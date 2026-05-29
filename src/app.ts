import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { AppEnv } from "./env";
import { requestId, registerErrorHandler } from "./middleware/error";
import { authMiddleware } from "./middleware/auth";
import { rateLimit } from "./middleware/rateLimit";
import { miscRoutes } from "./routes/misc";
import { authRoutes } from "./routes/auth";
import { deviceRoutes } from "./routes/devices";
import { syncRoutes } from "./routes/sync";

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

// Rate limit the auth bootstrap BEFORE auth verification. authMiddleware's
// allowlist skips all of /auth/*, so this limiter is the only gate there; it
// enforces 10/IP/hr (apple + refresh) plus 3/email/hr (magic-link). Order on
// /auth/*: requestId -> rateLimit("auth") -> routes.
app.use("/auth/*", rateLimit("auth"));

// Bearer auth, applied once globally. isPublic() internally lets /health,
// /auth/* and /banks through, so a single wildcard mount is correct and avoids
// per-group duplication. Protected routes just read c.var.userId / c.var.deviceId.
app.use("*", authMiddleware());

// Per-class limiters for the protected groups, mounted AFTER authMiddleware so
// c.var.userId is populated (the limiter keys on userId). Order on /sync/* and
// /devices/*: requestId -> auth -> rateLimit(...) -> routes. /health and /banks
// are never rate-limited (they sit outside these prefixes).
app.use("/sync/*", rateLimit("sync"));
app.use("/devices/*", rateLimit("default"));

// Public + placeholder routes.
// /auth/* is in the public-path allowlist (auth middleware skips it).
app.route("/auth", authRoutes);
// Protected: /devices/* is not in PUBLIC_PATHS, so authMiddleware guards it and
// the handlers read c.var.userId.
app.route("/devices", deviceRoutes);
// Protected: /sync/* (push + pull). Same auth model — handlers read
// c.var.userId / c.var.deviceId.
app.route("/sync", syncRoutes);
app.route("/", miscRoutes);
