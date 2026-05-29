import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { AppEnv } from "./env";
import { requestId, registerErrorHandler } from "./middleware/error";
import { ApiError, ERROR, type ErrorCode } from "./lib/errors";
import { miscRoutes } from "./routes/misc";

/**
 * The Snapceipt Worker Hono app. Middleware and routes are mounted at module
 * scope below — there is no factory function (per the plan's Canonical Contracts).
 * Order matters: requestId first (so every later layer + the error envelope
 * can read c.var.requestId), then logger, then cors. Routes mount last.
 */
export const app = new Hono<AppEnv>();

// Must be first so c.var.requestId + the X-Request-Id response header exist for
// every handler and for the error envelope. Register onError up front too.
app.use("*", requestId());
registerErrorHandler(app);

app.use("*", logger());
app.use("*", cors());

// TEMP: exercises the error envelope end-to-end; replaced when real routes land.
app.get("/__throw", (c) => {
  const code = c.req.query("code") ?? "INTERNAL";
  if (code in ERROR) throw new ApiError(code as ErrorCode, "nope");
  throw new Error("unexpected: " + code);
});

// Public + placeholder routes. (auth/rateLimit middleware: later tasks.)
app.route("/", miscRoutes);
