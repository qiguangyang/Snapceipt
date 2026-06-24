import type { Env } from "../env";
import * as apns from "../lib/apns";

interface BudgetRow {
  id: string;
  user_id: string;
  profile_id: string;
  category_id: string | null;
  label: string;
  month_key: string | null;
  cap_cents: number;
  alert_threshold_pct: number;
  alert_sent_at: number | null;
}

interface DeviceRow {
  apns_token: string;
  timezone: string | null;
  quiet_hours_start_min: number | null;
  quiet_hours_end_min: number | null;
  apns_environment: string | null;
}

/** UTC `YYYY-MM` for an epoch-ms instant. */
function utcMonthKey(ms: number): string {
  const d = new Date(ms);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

/** AUD dollars with 2 dp from signed/unsigned cents. */
function fmtMoney(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/**
 * Device-local minutes-from-midnight at `ms` in the given IANA timezone, using
 * Intl (available under workerd). Falls back to UTC when timezone is null.
 */
function localMinutes(ms: number, timezone: string | null): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone ?? "UTC",
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(new Date(ms));
  const hour = Number(parts.find((p) => p.type === "hour")?.value ?? "0") % 24;
  const minute = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  return hour * 60 + minute;
}

/** True if the device is currently in its quiet window (spec §4.6). */
function inQuietHours(device: DeviceRow, nowMs: number): boolean {
  const { quiet_hours_start_min: start, quiet_hours_end_min: end } = device;
  if (start === null || end === null) return false;
  const local = localMinutes(nowMs, device.timezone);
  if (start > end) return local >= start || local < end; // wrap-around
  return local >= start && local < end;
}

/**
 * Hourly budget-alert cron core (spec §4.3–4.6). Pure-ish: db + env + nowMs are
 * injected so it is unit-testable without the scheduled() runtime. For each live
 * budget it computes month spend, fires when over the threshold (unless already
 * alerted this month), pushes to each eligible non-quiet device, and stamps
 * alert_sent_at only when at least one device was actually pushed.
 */
export async function budgetCronLogic(db: D1Database, env: Env, nowMs: number): Promise<void> {
  const { results: budgets } = await db
    .prepare(
      `SELECT id, user_id, profile_id, category_id, label, month_key, cap_cents,
              alert_threshold_pct, alert_sent_at
         FROM budgets
        WHERE deleted_at IS NULL AND cap_cents > 0`,
    )
    .all<BudgetRow>();

  for (const b of budgets) {
    const targetMonth = b.month_key ?? utcMonthKey(nowMs);

    // Already alerted this month? (dedup; month rollover re-arms.)
    if (b.alert_sent_at !== null && utcMonthKey(b.alert_sent_at) === targetMonth) continue;

    // Spend = magnitude of expense cents for this profile + month (+ category).
    const spendRow = await db
      .prepare(
        `SELECT COALESCE(SUM(-amount_cents), 0) AS spent
           FROM transactions
          WHERE user_id = ? AND profile_id = ? AND deleted_at IS NULL
            AND amount_cents < 0
            AND substr(txn_date,1,7) = ?
            AND (? IS NULL OR category_id = ?)`,
      )
      .bind(b.user_id, b.profile_id, targetMonth, b.category_id, b.category_id)
      .first<{ spent: number }>();
    const spent = spendRow?.spent ?? 0;

    // Fire threshold: spent >= cap * pct / 100.
    if (spent * 100 < b.cap_cents * b.alert_threshold_pct) continue;

    // Eligible devices: push_enabled, token present, not currently quiet.
    const { results: devices } = await db
      .prepare(
        `SELECT apns_token, timezone, quiet_hours_start_min, quiet_hours_end_min, apns_environment
           FROM devices
          WHERE user_id = ? AND deleted_at IS NULL
            AND push_enabled = 1 AND apns_token IS NOT NULL`,
      )
      .bind(b.user_id)
      .all<DeviceRow>();

    const pct = Math.round((spent / b.cap_cents) * 100);
    const payload: apns.ApnsPayload = {
      aps: {
        alert: {
          title: "Budget alert",
          body: `${b.label}: ${fmtMoney(spent)} of ${fmtMoney(b.cap_cents)} (${pct}%)`,
        },
        sound: "default",
      },
      budgetId: b.id,
      deepLink: `snapceipt://budget/${b.id}`,
    };

    let pushed = 0;
    for (const d of devices) {
      if (inQuietHours(d, nowMs)) continue;
      try {
        const apnsEnv = d.apns_environment === "development" ? "development" : "production";
        const result = await apns.sendPush(env, d.apns_token, payload, apnsEnv);
        if (result.stub === false) {
          if (result.status === 200) {
            pushed++;
          } else if (result.status === 410 || result.status === 400) {
            // APNs reports the token is no longer valid (410 Unregistered / 400 BadDeviceToken):
            // null it so future runs skip this device (devices WHERE apns_token IS NOT NULL).
            await db
              .prepare(`UPDATE devices SET apns_token = NULL, updated_at = ? WHERE apns_token = ?`)
              .bind(nowMs, d.apns_token)
              .run();
          }
        }
      } catch (err) {
        console.warn(`[budgetAlert] sendPush failed for token ${String(d.apns_token).slice(0, 8)}…:`, err);
      }
    }

    // Stamp only if at least one device was actually pushed (quiet-suppressed
    // budgets re-fire on the next hourly run outside the quiet window).
    if (pushed > 0) {
      await db.prepare(`UPDATE budgets SET alert_sent_at = ? WHERE id = ?`).bind(nowMs, b.id).run();
    }
  }
}
