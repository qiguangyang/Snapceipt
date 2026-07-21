import {
  env,
  SELF,
  createExecutionContext,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { app } from "../src/app";
import { attestDecision, type AttestMode } from "../src/middleware/attest";
import { mintChallenge } from "../src/lib/attestChallenge";
import { buildAssertion } from "./appAttest.testutil";

afterEach(() => vi.restoreAllMocks());

// ────────────────────────────────────────────────────────────────────────────
// PART 1 — attestDecision: the PURE enforcement core, tested EXHAUSTIVELY.
//
// Every mode × attested{true,false} × build{<min, ==min, >min, ==0}, with the
// expected pass/reject hard-coded (NOT recomputed from the implementation, so the
// table can't drift into circularity). minBuild is fixed at 70. This is the
// deterministic, worker-free coverage of the security gate's logic.
// ────────────────────────────────────────────────────────────────────────────
describe("attestDecision (pure)", () => {
  const MIN = 70;
  const cases: Array<[AttestMode, boolean, number, "pass" | "reject"]> = [
    // off — attestation disabled; always pass.
    ["off", true, 60, "pass"],
    ["off", true, 70, "pass"],
    ["off", true, 80, "pass"],
    ["off", true, 0, "pass"],
    ["off", false, 60, "pass"],
    ["off", false, 70, "pass"],
    ["off", false, 80, "pass"],
    ["off", false, 0, "pass"],
    // soft — observe-only; always pass.
    ["soft", true, 60, "pass"],
    ["soft", true, 70, "pass"],
    ["soft", true, 80, "pass"],
    ["soft", true, 0, "pass"],
    ["soft", false, 60, "pass"],
    ["soft", false, 70, "pass"],
    ["soft", false, 80, "pass"],
    ["soft", false, 0, "pass"],
    // enforce-new — attested always passes; un-attested rejects iff build >= min.
    ["enforce-new", true, 60, "pass"],
    ["enforce-new", true, 70, "pass"],
    ["enforce-new", true, 80, "pass"],
    ["enforce-new", true, 0, "pass"],
    ["enforce-new", false, 60, "pass"], // older build → exempt
    ["enforce-new", false, 70, "reject"], // at the floor → enforced
    ["enforce-new", false, 80, "reject"], // above the floor → enforced
    ["enforce-new", false, 0, "pass"], // missing build (0) → exempt
    // enforce-all — attested passes; every un-attested request rejects.
    ["enforce-all", true, 60, "pass"],
    ["enforce-all", true, 70, "pass"],
    ["enforce-all", true, 80, "pass"],
    ["enforce-all", true, 0, "pass"],
    ["enforce-all", false, 60, "reject"],
    ["enforce-all", false, 70, "reject"],
    ["enforce-all", false, 80, "reject"],
    ["enforce-all", false, 0, "reject"],
  ];

  it.each(cases)(
    "mode=%s attested=%s build=%d → %s",
    (mode, attested, build, expected) => {
      expect(attestDecision(mode, attested, build, MIN)).toBe(expected);
    },
  );

  it("covers all 32 mode×attested×build combinations", () => {
    expect(cases).toHaveLength(32);
  });
});

// ────────────────────────────────────────────────────────────────────────────
// PART 2 — middleware mounted but INERT under the default (off) mode.
//
// vitest.config.ts / wrangler.test.jsonc declare NO ATTEST_MODE, so a real
// SELF.fetch runs the worker in "off": the middleware early-returns before it
// ever touches the body, so the six routes behave exactly as before.
// ────────────────────────────────────────────────────────────────────────────
describe("attestMiddleware — default off (SELF.fetch, ATTEST_MODE unset)", () => {
  it("un-attested POST /auth/otp/request still 202 (mounted but inert)", async () => {
    vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "off-mode@e.co" }),
    });
    expect(res.status).toBe(202);
  });

  it("a malformed body still 400 VALIDATION_FAILED (body/validation intact)", async () => {
    vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "not-an-email" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});

// ────────────────────────────────────────────────────────────────────────────
// PART 3 — enforcement paths, driven through app.fetch with an env OVERRIDE.
//
// FINDING (see report): mutating the cloudflare:test `env` before SELF.fetch does
// NOT propagate into the worker (SELF keeps its statically-bound vars). Calling
// app.fetch(req, { ...env, ATTEST_MODE }, ctx) DOES give reliable per-test control
// while keeping the real DB/KV bindings, so we exercise the live middleware + the
// full app stack (requestId, rate limit, router) deterministically.
// ────────────────────────────────────────────────────────────────────────────
type Hdrs = Record<string, string>;
async function fetchOtp(
  envOverride: Record<string, unknown>,
  headers: Hdrs,
  bodyStr: string,
): Promise<Response> {
  const ctx = createExecutionContext();
  const req = new Request("https://x/auth/otp/request", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: bodyStr,
  });
  const res = await app.fetch(req, envOverride as never, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}
const modeEnv = (mode: AttestMode, minBuild = "70") => ({
  ...env,
  ATTEST_MODE: mode,
  ATTEST_MIN_BUILD: minBuild,
});
const OTP_BODY = JSON.stringify({ email: "enf@e.co" });

describe("attestMiddleware — enforcement (app.fetch env override)", () => {
  beforeEach(() => {
    vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  });

  it("soft: un-attested → 202 (never rejects)", async () => {
    const res = await fetchOtp(modeEnv("soft"), {}, OTP_BODY);
    expect(res.status).toBe(202);
  });

  it("enforce-all: un-attested → 401 App verification required", async () => {
    const res = await fetchOtp(modeEnv("enforce-all"), {}, OTP_BODY);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("enforce-new: old build (X-App-Build below min) → EXEMPT → 202", async () => {
    const res = await fetchOtp(modeEnv("enforce-new"), { "X-App-Build": "60" }, OTP_BODY);
    expect(res.status).toBe(202);
  });

  it("enforce-new: missing X-App-Build (treated as 0) → EXEMPT → 202", async () => {
    const res = await fetchOtp(modeEnv("enforce-new"), {}, OTP_BODY);
    expect(res.status).toBe(202);
  });

  it("enforce-new: new build (X-App-Build at/above min) un-attested → 401", async () => {
    const res = await fetchOtp(modeEnv("enforce-new"), { "X-App-Build": "70" }, OTP_BODY);
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
});

// ────────────────────────────────────────────────────────────────────────────
// PART 4 — a genuine, self-signed VALID assertion end-to-end.
//
// Proves the middleware actually VERIFIES + PERSISTS (sign_count advances) AND —
// crucially — that reading the raw body in the middleware did NOT consume it: the
// downstream zod validator still parses the same bytes (202 on a valid body; 400
// VALIDATION_FAILED on a malformed-but-validly-signed body). Uses enforce-all so a
// valid assertion is the ONLY thing that can produce a non-401.
// ────────────────────────────────────────────────────────────────────────────
describe("attestMiddleware — valid assertion verifies, persists, and leaves the body readable", () => {
  const KEY_ID = "attest-mw-key";

  async function freshKeyPair(): Promise<{ pair: CryptoKeyPair; spki: Uint8Array }> {
    const pair = (await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    const spki = new Uint8Array(
      (await crypto.subtle.exportKey("spki", pair.publicKey)) as ArrayBuffer,
    );
    return { pair, spki };
  }

  async function seedKey(spki: Uint8Array, signCount = 0): Promise<void> {
    await env.DB.prepare("DELETE FROM attest_keys WHERE key_id = ?").bind(KEY_ID).run();
    await env.DB.prepare(
      "INSERT INTO attest_keys (key_id, device_id, public_key, sign_count, aaguid, created_at) VALUES (?,?,?,?,?,?)",
    )
      .bind(KEY_ID, "dev-1", spki, signCount, "appattest", Date.now())
      .run();
  }

  beforeEach(() => {
    vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  });

  it("enforce-all + valid assertion over a VALID body → 202 and sign_count advances 0→1", async () => {
    const { pair, spki } = await freshKeyPair();
    await seedKey(spki, 0);
    const challenge = await mintChallenge(env.KV);
    const bodyStr = JSON.stringify({ email: "attested@e.co" });
    const bodyBytes = new TextEncoder().encode(bodyStr);
    const assertion = await buildAssertion({
      challenge,
      body: bodyBytes,
      counter: 1,
      privateKey: pair.privateKey,
    });

    const res = await fetchOtp(
      modeEnv("enforce-all"),
      {
        "X-Attest-Key-Id": KEY_ID,
        "X-Attest-Assertion": assertion,
        "X-Attest-Challenge": challenge,
      },
      bodyStr,
    );
    expect(res.status).toBe(202); // route ran → validator re-read the same body

    const row = await env.DB.prepare("SELECT sign_count FROM attest_keys WHERE key_id = ?")
      .bind(KEY_ID)
      .first<{ sign_count: number }>();
    expect(row?.sign_count).toBe(1); // middleware verified + persisted the new counter
  });

  it("enforce-all + valid assertion over a MALFORMED body → attestation passes but validator still 400s", async () => {
    const { pair, spki } = await freshKeyPair();
    await seedKey(spki, 0);
    const challenge = await mintChallenge(env.KV);
    // A validly-SIGNED body that the otp schema rejects (email is not an email).
    const bodyStr = JSON.stringify({ email: "nope" });
    const bodyBytes = new TextEncoder().encode(bodyStr);
    const assertion = await buildAssertion({
      challenge,
      body: bodyBytes,
      counter: 1,
      privateKey: pair.privateKey,
    });

    const res = await fetchOtp(
      modeEnv("enforce-all"),
      {
        "X-Attest-Key-Id": KEY_ID,
        "X-Attest-Assertion": assertion,
        "X-Attest-Challenge": challenge,
      },
      bodyStr,
    );
    // NOT 401 (attestation succeeded) and NOT 500 (body was re-readable) → 400 from the validator.
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("enforce-all + STALE challenge (already consumed) → not attested → 401", async () => {
    const { pair, spki } = await freshKeyPair();
    await seedKey(spki, 0);
    const challenge = await mintChallenge(env.KV);
    const bodyStr = JSON.stringify({ email: "stale@e.co" });
    const bodyBytes = new TextEncoder().encode(bodyStr);
    const assertion = await buildAssertion({
      challenge,
      body: bodyBytes,
      counter: 1,
      privateKey: pair.privateKey,
    });
    // Burn the challenge before the request so consumeChallenge misses.
    await env.KV.delete(`att_chal:${challenge}`);

    const res = await fetchOtp(
      modeEnv("enforce-all"),
      {
        "X-Attest-Key-Id": KEY_ID,
        "X-Attest-Assertion": assertion,
        "X-Attest-Challenge": challenge,
      },
      bodyStr,
    );
    expect(res.status).toBe(401);
    const row = await env.DB.prepare("SELECT sign_count FROM attest_keys WHERE key_id = ?")
      .bind(KEY_ID)
      .first<{ sign_count: number }>();
    expect(row?.sign_count).toBe(0); // counter NOT advanced on a rejected assertion
  });
});
