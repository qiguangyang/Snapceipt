import { Hono, type Context } from "hono";
import { zValidator } from "@hono/zod-validator";
import type { ZodSchema } from "zod";
import type { ValidationTargets } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { hashToken, signAccess } from "../lib/jwt";
import {
  issueSession,
  findSessionByRefreshHash,
  rotateSession,
  revokeSession,
  revokeSessionFamily,
} from "../lib/sessions";
import { sendMagicLinkEmail, sendSignInCode } from "../lib/email";
import { verifyAppleIdentityToken } from "../lib/apple";
import { requireAuth } from "../middleware/auth";
import { hashPassword, verifyPassword } from "../lib/password";
import {
  appleBody,
  magicLinkRequestBody,
  magicLinkVerifyBody,
  otpRequestBody,
  otpVerifyBody,
  refreshBody,
  passwordSetBody,
  passwordLoginBody,
} from "../schemas/auth";

/**
 * zValidator wrapper whose failure path throws the shared ApiError so the
 * onError handler emits the uniform 400 VALIDATION_FAILED envelope (the default
 * @hono/zod-validator behavior returns a bare 400 with the raw ZodError, which
 * would bypass our error contract).
 */
export function validate<T extends ZodSchema, Target extends keyof ValidationTargets>(
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
const MAGIC_LINK_BASE_URL = "https://api.snapceipt.cc/auth/magic";
// Superseded-refresh-hash retention for reuse detection == the 60-day refresh window.
const REFRESH_REUSE_TTL_SECONDS = 60 * 24 * 60 * 60;

// OTP sign-in code TTL — mirrors the email-change code window (account.ts).
const OTP_TTL_SECONDS = 600; // 10 minutes
const OTP_MAX_ATTEMPTS = 5;

/** Canonical form for email comparison + storage: trimmed + lowercased. */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** SHA-256 hex of the input — used to derive the KV key from the raw token. */
async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** 6-digit numeric sign-in code (zero-padded). Mirrors account.ts sixDigitCode. */
function sixDigitCode(): string {
  const n = (crypto.getRandomValues(new Uint32Array(1))[0] ?? 0) % 1_000_000;
  return n.toString().padStart(6, "0");
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
    const { email, deviceId } = c.req.valid("json");
    const normalized = normalizeEmail(email);

    const token = newMagicToken();
    const hash = await sha256Hex(token);

    // Device hint for binding: header wins, body is the fallback. Absent => no binding
    // (verify stays backward-compatible for already-minted tokens).
    const deviceHint = c.req.header("X-Device-Id") || deviceId || undefined;

    // Store only the hash; metadata carries the email + (optional) requesting device.
    await c.env.KV.put(`ml:${hash}`, "1", {
      expirationTtl: MAGIC_LINK_TTL_SECONDS,
      metadata: { email: normalized, createdAt: nowMs(), ...(deviceHint ? { deviceId: deviceHint } : {}) },
    });

    const link = `${MAGIC_LINK_BASE_URL}?token=${token}`;
    const e2e = c.env.E2E_TEST_MODE === "1";

    // Routed through the email seam (src/lib/email.ts) so tests can spy on it;
    // the real SendEmail binding isn't exercisable in the test runtime.
    // In E2E mode the local dev runtime has no real SendEmail binding, so a send
    // failure must not 500 the request — the harness gets the token via devToken
    // below, not via email. In production (e2e off) a send failure still surfaces.
    if (e2e) {
      try {
        await sendMagicLinkEmail(c.env, { to: normalized, link });
      } catch {
        // E2E-only: ignore the missing/failing local SendEmail binding.
      }
    } else {
      // Send in the background (waitUntil) so the request returns immediately — a slow or
      // failing email provider no longer blocks the client (which always gets 202 for
      // anti-enumeration and can't act on a send error anyway). Failures are logged.
      c.executionCtx.waitUntil(
        sendMagicLinkEmail(c.env, { to: normalized, link }).catch((err) => {
          console.error("magic-link email send failed", err);
        }),
      );
    }

    // E2E-ONLY SEAM — never enabled in production. When E2E_TEST_MODE === "1"
    // (only ever set by the e2e harness, never declared in wrangler.jsonc),
    // ALSO echo the raw token so a black-box HTTP client can finish the
    // magic-link flow without reading the email it can't access. Off by default:
    // the normal 202 carries NO body, so no token leaks unless explicitly opted in.
    if (e2e) {
      return c.json({ devToken: token }, 202);
    }

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

    const stored = await c.env.KV.getWithMetadata<{ email: string; deviceId?: string }>(key, "text");
    if (stored.value === null || !stored.metadata?.email) {
      // Unknown, already-consumed, or expired (KV TTL evicted it).
      throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired magic link");
    }

    // Single-use: delete before issuing so a replay can't double-consume. This
    // runs BEFORE the device-binding check, so a mismatched (intercepted) attempt
    // still burns the token — the legitimate requester must re-request or use OTP.
    await c.env.KV.delete(key);

    // Device binding (§21 same-device-only): when the token was minted with a
    // requesting-device hint, the redeemer MUST present the same X-Device-Id.
    // Tokens minted before this rollout carry no hint and stay redeemable anywhere.
    const boundDevice = stored.metadata.deviceId;
    if (boundDevice && c.req.header("X-Device-Id") !== boundDevice) {
      throw new ApiError("AUTH_DEVICE_MISMATCH", "This sign-in link can only be used on the device that requested it");
    }

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
 * POST /auth/otp/request
 * Cross-device fallback for the (now device-bound) magic link. Mint a 6-digit
 * code, store only its sha256 in KV under `oc:<sha256(email)>` (600s TTL,
 * {codeHash, email, attempts, expiresAtMs}), and email it. ALWAYS 202 (no
 * enumeration). Under E2E_TEST_MODE the code is echoed as devCode. The per-email
 * + per-IP "auth" rate-limit tier already covers this path.
 */
/** Mint a 6-digit code, store ONLY its sha256 in KV under `oc:<sha256(email)>` (600s TTL,
 *  {codeHash, email, attempts, expiresAtMs}), and email it (background send; E2E does a
 *  best-effort sync send). Returns the plaintext code so an E2E caller can echo it. Shared by
 *  /otp/request and the new-device MFA path of /password/login. */
async function sendOtpCode(c: Context<AppEnv>, normalized: string): Promise<string> {
  const code = sixDigitCode();
  const codeHash = await sha256Hex(code);
  const emailHash = await sha256Hex(normalized);
  const expiresAtMs = nowMs() + OTP_TTL_SECONDS * 1000;
  await c.env.KV.put(
    `oc:${emailHash}`,
    JSON.stringify({ codeHash, email: normalized, attempts: 0, expiresAtMs }),
    { expirationTtl: OTP_TTL_SECONDS },
  );
  if (c.env.E2E_TEST_MODE === "1") {
    try {
      await sendSignInCode(c.env, { to: normalized, code });
    } catch {
      // E2E-only: ignore the missing/failing local SendEmail binding.
    }
  } else {
    // Background send (waitUntil) so a slow/failing provider can't block the request.
    c.executionCtx.waitUntil(
      sendSignInCode(c.env, { to: normalized, code }).catch((err) => {
        console.error("otp email send failed", err);
      }),
    );
  }
  return code;
}

authRoutes.post("/otp/request", validate("json", otpRequestBody), async (c) => {
  const { email } = c.req.valid("json");
  const code = await sendOtpCode(c, normalizeEmail(email));
  if (c.env.E2E_TEST_MODE === "1") return c.json({ devCode: code }, 202);
  return c.body(null, 202);
});

/** Length-independent-only constant-time compare of two equal-length hex digests, so
 *  the OTP code check leaks no timing signal about how many leading bytes matched. */
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * POST /auth/otp/verify
 * Consume the 6-digit code (single-use, 5-attempt cap), upsert the user by email
 * (+ email auth_identity), register the redeemer's X-Device-Id device, and issue
 * a session — the same envelope as /magic-link/verify. Unknown/expired => 401
 * AUTH_INVALID_TOKEN; wrong code => 400 VALIDATION_FAILED until the attempt cap.
 */
authRoutes.post("/otp/verify", validate("json", otpVerifyBody), async (c) => {
  const { email, code } = c.req.valid("json");
  const normalized = normalizeEmail(email);
  const emailHash = await sha256Hex(normalized);
  const kvKey = `oc:${emailHash}`;

  const raw = await c.env.KV.get(kvKey);
  if (!raw) throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired sign-in code");
  const pending = JSON.parse(raw) as {
    codeHash: string;
    email: string;
    attempts: number;
    expiresAtMs: number;
  };

  if (!constantTimeEqual(await sha256Hex(code), pending.codeHash)) {
    const attempts = (pending.attempts ?? 0) + 1;
    if (attempts >= OTP_MAX_ATTEMPTS) {
      await c.env.KV.delete(kvKey);
      throw new ApiError("AUTH_INVALID_TOKEN", "Too many attempts, request a new code");
    }
    const ttl = Math.max(1, Math.ceil((pending.expiresAtMs - nowMs()) / 1000));
    await c.env.KV.put(kvKey, JSON.stringify({ ...pending, attempts }), { expirationTtl: ttl });
    throw new ApiError("VALIDATION_FAILED", "Incorrect code");
  }

  // Correct: single-use delete before issuing.
  await c.env.KV.delete(kvKey);

  const userEmail = normalizeEmail(pending.email);
  const now = nowMs();

  let user = await c.env.DB.prepare(
    "SELECT id, email, display_name FROM users WHERE email = ? AND deleted_at IS NULL",
  )
    .bind(userEmail)
    .first<{ id: string; email: string | null; display_name: string | null }>();

  if (!user) {
    const userId = uuidv7();
    await c.env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
       VALUES (?, ?, 1, NULL, 'free', ?, ?)`,
    )
      .bind(userId, userEmail, now, now)
      .run();
    user = { id: userId, email: userEmail, display_name: null };
  } else {
    await c.env.DB.prepare("UPDATE users SET email_verified = 1, updated_at = ? WHERE id = ?")
      .bind(now, user.id)
      .run();
  }

  await c.env.DB.prepare(
    `INSERT INTO auth_identities (id, user_id, provider, subject, created_at)
     VALUES (?, ?, 'email', ?, ?)
     ON CONFLICT(provider, subject) DO NOTHING`,
  )
    .bind(uuidv7(), user.id, userEmail, now)
    .run();

  // A correct 6-digit code TRUSTS this device, so a later password login here skips the MFA
  // challenge (and sign-up / passwordless code-login / new-device MFA all flow through here).
  const deviceHeader = c.req.header("X-Device-Id");
  const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, trusted_at, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       user_id = excluded.user_id,
       trusted_at = excluded.trusted_at,
       last_seen_at = excluded.last_seen_at,
       updated_at = excluded.updated_at`,
  )
    .bind(deviceId, user.id, now, now, now, now)
    .run();

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
});

/**
 * POST /auth/password/set (authenticated)
 * Set or change the signed-in user's password (min 8 chars). Used by sign-up (right after the
 * 6-digit code verifies the new account), the optional prompt for existing users, and password
 * changes. Trusts the device the password is set from (the user is already authenticated on it),
 * so a later password login there isn't re-challenged with a code.
 */
authRoutes.post("/password/set", requireAuth(), validate("json", passwordSetBody), async (c) => {
  const userId = c.var.userId;
  const { password } = c.req.valid("json");
  const now = nowMs();
  const hash = await hashPassword(password);
  await c.env.DB.prepare("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?")
    .bind(hash, now, userId)
    .run();
  const deviceId = c.req.header("X-Device-Id");
  if (deviceId && deviceId.length > 0) {
    await c.env.DB.prepare(
      "UPDATE devices SET trusted_at = COALESCE(trusted_at, ?), updated_at = ? WHERE id = ? AND user_id = ?",
    )
      .bind(now, now, deviceId, userId)
      .run();
  }
  return c.json({ ok: true });
});

/**
 * POST /auth/password/login (public)
 * Email + password. A missing account, missing password, or wrong password all return the same
 * 401 AUTH_INVALID_CREDENTIALS (no account enumeration). On a correct password:
 *  - TRUSTED device (verified before via a code) → issue a session.
 *  - NEW/untrusted device → email a 6-digit code and return { mfaRequired: true } with NO
 *    session; the client verifies it via /otp/verify, which trusts the device + issues the
 *    session (second factor on new devices, by default).
 */
authRoutes.post("/password/login", validate("json", passwordLoginBody), async (c) => {
  const { email, password } = c.req.valid("json");
  const normalized = normalizeEmail(email);

  const user = await c.env.DB.prepare(
    "SELECT id, email, display_name, password_hash FROM users WHERE email = ? AND deleted_at IS NULL",
  )
    .bind(normalized)
    .first<{ id: string; email: string | null; display_name: string | null; password_hash: string | null }>();

  if (!user || !user.password_hash || !(await verifyPassword(password, user.password_hash))) {
    throw new ApiError("AUTH_INVALID_CREDENTIALS", "Incorrect email or password");
  }

  const now = nowMs();
  const deviceHeader = c.req.header("X-Device-Id");
  const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();

  const device = await c.env.DB.prepare("SELECT trusted_at FROM devices WHERE id = ? AND user_id = ?")
    .bind(deviceId, user.id)
    .first<{ trusted_at: number | null }>();

  if (!device?.trusted_at) {
    const code = await sendOtpCode(c, normalized);
    const body: { mfaRequired: true; devCode?: string } = { mfaRequired: true };
    if (c.env.E2E_TEST_MODE === "1") body.devCode = code;
    return c.json(body);
  }

  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET last_seen_at = excluded.last_seen_at, updated_at = excluded.updated_at`,
  )
    .bind(deviceId, user.id, now, now, now)
    .run();

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
});

/**
 * GET /auth/magic — bridge page for the magic-link email.
 *
 * The email links to https://api.snapceipt.cc/auth/magic?token=… . This page
 * forwards the token to the registered custom scheme snapceipt://auth/verify?token=…
 * which the iOS app (AuthViewModel/MagicLinkParser) handles → POST /auth/magic-link/verify.
 * No verification happens here; the single-use, TTL-bound check is in /magic-link/verify.
 * Universal Links/AASA are out of scope for the go-live milestone, so this bridge is the
 * path from a tapped/opened https link to the app.
 *
 * Magic tokens are base64url ([A-Za-z0-9_-], see newMagicToken). We reject anything else
 * so the value is safe to interpolate and we never forward a malformed link.
 */
authRoutes.get("/magic", (c) => {
  const headers = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
  };
  const token = c.req.query("token") ?? "";
  if (token.length === 0 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    return c.html(
      `<!doctype html><meta charset="utf-8"><title>Snapceipt</title>` +
        `<p>This sign-in link is invalid or has expired. Request a new one from the Snapceipt app.</p>`,
      400,
      headers,
    );
  }
  const deep = `snapceipt://auth/verify?token=${token}`;
  return c.html(
    `<!doctype html><html><head><meta charset="utf-8">` +
      `<meta name="viewport" content="width=device-width, initial-scale=1">` +
      `<title>Signing in to Snapceipt…</title>` +
      `<meta http-equiv="refresh" content="0;url=${deep}">` +
      `<script>location.replace(${JSON.stringify(deep)});</script></head>` +
      `<body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:3rem 1.5rem">` +
      `<p>Opening Snapceipt…</p>` +
      `<p><a href="${deep}">Open in Snapceipt</a></p>` +
      `<p style="color:#666">Return to the Snapceipt app to finish signing in.</p>` +
      `</body></html>`,
    200,
    headers,
  );
});

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
  const { identityToken, rawNonce, fullName } = c.req.valid("json");

  // 1. Verify the Apple identity token (signature, iss, aud, exp, nonce).
  const claims = await verifyAppleIdentityToken(c.env, identityToken, rawNonce);
  const appleSub = claims.sub;

  // 1b. Single-use nonce: the verified nonce (sha256 of the client raw nonce, embedded
  // in the signed token) is consumed once, so a captured {identityToken, rawNonce} pair
  // can't be replayed within the token's ~10-min validity to mint extra sessions / bind
  // an attacker device. Mirrors the magic-link / OTP single-use discipline.
  if (claims.nonce) {
    const nonceKey = `apple_nonce:${claims.nonce}`;
    if (await c.env.KV.get(nonceKey)) {
      throw new ApiError("AUTH_INVALID_TOKEN", "Sign-in token already used");
    }
    await c.env.KV.put(nonceKey, "1", { expirationTtl: 900 });
  }
  // SECURITY: use ONLY the email from the cryptographically-verified identity
  // token — never the client-supplied `email` JSON field. Trusting the client
  // value would let any Apple ID register (and mark `email_verified`) under a
  // victim's address, enabling account pre-hijacking when the victim later signs
  // in by magic link to the same email. The body's `email`/`fullName` are
  // unverified client input; we keep `fullName` only as a display name.
  const appleEmail = claims.email ?? null;

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

/** KV namespace for superseded (already-rotated) refresh hashes — see /auth/refresh. */
const RETIRED_REFRESH_PREFIX = "rfr:";

/**
 * POST /auth/refresh
 * Public (no bearer): rotate an opaque refresh token. The presented token is
 * hashed and looked up via findSessionByRefreshHash, which resolves ONLY when the
 * row is non-revoked AND not expired. On a hit → rotate in place (new refresh,
 * slide the 60-day expiry, keep the same session id + family), mint a fresh access
 * token, and return the session envelope.
 *
 * Reuse detection: rotateSession OVERWRITES the refresh hash in place, so a
 * replayed old token's hash no longer exists in the sessions table. To still
 * catch reuse, every rotation records the just-superseded hash in KV
 * (`rfr:<hash>` -> family, 60-day TTL matching the refresh window). On a DB miss
 * we consult KV: a hit means an already-rotated token was replayed -> revoke the
 * whole family and answer 401 AUTH_SESSION_REVOKED. A revoked/expired live-table
 * miss with no KV record (e.g. a signed-out session) is also AUTH_SESSION_REVOKED
 * when the hash is still present on a (revoked) row; a hash that never existed is
 * 401 AUTH_INVALID_TOKEN.
 */
authRoutes.post("/refresh", validate("json", refreshBody), async (c) => {
  const { refreshToken } = c.req.valid("json");
  const presentedHash = await hashToken(refreshToken);

  // 1. Live session for this hash? (findSessionByRefreshHash filters revoked + expired.)
  const session = await findSessionByRefreshHash(c.env.DB, presentedHash);

  if (session) {
    // Record the soon-to-be-superseded hash BEFORE rotating, so that if KV.put
    // throws the old refresh token remains valid in D1 and the client can retry.
    await c.env.KV.put(`${RETIRED_REFRESH_PREFIX}${presentedHash}`, session.family, {
      expirationTtl: REFRESH_REUSE_TTL_SECONDS,
    });

    // ROTATE: new opaque refresh, slide the 60-day expiry, keep the same family.
    const rotated = await rotateSession(c.env.DB, session.id);

    const accessToken = await signAccess(c.env.JWT_SIGNING_KEY, {
      userId: session.user_id,
      sessionId: session.id,
      deviceId: session.device_id,
    });

    const user = await c.env.DB.prepare(
      "SELECT id, email, display_name FROM users WHERE id = ? AND deleted_at IS NULL",
    )
      .bind(session.user_id)
      .first<{ id: string; email: string | null; display_name: string | null }>();
    if (!user) throw new ApiError("AUTH_INVALID_TOKEN", "User not found");

    return c.json({
      accessToken,
      refreshToken: rotated.refreshToken,
      expiresIn: 900,
      user: { id: user.id, email: user.email, displayName: user.display_name },
    });
  }

  // 2. No live match. Reuse of an already-rotated token? KV remembers superseded
  //    hashes -> revoke the whole family and force re-auth.
  const retiredFamily = await c.env.KV.get(`${RETIRED_REFRESH_PREFIX}${presentedHash}`);
  if (retiredFamily) {
    await revokeSessionFamily(c.env.DB, retiredFamily);
    throw new ApiError("AUTH_SESSION_REVOKED", "Refresh token reuse detected");
  }

  // 3. Hash still present on a (revoked/expired) row — e.g. a signed-out session
  //    whose current refresh token is presented. The session is dead.
  const known = await c.env.DB.prepare("SELECT family FROM sessions WHERE refresh_hash = ?")
    .bind(presentedHash)
    .first<{ family: string }>();
  if (known) {
    throw new ApiError("AUTH_SESSION_REVOKED", "Session is no longer active");
  }

  // 4. Token never existed.
  throw new ApiError("AUTH_INVALID_TOKEN", "Invalid refresh token");
});

/**
 * POST /auth/signout
 * Bearer required (requireAuth sets c.var.sessionId from the JWT `sid` claim).
 * Revoke just the current session (single-device sign-out). Idempotent.
 */
authRoutes.post("/signout", requireAuth(), async (c) => {
  await revokeSession(c.env.DB, c.var.sessionId);
  return c.json({ ok: true });
});

/**
 * GET /auth/me
 * Bearer required: return the current user plus their active (non-deleted)
 * devices, scoped to c.var.userId.
 */
authRoutes.get("/me", requireAuth(), async (c) => {
  const userId = c.var.userId;

  const user = await c.env.DB.prepare(
    "SELECT id, email, display_name, plan FROM users WHERE id = ? AND deleted_at IS NULL",
  )
    .bind(userId)
    .first<{
      id: string;
      email: string | null;
      display_name: string | null;
      plan: string;
    }>();
  if (!user) throw new ApiError("NOT_FOUND", "User not found");

  const devices = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled, last_seen_at, created_at
       FROM devices
      WHERE user_id = ? AND deleted_at IS NULL
      ORDER BY created_at`,
  )
    .bind(userId)
    .all<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      apns_token: string | null;
      push_enabled: number;
      last_seen_at: number | null;
      created_at: number;
    }>();

  return c.json({
    user: {
      id: user.id,
      email: user.email,
      displayName: user.display_name,
      plan: user.plan,
    },
    devices: devices.results.map((d) => ({
      id: d.id,
      platform: d.platform,
      model: d.model,
      osVersion: d.os_version,
      hasApnsToken: d.apns_token !== null,
      pushEnabled: d.push_enabled === 1,
      lastSeenAt: d.last_seen_at,
      createdAt: d.created_at,
    })),
  });
});
