import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";

/**
 * KV fixed-window rate limiter (SPINE §4 RATE LIMITING).
 *
 * One counter key per `{tier, identity, window-bucket}`. The bucket is
 * `floor(now / windowMs)` so keys roll over automatically each window and we
 * lean on KV `expirationTtl` (60s minimum) for cleanup. Identity is the authed
 * `userId` when present, else the client IP from `CF-Connecting-IP`. The
 * magic-link/auth class enforces BOTH a per-email cap (3/email/hr) and a per-IP
 * cap (10/IP/hr); apple + refresh share the same per-IP `auth` tier; all others
 * are single-dimension. On breach we throw `ApiError("RATE_LIMITED", …,
 * { retryAfter })` so the error middleware can set the `Retry-After` header.
 *
 * KV is eventually consistent, which is acceptable for coarse abuse limiting
 * (the SPINE notes this is upgradeable to the native Rate Limiting binding).
 */

const HOUR_MS = 60 * 60 * 1000;
const MINUTE_MS = 60 * 1000;

export type RateLimitTier = {
  /** stable prefix used in the KV key */
  name: string;
  /** max requests permitted per window */
  limit: number;
  /** window length in ms */
  windowMs: number;
  /** identity dimension: "user" falls back to IP when unauthenticated */
  dimension: "user" | "ip";
};

/** Route-class tiers (SPINE §4 RATE LIMITING). */
export const RATE_LIMIT_TIERS = {
  /** magic-link/apple/refresh per-IP ceiling. */
  authIp: { name: "auth-ip", limit: 10, windowMs: HOUR_MS, dimension: "ip" },
  /** magic-link per-email cap (keyed by the request body's email). */
  authEmail: { name: "auth-email", limit: 3, windowMs: HOUR_MS, dimension: "ip" },
  /** hot sync path. */
  sync: { name: "sync", limit: 600, windowMs: HOUR_MS, dimension: "user" },
  /** receipt extraction — calls an external API; keep it tight. */
  extract: { name: "extract", limit: 30, windowMs: HOUR_MS, dimension: "user" },
  /** export generation — file build + email; 60/user/hr. */
  export: { name: "export", limit: 60, windowMs: HOUR_MS, dimension: "user" },
  /** every other protected route. */
  default: { name: "default", limit: 300, windowMs: MINUTE_MS, dimension: "user" },
} as const satisfies Record<string, RateLimitTier>;

/** The factory's selectable route classes. */
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "default";

type RateLimitCtx = {
  req: { header: (n: string) => string | undefined };
  get: (k: "userId") => string | undefined;
};

/** Resolve the identity component of a KV key for a tier. */
export function clientKeyForRoute(c: RateLimitCtx, tier: RateLimitTier): string {
  if (tier.dimension === "user") {
    const uid = c.get("userId");
    if (uid) return `u:${uid}`;
  }
  const ip =
    c.req.header("CF-Connecting-IP") ??
    c.req.header("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown";
  return `ip:${ip}`;
}

/**
 * Consume one unit against a fixed window. Returns the seconds-to-reset when the
 * limit is exceeded, otherwise null.
 */
async function consume(
  kv: KVNamespace,
  tier: RateLimitTier,
  identity: string,
  now: number,
): Promise<number | null> {
  const bucket = Math.floor(now / tier.windowMs);
  const key = `rl:${tier.name}:${identity}:${bucket}`;
  const current = Number((await kv.get(key)) ?? "0");
  if (current >= tier.limit) {
    const resetMs = (bucket + 1) * tier.windowMs - now;
    return Math.max(1, Math.ceil(resetMs / 1000));
  }
  // KV TTL minimum is 60s; pad the window so the key outlives the bucket.
  const ttlSeconds = Math.max(60, Math.ceil(tier.windowMs / 1000) + 1);
  await kv.put(key, String(current + 1), { expirationTtl: ttlSeconds });
  return null;
}

function reject(retryAfterSeconds: number): never {
  throw new ApiError("RATE_LIMITED", "Rate limit exceeded. Please retry later.", {
    retryAfter: retryAfterSeconds,
  });
}

/**
 * Middleware factory. `kind` picks the tier:
 *  - "auth": magic-link/apple/refresh bootstrap — enforces 10/IP/hr always and
 *    3/email/hr when the JSON body carries an `email`.
 *  - "sync": 600/user/hr hot path.
 *  - "default": 300/user/min for every other protected route.
 * Runs BEFORE auth() on /auth/*, and AFTER auth() on protected groups (so a
 * userId is available there).
 */
export function rateLimit(kind: RateLimitKind): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const now = Date.now();
    const kv = c.env.KV;

    if (kind === "auth") {
      const ip = clientKeyForRoute(c, RATE_LIMIT_TIERS.authIp);
      const ipReset = await consume(kv, RATE_LIMIT_TIERS.authIp, ip, now);
      if (ipReset !== null) reject(ipReset);

      // Per-email cap, only when the body carries an email (request/verify shapes).
      let email: string | undefined;
      try {
        const cloned = c.req.raw.clone();
        const ct = cloned.headers.get("content-type") ?? "";
        if (ct.includes("application/json")) {
          const parsed = (await cloned.json()) as { email?: unknown };
          if (typeof parsed.email === "string" && parsed.email.length > 0) {
            email = parsed.email.trim().toLowerCase();
          }
        }
      } catch {
        // Non-JSON / unparseable body: the IP cap above still applies.
      }
      if (email) {
        const emailReset = await consume(
          kv,
          RATE_LIMIT_TIERS.authEmail,
          `email:${email}`,
          now,
        );
        if (emailReset !== null) reject(emailReset);
      }
      return next();
    }

    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : kind === "export"
            ? RATE_LIMIT_TIERS.export
            : RATE_LIMIT_TIERS.default;
    const identity = clientKeyForRoute(c, tier);
    const reset = await consume(kv, tier, identity, now);
    if (reset !== null) reject(reset);
    return next();
  };
}
