import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { mintChallenge, consumeChallenge } from "../lib/attestChallenge";
import { verifyAttestation, AppAttestError } from "../lib/appAttest";

/**
 * App Attest bootstrap endpoints. Both are in PUBLIC_PATHS (no bearer token) since
 * a device attests BEFORE it has any session:
 *  - GET  /attest/challenge → { challenge }         (one-time, 120s TTL, KV-backed)
 *  - POST /attest/verify   { keyId, attestation, challenge } → { ok: true }
 *      Verifies the Apple attestation against the fresh challenge and, on success,
 *      upserts the attested public key into attest_keys (Task 5 checks later
 *      assertions against it).
 */
export const attestRoutes = new Hono<AppEnv>();

attestRoutes.get("/challenge", async (c) => {
  return c.json({ challenge: await mintChallenge(c.env.KV) });
});

attestRoutes.post("/verify", async (c) => {
  const body = (await c.req.json().catch(() => null)) as
    | { keyId?: string; attestation?: string; challenge?: string }
    | null;
  if (!body?.keyId || !body.attestation || !body.challenge) {
    throw new ApiError("VALIDATION_FAILED", "keyId, attestation, challenge required");
  }

  // One-time challenge: unknown or already-used → reject before any crypto work.
  if (!(await consumeChallenge(c.env.KV, body.challenge))) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Unknown or used challenge");
  }

  let result;
  try {
    result = await verifyAttestation({
      attestationB64u: body.attestation,
      challenge: body.challenge,
      keyId: body.keyId,
    });
  } catch (e) {
    // A verification failure is a client error; anything else propagates as 500.
    if (e instanceof AppAttestError) throw new ApiError("VALIDATION_FAILED", "Attestation failed");
    throw e;
  }

  const deviceId = c.req.header("X-Device-Id") ?? null;
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO attest_keys (key_id, device_id, public_key, sign_count, aaguid, created_at, last_used_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(key_id) DO UPDATE SET device_id = excluded.device_id, last_used_at = excluded.last_used_at`,
  )
    .bind(result.keyId, deviceId, result.publicKeyDer, result.signCount, result.aaguid, now, now)
    .run();

  return c.json({ ok: true });
});
