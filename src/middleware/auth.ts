import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyAccess } from "../lib/jwt";

/**
 * Paths reachable without a valid access token. An entry ending in `/` matches by
 * prefix (e.g. `/auth/` covers all `/auth/*`); other entries match exactly.
 * Per the Canonical Contracts this includes `/health`, `/auth/*`, and `/banks`.
 */
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/quotes/dl/", "/invoices/dl/", "/appstore/"];

function isPublic(path: string): boolean {
  return PUBLIC_PATHS.some((p) => (p.endsWith("/") ? path.startsWith(p) : path === p));
}

/**
 * Verify the `Authorization: Bearer <jwt>` header and stash the resolved identity
 * (`userId` / `deviceId` / `sessionId`) on the context. Any jose failure collapses
 * to a single client-facing 401 `AUTH_INVALID_TOKEN`. Shared by `authMiddleware`
 * and by `requireAuth` (for the handful of bearer routes that live under an
 * otherwise-public path prefix, e.g. /auth/me + /auth/signout).
 */
async function verifyBearer(c: Parameters<MiddlewareHandler<AppEnv>>[0]): Promise<void> {
  const header = c.req.header("Authorization");
  if (!header || !header.startsWith("Bearer ")) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Missing or malformed Authorization header");
  }
  const token = header.slice("Bearer ".length).trim();
  if (!token) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Empty bearer token");
  }

  let claims;
  try {
    claims = await verifyAccess(c.env.JWT_SIGNING_KEY, token);
  } catch {
    // jose throws JWTExpired / JWSSignatureVerificationFailed / JWTClaimValidationFailed —
    // all collapse to one client-facing code.
    throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired access token");
  }

  c.set("userId", claims.sub);
  c.set("deviceId", claims.did);
  c.set("sessionId", claims.sid);
}

/**
 * Bearer auth middleware. On a protected path it verifies the bearer token and
 * exposes `c.var.userId` / `c.var.deviceId` / `c.var.sessionId`. Public paths
 * (per PUBLIC_PATHS) skip verification.
 */
export function authMiddleware(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    if (isPublic(c.req.path)) {
      return next();
    }
    await verifyBearer(c);
    return next();
  };
}

/**
 * Route-scoped bearer guard for protected endpoints that sit UNDER a public path
 * prefix (the global authMiddleware skips all of /auth/*, but /auth/me and
 * /auth/signout still require a valid access token).
 */
export function requireAuth(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    await verifyBearer(c);
    return next();
  };
}
