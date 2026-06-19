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
import { imageRoutes } from "./routes/images";
import { extractRoutes } from "./routes/extract";
import { exportRoutes } from "./routes/export";
import { quotesRoutes } from "./routes/quotes";
import { quoteLinkRoutes } from "./routes/quoteLink";
import { invoicesRoutes } from "./routes/invoices";
import { inboxRoutes } from "./routes/inbox";
import { profileRoutes } from "./routes/profile";
import { accountRoutes } from "./routes/account";
import { crashReportRoutes } from "./routes/crashReports";
import { appstoreRoutes } from "./routes/appstore";
import { subscriptionRoutes } from "./routes/subscription";

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
// Receipt extraction (external API) — tight 30/user/hr tier. Mount the limiter
// on BOTH the exact path AND the wildcard: the route handler serves POST /extract
// (no trailing slash, mounted at "/"), and Hono's "/extract/*" wildcard does NOT
// reliably match the exact "/extract" path, so the exact mount guarantees the
// limiter runs for the actual POST. (Belt-and-suspenders; no behavior depends on
// "try and see".)
app.use("/extract", rateLimit("extract"));
app.use("/extract/*", rateLimit("extract"));
// Image upload/read — default tier. POST /images is the exact path; GET /images/*
// is the wildcard. Mount both so the exact-path POST is also limited.
app.use("/images", rateLimit("default"));
app.use("/images/*", rateLimit("default"));
// Export generation — file build + email; 60/hr. Mount on BOTH the exact path
// (POST /export) AND the wildcard so the limiter runs for the actual POST too.
// The wildcard also covers the public GET /export/dl/* download: since that
// route is unauthenticated, the "export" tier (dimension: user) falls back to
// IP-keyed limiting (60/IP/hr) — benign anti-abuse on the public endpoint; a
// normal accountant opening a 7-day link is well under the cap.
app.use("/export", rateLimit("export"));
app.use("/export/*", rateLimit("export"));
// Quote send — PDF build + email; 60/hr. Mount on BOTH the exact path
// (POST /quotes/:id/send) AND the wildcard so the limiter runs for the actual
// POST too. The wildcard also covers the public GET /quotes/dl/* download:
// since that route is unauthenticated, the "quotes" tier (dimension: user)
// falls back to IP-keyed limiting on the public endpoint.
app.use("/quotes", rateLimit("quotes"));
app.use("/quotes/*", rateLimit("quotes"));
// Public HTML quote page — GET /q/:token. Unauthenticated; the default tier's
// per-user limiter falls back to IP-keyed limiting on this public endpoint.
app.use("/q/*", rateLimit("default"));
// Invoice issue/send/pdf — PDF build + email; reuse the "quotes" tier (60/hr).
// Mount on BOTH the exact path AND the wildcard so the limiter runs for the POSTs;
// the wildcard also IP-limits the public GET /invoices/dl/* download.
app.use("/invoices", rateLimit("quotes"));
app.use("/invoices/*", rateLimit("quotes"));
// Inbox alias mint/rotate — light per-user tier. Auth-gated (not public).
app.use("/profiles/*", rateLimit("inbox"));
// Business-profile asset upload (logo) — default tier. Auth-gated (NOT in PUBLIC_PATHS).
// Mount on BOTH the exact path AND the wildcard so the POST is limited.
app.use("/profile", rateLimit("default"));
app.use("/profile/*", rateLimit("default"));
// Account ops (change email / delete account) — tight per-user tier. Auth-gated.
app.use("/users/*", rateLimit("account"));
app.use("/account", rateLimit("account"));
// iOS MetricKit ingest — default tier. Auth-gated.
app.use("/crash-reports", rateLimit("default"));

// Public + placeholder routes.
// /auth/* is in the public-path allowlist (auth middleware skips it).
app.route("/auth", authRoutes);
// Protected: /devices/* is not in PUBLIC_PATHS, so authMiddleware guards it and
// the handlers read c.var.userId.
app.route("/devices", deviceRoutes);
// Protected: /sync/* (push + pull). Same auth model — handlers read
// c.var.userId / c.var.deviceId.
app.route("/sync", syncRoutes);
// Protected: receipt image upload/read (R2 + FK-safe receipt_images link).
app.route("/images", imageRoutes);
// Protected: receipt extraction (DeepSeek + stub). Rate tier "extract" above.
app.route("/extract", extractRoutes);
// Protected: POST /export (+ public GET /export/dl/:token via PUBLIC_PATHS).
app.route("/export", exportRoutes);
// Protected: POST /quotes/:id/send (+ public GET /quotes/dl/:token via PUBLIC_PATHS).
app.route("/quotes", quotesRoutes);
// Protected: POST /invoices/:id/issue|send|pdf (+ public GET /invoices/dl/:token via PUBLIC_PATHS).
app.route("/invoices", invoicesRoutes);
// Protected: per-profile inbox alias (GET mint + POST rotate).
app.route("/profiles", inboxRoutes);
// Protected: business-profile assets (POST /profile/logo -> R2 + logo_r2_key).
app.route("/profile", profileRoutes);
// Protected: iOS MetricKit crash/hang ingest (server-only crash_reports table).
app.route("/crash-reports", crashReportRoutes);
// Protected: account ops (change email via code, delete account).
app.route("/", accountRoutes);
// Protected: POST /me/subscription — purchase link (StoreKit tx → backend).
app.use("/me/*", rateLimit("account"));
app.route("/me/subscription", subscriptionRoutes);
// Public: GET /q/:token — hosted HTML quote page (via PUBLIC_PATHS).
app.route("/q", quoteLinkRoutes);
// Public unauthenticated webhook — IP-keyed via the default tier's fallback
// (no userId is present; clientKeyForRoute falls back to CF-Connecting-IP).
app.use("/appstore/*", rateLimit("default"));
app.route("/appstore", appstoreRoutes);
app.route("/", miscRoutes);
