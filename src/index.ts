import { app } from "./app";
import type { Env } from "./env";
import { budgetCronLogic } from "./cron/budgetAlert";
import { d1BackupLogic } from "./cron/d1Backup";
import { inboundEmailLogic } from "./email/inbound";
import { currentPeriod, pruneOldUsage } from "./lib/smartScan";

/**
 * Prune smart_scan_usage rows older than ~2 months to avoid unbounded table growth.
 * Uses lexicographic YYYY-MM comparison: cutoff = period of (now − 62 days).
 * Keeps the current month and the previous month; deletes anything older.
 */
async function pruneSmartScanUsage(db: D1Database, now: number): Promise<void> {
  const SIXTY_TWO_DAYS_MS = 62 * 24 * 60 * 60 * 1000;
  const cutoff = currentPeriod(now - SIXTY_TWO_DAYS_MS);
  await pruneOldUsage(db, cutoff);
}

/**
 * Hourly scheduled handler (wrangler.jsonc triggers.crons = "0 * * * *").
 */
const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
  const now = Date.now();
  ctx.waitUntil(budgetCronLogic(env.DB, env, now));
  ctx.waitUntil(d1BackupLogic(env.DB, env.BACKUPS, now));
  ctx.waitUntil(pruneSmartScanUsage(env.DB, now));
};

/**
 * Inbound Email Routing handler (catch-all on in.snapceipt.cc). Thin wrapper:
 * builds the InboundMessage and delegates to the pure core. Rejected results call
 * setReject (the sender gets a bounce); created/duplicate are accepted silently.
 * Any thrown error is logged and swallowed — never rethrow, or Email Routing would
 * bounce + retry indefinitely.
 */
const email = async (
  message: ForwardableEmailMessage,
  env: Env,
  _ctx: ExecutionContext,
): Promise<void> => {
  try {
    const result = await inboundEmailLogic(
      env,
      {
        to: message.to,
        from: message.from,
        messageId: message.headers.get("message-id"),
        raw: message.raw,
      },
      Date.now(),
    );
    if (result.status === "rejected") {
      message.setReject(result.reason === "no_image" ? "No receipt image attached" : "Unknown inbox address");
    }
  } catch (err) {
    console.error("inbound email failed", err);
  }
};

// Worker entrypoint: HTTP fetch + hourly cron + inbound email.
export default {
  fetch: app.fetch,
  scheduled,
  email,
};
