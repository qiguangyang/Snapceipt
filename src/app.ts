import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { requestId } from "hono/request-id";
import type { AppEnv } from "./env";
import { miscRoutes } from "./routes/misc";

/**
 * The Snapceipt Worker Hono app. Middleware and routes are mounted at module
 * scope below — there is no factory function (per the plan's Canonical Contracts).
 * Order matters: requestId first (so every later layer + the error envelope
 * can read c.var.requestId), then logger, then cors. Routes mount last.
 */
export const app = new Hono<AppEnv>();

// Mirror Hono's request id into our typed Variables so c.get("requestId") works
// everywhere (Hono's requestId() stores it under the same key).
app.use("*", requestId());
app.use("*", logger());
app.use("*", cors());

// Public + placeholder routes. (auth/rateLimit/error middleware: later tasks.)
app.route("/", miscRoutes);
