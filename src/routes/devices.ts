import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { revokeSessionFamily } from "../lib/sessions";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import * as apns from "../lib/apns";
import { isProUser } from "../lib/plan";
import { uuidv7 } from "../lib/ids";
import { type ExtractedReceipt } from "../lib/deepseek";
import { writeReceiptRows } from "../lib/receiptRows";
import { notifyEmailInReceipt } from "../email/notify";

const SIM_MAX_IMAGE_BYTES = 6_291_456; // 6 MiB — mirrors inbound.ts

/** Dev simulator ONLY: a small set of varied synthetic receipts so each simulated email-in
 * lands as a DIFFERENT receipt (the bundled test image is fixed). The REAL email-in path
 * (src/email/inbound.ts) still extracts via Gemini — this only affects /devices/simulate-inbound. */
function pickSyntheticReceipt(date: string): ExtractedReceipt {
  const all = [
    { merchant: "Bunnings Warehouse", total: 89.5, gst: 8.14, category: "office", deductible: 100,
      lineItems: [{ name: "Cordless drill", price: 79 }, { name: "Drill bits 10pk", price: 10.5 }] },
    { merchant: "Coles", total: 42.3, gst: null, category: "groceries", deductible: 0,
      lineItems: [{ name: "Milk 2L", price: 3.5 }, { name: "Chicken breast 1kg", price: 12 }, { name: "Vegetables", price: 26.8 }] },
    { merchant: "Officeworks", total: 24.95, gst: 2.27, category: "office", deductible: 100,
      lineItems: [{ name: "A4 paper ream", price: 7.95 }, { name: "Pens 10pk", price: 6 }, { name: "USB-C cable", price: 11 }] },
    { merchant: "Caltex", total: 65, gst: 5.91, category: "vehicle", deductible: 100,
      lineItems: [{ name: "Unleaded 91 38.2L", price: 65 }] },
    { merchant: "JB Hi-Fi", total: 149, gst: 13.55, category: "office", deductible: 0,
      lineItems: [{ name: "Wireless mouse", price: 49 }, { name: "USB hub", price: 100 }] },
  ];
  const p = all[Math.floor(Math.random() * all.length)]!;
  return { ...p, date, currencyCode: "AUD", confidence: 0.95, needsReview: false };
}

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
  quietHoursStartMin: z.number().int().min(0).max(1439).optional(),
  quietHoursEndMin: z.number().int().min(0).max(1439).optional(),
  timezone: z.string().min(1).optional(),
  // The build's APNs environment, so the worker pushes to the matching host
  // (development → sandbox, production → prod). Omitted by quiet-hours-only updates.
  apnsEnvironment: z.enum(["development", "production"]).optional(),
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
  const {
    apnsToken, osVersion, model, pushEnabled,
    quietHoursStartMin, quietHoursEndMin, timezone, apnsEnvironment,
  } = c.req.valid("json");
  const now = nowMs();
  // push_enabled: 1/0 when the client sends it, null when omitted — so the INSERT defaults a NEW
  // device to 1 (COALESCE(?, 1)) while the UPDATE preserves the existing value (COALESCE(?, …)).
  // A token re-upload that omits pushEnabled must NOT clobber the user's Notifications toggle.
  const pushEnabledVal = pushEnabled !== undefined ? (pushEnabled ? 1 : 0) : null;

  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, model, os_version, apns_token, push_enabled,
                          quiet_hours_start_min, quiet_hours_end_min, timezone, apns_environment,
                          last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, COALESCE(?, 1), ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       model                 = COALESCE(excluded.model, devices.model),
       os_version            = COALESCE(excluded.os_version, devices.os_version),
       apns_token            = COALESCE(excluded.apns_token, devices.apns_token),
       push_enabled          = COALESCE(?, devices.push_enabled),
       quiet_hours_start_min = COALESCE(excluded.quiet_hours_start_min, devices.quiet_hours_start_min),
       quiet_hours_end_min   = COALESCE(excluded.quiet_hours_end_min, devices.quiet_hours_end_min),
       timezone              = COALESCE(excluded.timezone, devices.timezone),
       apns_environment      = COALESCE(excluded.apns_environment, devices.apns_environment),
       last_seen_at          = excluded.last_seen_at,
       updated_at            = excluded.updated_at,
       deleted_at            = NULL
     WHERE devices.user_id = excluded.user_id`,
  )
    .bind(
      deviceId,
      userId,
      model ?? null,
      osVersion ?? null,
      apnsToken ?? null,
      pushEnabledVal,                       // INSERT: COALESCE(?, 1) → new devices default ON
      quietHoursStartMin ?? null,
      quietHoursEndMin ?? null,
      timezone ?? null,
      apnsEnvironment ?? null,
      now,
      now,
      now,
      pushEnabledVal,                       // UPDATE: COALESCE(?, devices.push_enabled) → preserve toggle
    )
    .run();

  const row = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled,
            quiet_hours_start_min, quiet_hours_end_min, timezone, last_seen_at
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
      quiet_hours_start_min: number | null;
      quiet_hours_end_min: number | null;
      timezone: string | null;
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
    quietHoursStartMin: row.quiet_hours_start_min,
    quietHoursEndMin: row.quiet_hours_end_min,
    timezone: row.timezone,
    lastSeenAt: row.last_seen_at,
  });
});

/**
 * POST /devices/test-push
 * Dev/QA helper: send the email-in push to the authed user's OWN registered devices
 * and report the outcome, so push delivery can be exercised without sending a real
 * email. Returns the eligible-device count and a per-device "env=… status=…" detail
 * (status 200 = delivered, 400/410 = bad/expired token, "stub" = no APNS_KEY). Safe:
 * authed, owner's devices only, no side effects beyond the push.
 */
deviceRoutes.post("/test-push", async (c) => {
  const userId = c.var.userId;
  const { results } = await c.env.DB.prepare(
    `SELECT apns_token, apns_environment FROM devices
      WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`,
  ).bind(userId).all<{ apns_token: string; apns_environment: string | null }>();

  const payload: apns.ApnsPayload = {
    aps: { alert: { title: "New receipt", body: "Test email-in — tap to review." }, sound: "default" },
    type: "email_in",
    transactionId: "test",
    deepLink: "snapceipt://receipt/test",
  };

  const sends: string[] = [];
  for (const d of results) {
    const apnsEnv = d.apns_environment === "development" ? "development" : "production";
    const r = await apns.sendPush(c.env, d.apns_token, payload, apnsEnv);
    sends.push(`env=${apnsEnv} status=${r.stub ? "stub" : r.status}`);
  }
  const detail = results.length === 0
    ? "No registered device — enable notifications in the app first."
    : sends.join("; ");
  return c.json({ deviceCount: results.length, detail });
});

/**
 * POST /devices/simulate-inbound
 * Dev/QA: run a real email-in ingestion for the authed (Pro) user from an uploaded image —
 * store it to R2, extract via Gemini, write the transaction, then push the email-in
 * notification — WITHOUT sending an actual email. Lets the WHOLE flow be exercised
 * (receipt created → synced → push → tap-to-review → foreground refresh). Body = raw image
 * bytes; content-type sets the mime. Returns the created txn id + extraction + push count.
 */
deviceRoutes.post("/simulate-inbound", async (c) => {
  const userId = c.var.userId;
  if (!(await isProUser(c.env.DB, userId))) {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
  // Attach to the caller's ACTIVE profile when supplied (?profileId=, verified to belong to the
  // user) so the simulated receipt lands where the Email-in screen is actually looking. Without
  // it, fall back to the most-recently-aliased profile, then the oldest. (The active profile is a
  // client concept the server can't infer — a multi-profile user's newest alias may not be the
  // one currently on screen, which previously filed simulated receipts under the wrong profile.)
  const requestedProfileId = c.req.query("profileId");
  const prof = (requestedProfileId
    ? await c.env.DB.prepare(
        "SELECT id, type FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
      ).bind(requestedProfileId, userId).first<{ id: string; type: string }>()
    : null)
    ?? (await c.env.DB.prepare(
      `SELECT p.id, p.type FROM profiles p
         JOIN profile_inbox_tokens t ON t.profile_id = p.id
        WHERE p.user_id = ? AND p.deleted_at IS NULL
        ORDER BY t.created_at DESC LIMIT 1`,
    ).bind(userId).first<{ id: string; type: string }>())
    ?? (await c.env.DB.prepare(
      "SELECT id, type FROM profiles WHERE user_id = ? AND deleted_at IS NULL ORDER BY created_at LIMIT 1",
    ).bind(userId).first<{ id: string; type: string }>());
  if (!prof) throw new ApiError("NOT_FOUND", "No profile to attach the receipt to");

  const buf = await c.req.arrayBuffer();
  if (buf.byteLength === 0 || buf.byteLength > SIM_MAX_IMAGE_BYTES) {
    throw new ApiError("VALIDATION_FAILED", "A receipt image (≤6 MiB) is required in the body");
  }
  const contentType = (c.req.header("content-type") ?? "image/jpeg").toLowerCase();
  const ext = contentType.includes("png") ? "png" : "jpg";
  const now = nowMs();
  const defaultDate = new Date(now).toISOString().slice(0, 10);

  // Store the posted image (so the detail screen shows a photo), then attach a varied
  // synthetic receipt so each simulated email-in is a DIFFERENT receipt.
  const r2Key = `u/${userId}/${uuidv7()}.${ext}`;
  await c.env.RECEIPTS.put(r2Key, buf, { httpMetadata: { contentType } });

  const receipt = pickSyntheticReceipt(defaultDate);
  const extraction: "done" | "failed" = "done";
  const model = "synthetic";

  const transactionId = await writeReceiptRows(c.env.DB, {
    userId, profileId: prof.id, profileType: prof.type,
    receipt, ocrText: null, r2Key, contentType, byteSize: buf.byteLength,
    extractionStatus: extraction, extractionModel: model, nowMs: now,
  });
  await notifyEmailInReceipt(c.env, userId, transactionId, receipt.merchant, extraction, now);

  const { results } = await c.env.DB.prepare(
    `SELECT 1 FROM devices WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`,
  ).bind(userId).all();
  return c.json({ transactionId, extraction, merchant: receipt.merchant, deviceCount: results.length });
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
