import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { AppEnv } from "./env";
import { requestId, registerErrorHandler } from "./middleware/error";
import { authMiddleware } from "./middleware/auth";
import { ApiError, ERROR, type ErrorCode } from "./lib/errors";
import { miscRoutes } from "./routes/misc";
import { authRoutes } from "./routes/auth";
import { deviceRoutes } from "./routes/devices";

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
// Mounted BEFORE authMiddleware so it stays reachable without a bearer token
// (it is not in PUBLIC_PATHS); remove alongside __authprobe in later cleanup.
app.get("/__throw", (c) => {
  const code = c.req.query("code") ?? "INTERNAL";
  if (code in ERROR) throw new ApiError(code as ErrorCode, "nope");
  throw new Error("unexpected: " + code);
});

// Bearer auth, applied once globally. isPublic() internally lets /health,
// /auth/* and /banks through, so a single wildcard mount is correct and avoids
// per-group duplication. Protected routes just read c.var.userId / c.var.deviceId.
app.use("*", authMiddleware());

// TEMP(test-probe): protected route that echoes the resolved identity so the
// auth middleware can be black-box tested. Harmless behind auth; useful for the
// auth tests in later tasks. Remove in later cleanup.
app.get("/__authprobe", (c) => c.json({ userId: c.var.userId, deviceId: c.var.deviceId }));

// Public + placeholder routes. (rateLimit middleware: later tasks.)
// /auth/* is in the public-path allowlist (auth middleware skips it).
app.route("/auth", authRoutes);
// Protected: /devices/* is not in PUBLIC_PATHS, so authMiddleware guards it and
// the handlers read c.var.userId.
app.route("/devices", deviceRoutes);
app.route("/", miscRoutes);
