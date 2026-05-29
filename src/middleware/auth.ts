import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyAccess } from "../lib/jwt";

/**
 * Paths reachable without a valid access token. An entry ending in `/` matches by
 * prefix (e.g. `/auth/` covers all `/auth/*`); other entries match exactly.
 * Per the Canonical Contracts this includes `/health`, `/auth/*`, and `/banks`.
 */
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks"];

function isPublic(path: string): boolean {
  return PUBLIC_PATHS.some((p) => (p.endsWith("/") ? path.startsWith(p) : path === p));
}

/**
 * Bearer auth middleware. On a protected path it extracts the `Authorization:
 * Bearer <jwt>` token, verifies it (HS256, iss/aud/exp), and exposes
 * `c.var.userId` / `c.var.deviceId`. Any jose failure collapses to a single
 * client-facing 401 `AUTH_INVALID_TOKEN`. Public paths skip verification.
 */
export function authMiddleware(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    if (isPublic(c.req.path)) {
      return next();
    }

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
    return next();
  };
}
