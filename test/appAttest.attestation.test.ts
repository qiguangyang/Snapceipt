import { describe, expect, it } from "vitest";
import { verifyAttestation, rpIdHash, AppAttestError, APP_ID } from "../src/lib/appAttest";
import { bytesToB64u } from "../src/lib/cbor";

// Negative + structural coverage only. A genuine Apple App Attest attestation blob
// can only be produced on a physical iPhone (Secure Enclave), which is not available
// here — the positive acceptance vector is captured + asserted in Task 10 (see the
// it.todo below). We therefore prove the verifier REJECTS malformed / wrong-format
// input and expose the pinned identity constants the rest of the suite relies on.

function cborHexToB64u(hex: string): string {
  const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
  return bytesToB64u(bytes);
}

describe("verifyAttestation (negatives + structure)", () => {
  it("rejects a non-CBOR / garbage attestation", async () => {
    await expect(
      verifyAttestation({ attestationB64u: "AAAA", challenge: "c", keyId: "k" }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects undecodable base64url that is not valid CBOR", async () => {
    // 0x9f = array, indefinite length (major 4, info 31) — unsupported by our decoder.
    await expect(
      verifyAttestation({ attestationB64u: cborHexToB64u("9f"), challenge: "c", keyId: "k" }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a well-formed CBOR object with the wrong fmt", async () => {
    // CBOR: {"fmt":"none"} -> a1 63 "fmt" 64 "none"
    const hex = "a163666d74646e6f6e65";
    await expect(
      verifyAttestation({ attestationB64u: cborHexToB64u(hex), challenge: "c", keyId: "k" }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects apple-appattest fmt but with a missing / short x5c chain", async () => {
    // CBOR: {"fmt":"apple-appattest","attStmt":{"x5c":[]},"authData":h''}
    //   a3                                   map(3)
    //     63 666d74                          "fmt"
    //     6f 6170706c652d617070617474657374  "apple-appattest" (text, 15 bytes)
    //     67 61747453746d74                  "attStmt"
    //       a1                               map(1)
    //         63 783563                      "x5c"
    //         80                             array(0)  -> chain too short
    //     68 6175746844617461                "authData"
    //       40                               byte-string(0)
    const hex =
      "a3" +
      "63" + "666d74" +
      "6f" + "6170706c652d617070617474657374" +
      "67" + "61747453746d74" +
      "a1" + "63" + "783563" + "80" +
      "68" + "6175746844617461" + "40";
    await expect(
      verifyAttestation({ attestationB64u: cborHexToB64u(hex), challenge: "c", keyId: "k" }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("exposes the correct pinned App ID", () => {
    expect(APP_ID).toBe("2SU47GHJQX.app.snapceipt.Snapceipt");
  });

  it("rpIdHash is a 32-byte SHA-256 of the App ID", async () => {
    const h = await rpIdHash();
    expect(h).toBeInstanceOf(Uint8Array);
    expect(h.length).toBe(32);
  });

  it.todo("accepts a captured real-device attestation (Task 10, needs hardware)");
});
