import type { Env } from "../env";
import * as apns from "../lib/apns";

/** Best-effort APNs notify for an ingested email-in receipt. Pushes to every push-enabled
 * device of the owner; nulls a token APNs reports dead (410/400). NEVER throws — a push
 * failure must not affect email ingestion. No-op when no eligible device / APNS_KEY absent
 * (sendPush stubs). */
export async function notifyEmailInReceipt(
  env: Env, userId: string, transactionId: string, merchant: string,
  extraction: "done" | "failed", nowMs: number,
): Promise<void> {
  try {
    const created = extraction === "done";
    const body = created
      ? (merchant ? `From ${merchant} — tap to review.` : "New emailed receipt — tap to review.")
      : "Couldn't read it automatically — tap to review.";
    const payload: apns.ApnsPayload = {
      aps: { alert: { title: created ? "New receipt" : "Receipt received", body }, sound: "default" },
      type: "email_in",
      transactionId,
      deepLink: `snapceipt://receipt/${transactionId}`,
    };
    const { results } = await env.DB.prepare(
      `SELECT apns_token FROM devices
        WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`,
    ).bind(userId).all<{ apns_token: string }>();
    for (const d of results) {
      try {
        const r = await apns.sendPush(env, d.apns_token, payload);
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
