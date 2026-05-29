import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import type { ZodSchema } from "zod";
import type { ValidationTargets } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { issueSession } from "../lib/sessions";
import { sendMagicLinkEmail } from "../lib/email";
import { verifyAppleIdentityToken } from "../lib/apple";
import { appleBody, magicLinkRequestBody, magicLinkVerifyBody } from "../schemas/auth";

/**
 * zValidator wrapper whose failure path throws the shared ApiError so the
 * onError handler emits the uniform 400 VALIDATION_FAILED envelope (the default
 * @hono/zod-validator behavior returns a bare 400 with the raw ZodError, which
 * would bypass our error contract).
 */
function validate<T extends ZodSchema, Target extends keyof ValidationTargets>(
  target: Target,
  schema: T,
) {
  return zValidator(target, schema, (result) => {
    if (!result.success) {
      throw new ApiError(
        "VALIDATION_FAILED",
        "Request validation failed",
        result.error.issues,
      );
    }
  });
}

/**
 * Auth routes mounted under `/auth` (public — in the auth-middleware allowlist).
 * This task adds the email magic-link half: request + verify. Apple / refresh
 * handlers land on this same `authRoutes` instance in their own tasks.
 */
export const authRoutes = new Hono<AppEnv>();

const MAGIC_LINK_TTL_SECONDS = 600; // 10 minutes
const MAGIC_LINK_BASE_URL = "https://snapceipt.app/auth/magic";

/** Canonical form for email comparison + storage: trimmed + lowercased. */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** SHA-256 hex of the input — used to derive the KV key from the raw token. */
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** 256-bit opaque token, base64url (no padding) — matches the refresh-token shape. */
function newMagicToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * POST /auth/magic-link/request
 * Mint a 256-bit token, store only its sha256 in KV under `ml:<hash>` (600s TTL,
 * `{email}` metadata), and email the link via the SendEmail binding. ALWAYS 202
 * (for known AND unknown emails) so the response can't be used to enumerate
 * accounts. Rate-limiting is applied centrally by the rate-limit middleware.
 */
authRoutes.post(
  "/magic-link/request",
  validate("json", magicLinkRequestBody),
  async (c) => {
    const { email } = c.req.valid("json");
    const normalized = normalizeEmail(email);

    const token = newMagicToken();
    const hash = await sha256Hex(token);

    // Store only the hash; metadata carries the email for verify-time lookup.
    await c.env.KV.put(`ml:${hash}`, "1", {
      expirationTtl: MAGIC_LINK_TTL_SECONDS,
      metadata: { email: normalized, createdAt: nowMs() },
    });

    const link = `${MAGIC_LINK_BASE_URL}?token=${token}`;
    // Routed through the email seam (src/lib/email.ts) so tests can spy on it;
    // the real SendEmail binding isn't exercisable in the test runtime.
    await sendMagicLinkEmail(c.env, { to: normalized, link });

    // ALWAYS 202 — no account enumeration. No response body.
    return c.body(null, 202);
  },
);

/**
 * POST /auth/magic-link/verify
 * Hash the presented token, look it up in KV, DELETE it (single-use), then
 * upsert the user by email (+ email auth_identity), register the X-Device-Id
 * device if present, and issue a session. Unknown / consumed / expired tokens
 * collapse to 401 AUTH_INVALID_TOKEN.
 */
authRoutes.post(
  "/magic-link/verify",
  validate("json", magicLinkVerifyBody),
  async (c) => {
    const { token } = c.req.valid("json");
    const hash = await sha256Hex(token);
    const key = `ml:${hash}`;

    const stored = await c.env.KV.getWithMetadata<{ email: string }>(key, "text");
    if (stored.value === null || !stored.metadata?.email) {
      // Unknown, already-consumed, or expired (KV TTL evicted it).
      throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired magic link");
    }

    // Single-use: delete before issuing so a replay can't double-consume.
    await c.env.KV.delete(key);

    const email = normalizeEmail(stored.metadata.email);
    const now = nowMs();

    // Upsert user by email (unique among non-deleted users). Reuse if present.
    let user = await c.env.DB.prepare(
      "SELECT id, email, display_name FROM users WHERE email = ? AND deleted_at IS NULL",
    )
      .bind(email)
      .first<{ id: string; email: string | null; display_name: string | null }>();

    if (!user) {
      const userId = uuidv7();
      await c.env.DB.prepare(
        `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
         VALUES (?, ?, 1, NULL, 'free', ?, ?)`,
      )
        .bind(userId, email, now, now)
        .run();
      user = { id: userId, email, display_name: null };
    } else {
      // A returning magic-link user has now re-proven control of the email.
      await c.env.DB.prepare("UPDATE users SET email_verified = 1, updated_at = ? WHERE id = ?")
        .bind(now, user.id)
        .run();
    }

    // Ensure an email auth_identity exists (idempotent on unique (provider,subject)).
    await c.env.DB.prepare(
      `INSERT INTO auth_identities (id, user_id, provider, subject, created_at)
       VALUES (?, ?, 'email', ?, ?)
       ON CONFLICT(provider, subject) DO NOTHING`,
    )
      .bind(uuidv7(), user.id, email, now)
      .run();

    // Register the device if the client sent one (X-Device-Id is the install UUID).
    const deviceHeader = c.req.header("X-Device-Id");
    const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();
    await c.env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at)
       VALUES (?, ?, 'ios', ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         user_id = excluded.user_id,
         last_seen_at = excluded.last_seen_at,
         updated_at = excluded.updated_at`,
    )
      .bind(deviceId, user.id, now, now, now)
      .run();

    // Issue an access+refresh session bound to this user+device (Task 5 helper).
    const session = await issueSession(c.env.DB, {
      userId: user.id,
      deviceId,
      signingKey: c.env.JWT_SIGNING_KEY,
    });

    return c.json({
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
      expiresIn: 900,
      user: { id: user.id, email: user.email, displayName: user.display_name },
    });
  },
);

/**
 * POST /auth/apple
 * Verify the Sign-in-with-Apple identity token (RS256 against Apple's JWKS,
 * with iss/aud/exp + sha256(rawNonce)==nonce enforced), upsert the user keyed by
 * the stable Apple `sub` (auth_identities.provider='apple'). Apple only sends
 * fullName/email on the FIRST authorization, so we persist them only when
 * creating the user — later sign-ins never overwrite them. Register the
 * X-Device-Id device and issue a session. Verification failures surface as
 * 401 AUTH_INVALID_TOKEN.
 */
authRoutes.post("/apple", validate("json", appleBody), async (c) => {
  const { identityToken, rawNonce, fullName, email } = c.req.valid("json");

  // 1. Verify the Apple identity token (signature, iss, aud, exp, nonce).
  const claims = await verifyAppleIdentityToken(c.env, identityToken, rawNonce);
  const appleSub = claims.sub;
  // Prefer the client-supplied email (first-auth only); fall back to the token.
  const appleEmail = email ?? claims.email ?? null;

  const now = nowMs();

  // 2. Look up the existing apple identity. Present → reuse the user (no
  //    overwrite of first-auth name/email). Absent → create user + identity.
  const identity = await c.env.DB.prepare(
    "SELECT user_id FROM auth_identities WHERE provider = 'apple' AND subject = ?",
  )
    .bind(appleSub)
    .first<{ user_id: string }>();

  let userId: string;
  if (identity) {
    userId = identity.user_id;
  } else {
    userId = uuidv7();
    await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'free', ?, ?)`,
      ).bind(userId, appleEmail, appleEmail ? 1 : 0, fullName ?? null, now, now),
      c.env.DB.prepare(
        `INSERT INTO auth_identities (id, user_id, provider, subject, created_at)
         VALUES (?, ?, 'apple', ?, ?)`,
      ).bind(uuidv7(), userId, appleSub, now),
    ]);
  }

  // 3. Register / refresh the device (X-Device-Id is the install UUID).
  const deviceHeader = c.req.header("X-Device-Id");
  const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       user_id = excluded.user_id,
       last_seen_at = excluded.last_seen_at,
       updated_at = excluded.updated_at`,
  )
    .bind(deviceId, userId, now, now, now)
    .run();

  // 4. Issue an access+refresh session bound to this user+device (Task 5 helper).
  const session = await issueSession(c.env.DB, {
    userId,
    deviceId,
    signingKey: c.env.JWT_SIGNING_KEY,
  });

  // 5. Load the canonical user for the response envelope.
  const user = await c.env.DB.prepare(
    "SELECT id, email, display_name FROM users WHERE id = ?",
  )
    .bind(userId)
    .first<{ id: string; email: string | null; display_name: string | null }>();

  if (!user) throw new ApiError("INTERNAL", "User not found after upsert");

  return c.json({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresIn: 900,
    user: { id: user.id, email: user.email, displayName: user.display_name },
  });
});
