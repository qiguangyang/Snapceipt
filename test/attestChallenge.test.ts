import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { mintChallenge, consumeChallenge } from "../src/lib/attestChallenge";

describe("attest challenge", () => {
  it("mints then consumes exactly once", async () => {
    const c = await mintChallenge(env.KV);
    expect(c.length).toBeGreaterThan(20);
    expect(await consumeChallenge(env.KV, c)).toBe(true);
    expect(await consumeChallenge(env.KV, c)).toBe(false); // single-use
    expect(await consumeChallenge(env.KV, "never-issued")).toBe(false);
  });

  it("mints two different tokens", async () => {
    const a = await mintChallenge(env.KV);
    const b = await mintChallenge(env.KV);
    expect(a).not.toBe(b);
  });

  it("returns false (does not throw) for an unknown token", async () => {
    await expect(
      consumeChallenge(env.KV, "definitely-never-issued"),
    ).resolves.toBe(false);
  });
});
