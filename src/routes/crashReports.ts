// src/routes/crashReports.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { crashReportSchema } from "../schemas/crashReport";

/**
 * iOS MetricKit ingest (auth-gated; rate tier "default"). The global auth
 * middleware has already resolved c.var.userId AND c.var.deviceId (from the JWT
 * `sub`/`did` claims, src/middleware/auth.ts:43-44); the device id comes from the
 * session-bound c.var.deviceId so a client can't spoof another device's reports.
 *  POST /crash-reports — store one MXCrashDiagnostic/MXHangDiagnostic.
 * Server-only: crash_reports is NEVER in SYNCABLE_TABLES.
 */
export const crashReportRoutes = new Hono<AppEnv>();

crashReportRoutes.post("/", validate("json", crashReportSchema), async (c) => {
  const userId = c.var.userId;
  const deviceId = c.var.deviceId;
  const { kind, appVersion, osVersion, deviceModel, occurredAt, payload } = c.req.valid("json");
  const id = uuidv7();
  const now = nowMs();

  await c.env.DB.prepare(
    `INSERT INTO crash_reports
       (id, user_id, device_id, kind, app_version, os_version, device_model, occurred_at, payload, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(id, userId, deviceId, kind, appVersion, osVersion, deviceModel, occurredAt, JSON.stringify(payload), now)
    .run();

  return c.json({ id }, 201);
});
