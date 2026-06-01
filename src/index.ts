import { app } from "./app";
import type { Env } from "./env";
import { budgetCronLogic } from "./cron/budgetAlert";

/**
 * Hourly scheduled handler (wrangler.jsonc triggers.crons = "0 * * * *").
 * Runs the budget-alert cron core with the current epoch-ms; waitUntil keeps the
 * isolate alive until the recompute + APNs sends settle. Errors are logged (a
 * thrown error would surface in the cron dashboard); the next hourly run retries.
 */
const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
  ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()));
};

// Worker entrypoint: HTTP fetch + the hourly budget-push scheduled handler.
export default {
  fetch: app.fetch,
  scheduled,
};
