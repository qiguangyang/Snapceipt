import { app } from "./app";
import type { Env } from "./env";
import { budgetCronLogic } from "./cron/budgetAlert";
import { inboundEmailLogic } from "./email/inbound";

/**
 * Hourly scheduled handler (wrangler.jsonc triggers.crons = "0 * * * *").
 */
const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
  ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()));
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
