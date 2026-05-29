import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { revokeSessionFamily } from "../lib/sessions";
import { nowMs } from "../lib/time";
import { validate } from "./auth";

/**
 * Device routes mounted under `/devices`. PROTECTED — the global auth middleware
 * has already resolved c.var.userId by the time these run (no per-route auth
 * import per the Canonical Contracts).
 */
export const deviceRoutes = new Hono<AppEnv>();

const putBody = z.object({
  apnsToken: z.string().min(1).optional(),
  appVersion: z.string().optional(),
  osVersion: z.string().optional(),
  model: z.string().optional(),
  pushEnabled: z.boolean().optional(),
});

/**
 * PUT /devices/me
 * Upsert the device named by the X-Device-Id header for the authed user. The
 * upsert is keyed on the device PK and scoped `WHERE devices.user_id =
 * excluded.user_id`, so a device id can never be silently re-homed to another
 * user. A missing X-Device-Id collapses to 400 VALIDATION_FAILED.
 */
deviceRoutes.put("/me", validate("json", putBody), async (c) => {
  const deviceId = c.req.header("X-Device-Id");
  if (!deviceId) {
    throw new ApiError("VALIDATION_FAILED", "Missing X-Device-Id header");
  }
  const userId = c.var.userId;
  const { apnsToken, osVersion, model, pushEnabled } = c.req.valid("json");
  const now = nowMs();

  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, model, os_version, apns_token, push_enabled, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       model        = COALESCE(excluded.model, devices.model),
       os_version   = COALESCE(excluded.os_version, devices.os_version),
       apns_token   = COALESCE(excluded.apns_token, devices.apns_token),
       push_enabled = excluded.push_enabled,
       last_seen_at = excluded.last_seen_at,
       updated_at   = excluded.updated_at,
       deleted_at   = NULL
     WHERE devices.user_id = excluded.user_id`,
  )
    .bind(
      deviceId,
      userId,
      model ?? null,
      osVersion ?? null,
      apnsToken ?? null,
      pushEnabled === false ? 0 : 1,
      now,
      now,
      now,
    )
    .run();

  const row = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled, last_seen_at
       FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  )
    .bind(deviceId, userId)
    .first<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      apns_token: string | null;
      push_enabled: number;
      last_seen_at: number | null;
    }>();
  // The scoped upsert is a no-op when the device id belongs to a different user.
  if (!row) throw new ApiError("FORBIDDEN", "Device belongs to another user");

  return c.json({
    id: row.id,
    platform: row.platform,
    model: row.model,
    osVersion: row.os_version,
    hasApnsToken: row.apns_token !== null,
    pushEnabled: row.push_enabled === 1,
    lastSeenAt: row.last_seen_at,
  });
});

/**
 * DELETE /devices/:id
 * Sign a device out: tombstone the row and revoke every session family bound to
 * that device. Scoped to the authed user; deleting a device that is not theirs
 * (or already gone) is 404 NOT_FOUND.
 */
deviceRoutes.delete("/:id", async (c) => {
  const id = c.req.param("id");
  const userId = c.var.userId;

  const device = await c.env.DB.prepare(
    "SELECT id FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
  )
    .bind(id, userId)
    .first<{ id: string }>();
  if (!device) throw new ApiError("NOT_FOUND", "Device not found");

  const now = nowMs();

  // Revoke every family bound to this device (covers re-issues across families).
  const families = await c.env.DB.prepare(
    "SELECT DISTINCT family FROM sessions WHERE device_id = ? AND user_id = ?",
  )
    .bind(id, userId)
    .all<{ family: string }>();
  for (const f of families.results) {
    await revokeSessionFamily(c.env.DB, f.family);
  }

  // Tombstone the device (soft-delete so the change propagates via sync).
  await c.env.DB.prepare(
    "UPDATE devices SET deleted_at = ?, updated_at = ? WHERE id = ? AND user_id = ?",
  )
    .bind(now, now, id, userId)
    .run();

  return c.json({ ok: true });
});
