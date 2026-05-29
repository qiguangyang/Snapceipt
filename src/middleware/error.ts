import type { Hono, MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { ApiError, toEnvelope } from "../lib/errors";

// Generates a per-request id (honoring an inbound X-Request-Id when present),
// exposes it as c.var.requestId, and echoes it on the response as X-Request-Id.
export function requestId(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const incoming = c.req.header("X-Request-Id");
    const id = incoming && incoming.length <= 200 ? incoming : uuidv7();
    c.set("requestId", id);
    c.header("X-Request-Id", id);
    await next();
  };
}

// Registers the uniform error handler on the app. Any thrown ApiError maps to its
// status + envelope; anything else becomes a 500 INTERNAL envelope. requestId is
// always present (the middleware ran first); fall back to a fresh id if not.
export function registerErrorHandler(app: Hono<AppEnv>): void {
  app.onError((err, c) => {
    const requestId = c.get("requestId") ?? uuidv7();
    c.header("X-Request-Id", requestId);
    const status = err instanceof ApiError ? err.status : 500;
    const envelope = toEnvelope(err, requestId);
    return c.json(envelope, status as 400 | 401 | 403 | 404 | 409 | 429 | 500 | 501);
  });
}
