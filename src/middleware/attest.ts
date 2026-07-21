// App Attest ENFORCEMENT middleware + phased-rollout decision.
//
// Mounted on the six auth-bootstrap ENTRY routes (see src/routes/auth.ts). It
// verifies an App Attest ASSERTION when the client supplies one, records the
// result on the context (`c.var.attested`), and then — driven ENTIRELY by the
// pure `attestDecision` below — either lets the request through or rejects it
// with 401. The decision is factored out (no I/O) so the security-critical
// enforcement logic can be unit-tested exhaustively and reasoned about without
// standing up a worker.

import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { consumeChallenge } from "../lib/attestChallenge";
import { verifyAssertion, AppAttestError } from "../lib/appAttest";

/** Phased enforcement mode (env.ATTEST_MODE). See env.ts for the rollout ladder. */
export type AttestMode = "off" | "soft" | "enforce-new" | "enforce-all";

/**
 * Decide whether to reject an un-attested/attested request. PURE — no I/O, env,
 * or headers. This is the security-critical enforcement core; it is exhaustively
 * unit-tested so the phased rollout can be reasoned about deterministically.
 *
 *  - `off`         → always pass (the middleware also early-returns before any verify).
 *  - attested      → always pass (a valid assertion satisfies every mode).
 *  - `soft`        → pass (observe-only; the caller logs the miss).
 *  - `enforce-new` → reject ONLY when `build >= minBuild`; older/unknown installs are
 *                    exempt. A missing build is 0, which is `< ` any real minBuild, so exempt.
 *  - `enforce-all` → reject.
 */
export function attestDecision(
  mode: AttestMode,
  attested: boolean,
  build: number,
  minBuild: number,
): "pass" | "reject" {
  if (mode === "off") return "pass";
  if (attested) return "pass";
  if (mode === "soft") return "pass";
  if (mode === "enforce-new") return build >= minBuild ? "reject" : "pass";
  return "reject"; // enforce-all
}

/**
 * Verify an App Attest assertion (if present) and enforce per `env.ATTEST_MODE`.
 *
 * The raw request body is read via Hono's cached reader (`c.req.arrayBuffer()`),
 * which re-exposes the bytes so the downstream zod validator's `c.req.json()`
 * still parses from cache — reading here does NOT consume the body for the route.
 *
 * A verification FAILURE (bad/absent assertion, stale challenge, unknown key) is
 * never thrown from here: it sets `attested = false` and lets the mode decide,
 * so `off`/`soft`/older-build requests are unaffected. Only unexpected errors
 * (e.g. a DB outage) propagate as a 500.
 */
export function attestMiddleware(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const mode = (c.env.ATTEST_MODE ?? "off") as AttestMode;
    // Fast path: attestation disabled. Do NOT touch the body — leave it pristine
    // for the validator and add zero overhead to the default (off) deployment.
    if (mode === "off") return next();

    const keyId = c.req.header("X-Attest-Key-Id");
    const assertion = c.req.header("X-Attest-Assertion");
    const challenge = c.req.header("X-Attest-Challenge");
    // A missing/garbage build is 0, so it stays below any real ATTEST_MIN_BUILD.
    const build = Number(c.req.header("X-App-Build") ?? "0") || 0;
    const minBuild = Number(c.env.ATTEST_MIN_BUILD ?? "0") || 0;

    let attested = false;
    if (keyId && assertion && challenge) {
      try {
        // Cached read: the validator re-reads the same bytes via c.req.json().
        const rawBody = new Uint8Array(await c.req.arrayBuffer());
        // One-time challenge: unknown or already-used → not attested.
        if (!(await consumeChallenge(c.env.KV, challenge))) {
          throw new AppAttestError("attest: stale or unknown challenge");
        }
        const row = await c.env.DB.prepare(
          "SELECT public_key, sign_count FROM attest_keys WHERE key_id = ?",
        )
          .bind(keyId)
          .first<{ public_key: ArrayBuffer; sign_count: number }>();
        if (!row) throw new AppAttestError("attest: unknown keyId");
        const { newSignCount } = await verifyAssertion({
          assertionB64u: assertion,
          challenge,
          rawBody,
          publicKeyDer: new Uint8Array(row.public_key),
          storedSignCount: row.sign_count,
        });
        // Persist the advanced counter (replay defense) + touch last_used_at.
        await c.env.DB.prepare(
          "UPDATE attest_keys SET sign_count = ?, last_used_at = ? WHERE key_id = ?",
        )
          .bind(newSignCount, nowMs(), keyId)
          .run();
        attested = true;
      } catch (e) {
        // Verification failures are the mode's call, not a hard error here.
        if (!(e instanceof AppAttestError)) throw e;
        attested = false;
      }
    }

    c.set("attested", attested);

    // Observe-only visibility while we roll out: log the miss but never reject.
    if (mode === "soft" && !attested) {
      console.log("attest soft: unattested request", { path: c.req.path, build });
    }

    if (attestDecision(mode, attested, build, minBuild) === "reject") {
      throw new ApiError("AUTH_INVALID_TOKEN", "App verification required");
    }
    return next();
  };
}
