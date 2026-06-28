/**
 * Cloudflare Worker bindings for the Snapceipt API.
 * Declared in wrangler.jsonc; injected as `c.env` at runtime.
 *
 * RECEIPTS / AI / EMAIL / DEEPSEEK_API_KEY are declared now but unused in the
 * foundation phase (receipt extraction, export, email-in, R2 images land later).
 */
export type Env = {
  /** D1 (SQLite) — source of truth for all syncable data. */
  DB: D1Database;
  /** R2 bucket for receipt images (unused this phase). */
  RECEIPTS: R2Bucket;
  /** R2 bucket for hourly D1 SQL dumps (ops backup; never read at request time). */
  BACKUPS: R2Bucket;
  /**
   * Secret: AES-256-GCM key material for the D1->R2 backup (L9 — the dump contains
   * password hashes + tokens, so it must not sit in R2 as plaintext). Any string; the
   * cron derives a 256-bit key via SHA-256(secret). When UNSET the backup is written
   * UNENCRYPTED (a warning is logged) so the cron never crashes before the secret is
   * provisioned. Set via `wrangler secret put BACKUP_ENCRYPTION_KEY`.
   */
  BACKUP_ENCRYPTION_KEY?: string;
  /** Workers AI binding for email-in OCR (unused this phase). */
  AI: Ai;
  /** KV: rate-limit counters + magic-link/nonce/JWKS cache. */
  KV: KVNamespace;
  /** Cloudflare Email Send binding (magic-link, exports). */
  EMAIL: SendEmail;
  /** Secret: HS256 signing key for app-issued JWTs. */
  JWT_SIGNING_KEY: string;
  /** Secret: DeepSeek API key. When empty/undefined, /extract uses the stub seam. */
  DEEPSEEK_API_KEY: string;
  /**
   * Var: DeepSeek model id used in the request body + echoed as meta.model.
   * Optional; the route falls back to "deepseek-v4-flash" when unset.
   */
  DEEPSEEK_MODEL?: string;
  /** Secret: Gemini API key — used by the email-in vision extractor (runGeminiVisionExtraction). */
  GEMINI_API_KEY: string;
  /**
   * Var: Gemini model id used in the generateContent URL + echoed as meta.model.
   * Optional; runGeminiVisionExtraction falls back to "gemini-3.1-flash-lite" when unset.
   */
  GEMINI_MODEL?: string;
  /** Var: Apple bundle id; Apple identityToken `aud` must equal this. */
  APPLE_BUNDLE_ID: string;
  /**
   * TEST-ONLY trust-anchor override for Apple JWS x5c verification. When unset
   * (production), the verifier pins the real AppleRootCA-G3 embedded in
   * src/lib/appleJws.ts. The test harness injects a self-generated root PEM here
   * so it can sign payloads with a test chain. MUST be undefined in production —
   * never declared in wrangler.jsonc.
   */
  APPLE_TRUST_ANCHOR_PEM?: string;
  /**
   * APNs auth-key (.p8 PKCS8 PEM). When undefined/empty, sendPush runs in STUB
   * mode: it logs and returns { stub: true } with no network call. Set via
   * `wrangler secret put APNS_KEY` once the key is provisioned.
   */
  APNS_KEY?: string;
  /** APNs auth-key id (the .p8 Key ID) — the JWT `kid` header. Optional => stub. */
  APNS_KEY_ID?: string;
  /** Apple developer Team ID — the JWT `iss` claim. Optional => stub. */
  APNS_TEAM_ID?: string;
  /**
   * Var: monthly smart-scan cap for free users (numeric string).
   * When unset, defaults to 10 (DEFAULT_CAP_FREE in src/lib/smartScan.ts).
   */
  SMART_SCAN_CAP_FREE?: string;
  /**
   * Var: monthly smart-scan cap for Pro users (numeric string).
   * When unset, defaults to 500 (DEFAULT_CAP_PRO in src/lib/smartScan.ts).
   */
  SMART_SCAN_CAP_PRO?: string;
  /**
   * E2E-ONLY test seam. When set to "1", POST /auth/magic-link/request ALSO
   * returns the raw magic-link token in its 202 body so a black-box HTTP client
   * can complete auth without reading the email. MUST be undefined in
   * production — it is never declared in wrangler.jsonc and is only injected by
   * the e2e harness (vitest.e2e.config.ts / unstable_dev vars). Optional so the
   * normal runtime + unit/integration tests run with it unset.
   */
  E2E_TEST_MODE?: string;
  /**
   * E2E-ONLY extraction seam. When set to "1", POST /extract skips the DeepSeek
   * network call and returns a deterministic stub from extractionHeuristic
   * (needsReview:false, confidence:0.9, meta.stub:true). Also auto-engaged when
   * DEEPSEEK_API_KEY is empty/undefined. MUST be undefined in production with a
   * real key — never declared in wrangler.jsonc; only injected by the e2e harness.
   */
  E2E_EXTRACT_MODE?: string;
  /**
   * E2E-ONLY email seam. When "1", the email-in OCR step returns a deterministic
   * stub instead of calling Workers AI, so the suite is hermetic. Also implicitly
   * engaged when the AI binding is absent. MUST be undefined in production.
   */
  E2E_EMAIL_MODE?: string;
  /**
   * App Review accommodation: the email of ONE demo account that may clear new-device 2FA with
   * the fixed code "123456" (so an App Store reviewer on a fresh device isn't blocked by the
   * emailed code). UNSET in normal production; set ONLY during a review. Only this account is
   * affected and the password is still required. Remove after approval.
   */
  REVIEW_DEMO_EMAIL?: string;
};

/**
 * Request-scoped values set by middleware (auth, requestId) and read by routes.
 * NEVER store these in module-level globals — keep them on the Hono context.
 */
export type Variables = {
  /** Authenticated user id (set by auth middleware). */
  userId: string;
  /** Device id bound to the session (set by auth middleware). */
  deviceId: string;
  /** Session id (JWT `sid` claim) bound to the access token (set by auth middleware). */
  sessionId: string;
  /** Per-request id for tracing + the error envelope. */
  requestId: string;
};

/** Convenience alias for typing `new Hono<AppEnv>()`. */
export type AppEnv = { Bindings: Env; Variables: Variables };
