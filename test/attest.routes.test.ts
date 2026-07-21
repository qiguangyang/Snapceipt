import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles);
// this includes 0019_attest_keys.sql, so the /verify upsert has a table to write.

describe("/attest routes", () => {
  it("challenge returns a token; verify rejects garbage", async () => {
    const ch = await SELF.fetch("https://x/attest/challenge");
    expect(ch.status).toBe(200);
    const { challenge } = (await ch.json()) as { challenge: string };
    expect(challenge.length).toBeGreaterThan(20);

    // Real minted challenge → consumeChallenge passes → we reach verifyAttestation,
    // which rejects the garbage attestation with an AppAttestError → 400.
    const v = await SELF.fetch("https://x/attest/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ keyId: "k", attestation: "AAAA", challenge }),
    });
    expect(v.status).toBe(400); // bad attestation
    const body = (await v.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("verify with a missing keyId → 400 VALIDATION_FAILED (before touching the challenge)", async () => {
    const ch = await SELF.fetch("https://x/attest/challenge");
    const { challenge } = (await ch.json()) as { challenge: string };

    const v = await SELF.fetch("https://x/attest/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ attestation: "AAAA", challenge }),
    });
    expect(v.status).toBe(400);
    const body = (await v.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("verify with an unknown challenge → 401 AUTH_INVALID_TOKEN", async () => {
    const v = await SELF.fetch("https://x/attest/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ keyId: "k", attestation: "AAAA", challenge: "never-minted-challenge" }),
    });
    expect(v.status).toBe(401);
    const body = (await v.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
});
