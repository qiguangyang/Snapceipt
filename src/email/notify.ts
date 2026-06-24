import type { Env } from "../env";
import * as apns from "../lib/apns";

/** Push `payload` to every push-enabled device of `userId`; nulls a token APNs reports dead
 * (410/400). NEVER throws — a push failure must not affect email ingestion. No-op when no
 * eligible device / APNS_KEY absent (sendPush stubs). `logTag` labels the wrangler-tail line. */
async function pushToOwnerDevices(
  env: Env, userId: string, payload: apns.ApnsPayload, nowMs: number, logTag: string,
): Promise<void> {
  try {
    const { results } = await env.DB.prepare(
      `SELECT apns_token, apns_environment FROM devices
        WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`,
    ).bind(userId).all<{ apns_token: string; apns_environment: string | null }>();
    // Observability: how many devices are eligible + each send's environment/status, so push
    // delivery can be diagnosed from `wrangler tail` (200 = delivered, 400/410 = bad/dead token).
    console.log(`[email-in:push] ${logTag}: ${results.length} eligible device(s)`);
    for (const d of results) {
      try {
        const apnsEnv = d.apns_environment === "development" ? "development" : "production";
        const r = await apns.sendPush(env, d.apns_token, payload, apnsEnv);
        console.log(
          `[email-in:push] sent env=${apnsEnv} status=${r.stub ? "stub" : r.status} token=${d.apns_token.slice(0, 8)}…`,
        );
        if (r.stub === false && (r.status === 410 || r.status === 400)) {
          await env.DB.prepare(`UPDATE devices SET apns_token = NULL, updated_at = ? WHERE apns_token = ?`)
            .bind(nowMs, d.apns_token).run();
        }
      } catch (err) {
        console.warn(`[email-in:push] sendPush failed for ${String(d.apns_token).slice(0, 8)}…:`, err);
      }
    }
  } catch (err) {
    console.warn("[email-in:push] notify failed:", err);
  }
}

/** Best-effort summary push after an inbound email is ingested: ONE notification per email,
 * regardless of how many receipts (attachments) it produced. No `transactionId` is sent, so the
 * tap opens the Email-in LIST (not a single receipt detail) — the product decision for batches.
 * No-op for count <= 0. */
export async function notifyEmailInBatch(
  env: Env, userId: string, count: number, nowMs: number,
): Promise<void> {
  if (count <= 0) return;
  const body = count === 1
    ? "1 receipt arrived — tap to review."
    : `${count} receipts arrived — tap to review.`;
  const payload: apns.ApnsPayload = {
    aps: { alert: { title: count === 1 ? "New receipt" : "New receipts", body }, sound: "default" },
    type: "email_in",
    // Intentionally NO transactionId/deepLink → NotificationDelegate.route falls back to the list.
  };
  await pushToOwnerDevices(env, userId, payload, nowMs, `batch ${count} receipt(s)`);
}
