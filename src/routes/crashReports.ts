// src/routes/crashReports.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { rateLimit } from "../middleware/rateLimit";
import { validate } from "./auth";
import { crashReportSchema } from "../schemas/crashReport";

/**
 * iOS MetricKit ingest (auth-gated). The global auth middleware has already
 * resolved c.var.userId AND c.var.deviceId (from the JWT `sub`/`did` claims,
 * src/middleware/auth.ts:43-44); the device id comes from the session-bound
 * c.var.deviceId so a client can't spoof another device's reports.
 *  POST /crash-reports — store one MXCrashDiagnostic/MXHangDiagnostic.
 * Server-only: crash_reports is NEVER in SYNCABLE_TABLES.
 *
 * M3 hardening (storage-exhaustion vector):
 *  - a dedicated, FAR tighter per-IP rate tier ("crash", 10/min) is enforced
 *    HERE in the sub-app so it actually takes effect — app.ts still mounts the
 *    looser `default` tier on /crash-reports (app.ts is out of scope for this
 *    change), but this in-route limiter trips first;
 *  - the stored payload is capped/truncated (below) so an oversized body can't
 *    bloat a row toward D1's ~1 MB value limit;
 *  - pruneCrashReports() (wired into the scheduled handler) deletes old rows.
 */
export const crashReportRoutes = new Hono<AppEnv>();

// Tight per-IP cap, applied in-route so it's effective despite app.ts's looser tier.
crashReportRoutes.use(rateLimit("crash"));

/** Cap on the stored MXDiagnostic JSON. MetricKit dictionaries are small; anything larger is
 *  truncated (kept, never dropped — telemetry should survive) so a crafted oversized body can't
 *  exhaust D1 storage. Below the schema's 256 KB pre-cap, so this is the effective bound. */
const MAX_STORED_PAYLOAD_BYTES = 16_384; // 16 KB
/** Delete crash_reports older than this (retention prune; run from the scheduled handler). */
const CRASH_RETENTION_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

crashReportRoutes.post("/", validate("json", crashReportSchema), async (c) => {
  const userId = c.var.userId;
  const deviceId = c.var.deviceId;
  const { kind, appVersion, osVersion, deviceModel, occurredAt, payload } = c.req.valid("json");
  const id = uuidv7();
  const now = nowMs();

  // Bound the stored row: truncate an oversized payload rather than reject it (don't lose telemetry).
  const serialized = JSON.stringify(payload);
  const storedPayload =
    serialized.length > MAX_STORED_PAYLOAD_BYTES
      ? JSON.stringify({
          _truncated: true,
          _originalBytes: serialized.length,
          preview: serialized.slice(0, MAX_STORED_PAYLOAD_BYTES),
        })
      : serialized;

  await c.env.DB.prepare(
    `INSERT INTO crash_reports
       (id, user_id, device_id, kind, app_version, os_version, device_model, occurred_at, payload, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(id, userId, deviceId, kind, appVersion, osVersion, deviceModel, occurredAt, storedPayload, now)
    .run();

  return c.json({ id }, 201);
});

/**
 * Retention prune (M3): delete crash_reports older than CRASH_RETENTION_MS so the
 * server-only telemetry table can't grow without bound. Indexed on created_at
 * (ix_crash_created), so the range delete is cheap. Wired into the hourly cron.
 */
export async function pruneCrashReports(db: D1Database, now: number): Promise<void> {
  const cutoff = now - CRASH_RETENTION_MS;
  await db.prepare("DELETE FROM crash_reports WHERE created_at < ?").bind(cutoff).run();
}
