import { beforeAll, describe, expect, it } from "vitest";
import { verifyAppleSignedPayload, AppleJwsError } from "../src/lib/appleJws";
import { makeTestChain, signAsLeaf, type TestChain } from "./helpers/appleChain";

// The verifier embeds the REAL AppleRootCA-G3 as its default trust anchor; tests
// inject their own test-chain root via opts.trustAnchorPEM so no real Apple
// signing is required.
let chain: TestChain;
let trustAnchorPEM: string;

beforeAll(async () => {
  chain = await makeTestChain();
  trustAnchorPEM = chain.rootCertPem;
});

describe("verifyAppleSignedPayload", () => {
  it("returns the decoded payload for a valid chain + signature", async () => {
    const jws = await signAsLeaf(chain, { productId: "p", originalTransactionId: "1000" });
    const out = await verifyAppleSignedPayload<{ productId: string; originalTransactionId: string }>(
      jws,
      { trustAnchorPEM },
    );
    expect(out.productId).toBe("p");
    expect(out.originalTransactionId).toBe("1000");
  });

  it("THROWS when the payload is tampered (signature no longer matches)", async () => {
    const jws = await signAsLeaf(chain, { productId: "p", originalTransactionId: "1000" });
    // Swap the payload segment for a re-encoded, mutated one — same header + sig.
    const [h, , s] = jws.split(".");
    const tamperedPayload = btoa(JSON.stringify({ productId: "p", originalTransactionId: "EVIL" }))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    const tampered = `${h}.${tamperedPayload}.${s}`;
    await expect(verifyAppleSignedPayload(tampered, { trustAnchorPEM })).rejects.toBeInstanceOf(AppleJwsError);
  });

  it("THROWS when the chain root is not the trust anchor (untrusted root)", async () => {
    const jws = await signAsLeaf(chain, { productId: "p" });
    // A DIFFERENT chain → its root != our trust anchor.
    const otherRoot = (await makeTestChain()).rootCertPem;
    await expect(verifyAppleSignedPayload(jws, { trustAnchorPEM: otherRoot })).rejects.toBeInstanceOf(
      AppleJwsError,
    );
  });

  it("THROWS when the leaf cert is expired (nowMs past notAfter)", async () => {
    const expiredChain = await makeTestChain({
      leafNotBefore: new Date(Date.now() - 120_000),
      leafNotAfter: new Date(Date.now() - 60_000), // already expired
    });
    const jws = await signAsLeaf(expiredChain, { productId: "p" });
    await expect(
      verifyAppleSignedPayload(jws, { trustAnchorPEM: expiredChain.rootCertPem }),
    ).rejects.toBeInstanceOf(AppleJwsError);
  });

  it("THROWS when the leaf is signed by a key OUTSIDE the presented chain", async () => {
    // Build a forged x5c: a valid-looking leaf cert from chain A, but the JWS is
    // signed by chain B's leaf key. The signature won't verify against chain A's
    // leaf public key.
    const chainB = await makeTestChain();
    const forgedJws = await signAsLeaf(
      { ...chain, leafPrivateKeyPkcs8Pem: chainB.leafPrivateKeyPkcs8Pem },
      { productId: "p" },
    );
    await expect(verifyAppleSignedPayload(forgedJws, { trustAnchorPEM })).rejects.toBeInstanceOf(
      AppleJwsError,
    );
  });

  it("THROWS when the intermediate is not actually issued by the chain root (broken link)", async () => {
    // Splice chain A's leaf + intermediate onto chain B's root in the x5c. The
    // intermediate is NOT issued by B's root → chain validation must fail.
    const chainB = await makeTestChain();
    const splicedX5c: string[] = [chain.x5c[0]!, chain.x5c[1]!, chainB.x5c[2]!];
    const jws = await signAsLeaf({ ...chain, x5c: splicedX5c }, { productId: "p" });
    // Trust anchor = chain B's root (matches the x5c root) so we get past the
    // anchor-equality check and hit the issued-by link check.
    await expect(
      verifyAppleSignedPayload(jws, { trustAnchorPEM: chainB.rootCertPem }),
    ).rejects.toBeInstanceOf(AppleJwsError);
  });

  it("THROWS on a malformed JWS / missing x5c header", async () => {
    await expect(verifyAppleSignedPayload("not.a.jws", { trustAnchorPEM })).rejects.toBeInstanceOf(
      AppleJwsError,
    );
  });

  it("uses the real AppleRootCA-G3 as the default trust anchor (rejects the test chain)", async () => {
    // With no trustAnchorPEM override, the verifier pins Apple's real root — our
    // test chain's root is not it, so verification must fail closed.
    const jws = await signAsLeaf(chain, { productId: "p" });
    await expect(verifyAppleSignedPayload(jws, {})).rejects.toBeInstanceOf(AppleJwsError);
  });
});
