import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";

/**
 * Misc routes: a public health check and the connected-banks placeholder.
 * /health is in the public-path allowlist (no auth) — mounted before auth in app.ts.
 */
export const miscRoutes = new Hono<AppEnv>();

// Public liveness probe. No auth, no DB access.
miscRoutes.get("/health", (c) => {
  return c.json({ ok: true, service: "snapceipt-api" });
});

// Connected banks / reconcile is a v1 UI placeholder with no backend.
// Throw the shared ApiError so the onError handler emits the uniform 501
// envelope (with requestId + X-Request-Id) — the iOS app degrades gracefully.
miscRoutes.all("/banks", () => {
  throw new ApiError(
    "NOT_IMPLEMENTED",
    "Connected banks are not available in this version.",
  );
});
