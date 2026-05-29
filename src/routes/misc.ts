import { Hono } from "hono";
import type { AppEnv } from "../env";

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
// Return a 501 envelope so the iOS app degrades gracefully.
// (Uses the error-envelope shape directly; the ApiError class + middleware
//  arrive in the errors task and will subsume this.)
miscRoutes.all("/banks", (c) => {
  return c.json(
    {
      error: {
        code: "NOT_IMPLEMENTED",
        message: "Connected banks are not available in this version.",
        requestId: c.get("requestId") ?? "",
      },
    },
    501,
  );
});
