import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyAccess } from "../lib/jwt";

/**
 * Paths reachable without a valid access token. An entry ending in `/` matches by
 * prefix (e.g. `/auth/` covers all `/auth/*`); other entries match exactly.
 * Per the Canonical Contracts this includes `/health`, `/auth/*`, and `/banks`.
 */
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/q/", "/i/", "/invoices/dl/", "/appstore/"];

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

  // TODO(security L3): an access token stays valid for up to its ~15-min TTL after sign-out /
  // device-revoke, because this middleware verifies the JWT purely cryptographically and does
  // not consult session liveness. DEFERRED this pass (not forced) because every safe lever is
  // out of reach here without regressions:
  //  - Centralizing `isSessionLive(DB, claims.sid, now)` here would 401 a token whose session
  //    row is absent/revoked. That breaks currently-green auth tests by design: authmw.test.ts
  //    signs tokens with synthetic session ids (e.g. "s-9") and expects 200, and
  //    devices-revoke.test.ts asserts /auth/me still 200s right after the session is revoked
  //    (the device merely drops out of the list). It also adds a D1 read to EVERY request.
  //  - Shortening the access TTL lives in src/lib/jwt.ts (ACCESS_TTL_SECONDS), which is outside
  //    this change's scope.
  // The blast radius is already bounded: the highest-value state-changing routes (account
  // delete, sync push) call isSessionLive() explicitly (src/routes/account.ts, src/routes/sync.ts),
  // turning revocation into an immediate kill-switch there. Revisit by either lowering the TTL or
  // centralizing the liveness check together with updating those two tests.
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
