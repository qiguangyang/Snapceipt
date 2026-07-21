import { describe, expect, it } from "vitest";
import { verifyAssertion, derToRawEcdsa, rpIdHash, AppAttestError } from "../src/lib/appAttest";
import { bytesToB64u } from "../src/lib/cbor";
import {
  buildAssertion,
  makeAssertionParts,
  encodeCborAssertion,
  rawToDerEcdsa,
} from "./appAttest.testutil";

// End-to-end assertion verification proven with a SELF-SIGNED P-256 keypair. Because an
// assertion is just an ECDSA signature over a server-derived nonce (no Apple cert chain),
// we can mint genuinely valid assertions here and exercise the full accept path plus every
// rejection branch. The DER<->raw round-trip (rawToDerEcdsa -> derToRawEcdsa) is what a real
// device + verifier do, so a passing accept case proves the byte plumbing too.

async function freshKeyPair(): Promise<{ pair: CryptoKeyPair; spki: Uint8Array }> {
  const pair = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const spki = new Uint8Array((await crypto.subtle.exportKey("spki", pair.publicKey)) as ArrayBuffer);
  return { pair, spki };
}

describe("verifyAssertion", () => {
  const challenge = "server-issued-challenge-abc123";
  const body = new TextEncoder().encode(JSON.stringify({ email: "x@y.z", n: 1 }));

  it("accepts a valid self-signed assertion (counter=1, storedSignCount=0)", async () => {
    const { pair, spki } = await freshKeyPair();
    const assertionB64u = await buildAssertion({ challenge, body, counter: 1, privateKey: pair.privateKey });

    const res = await verifyAssertion({
      assertionB64u,
      challenge,
      rawBody: body,
      publicKeyDer: spki,
      storedSignCount: 0,
    });
    expect(res).toEqual({ newSignCount: 1 });
  });

  it("advances across multiple assertions (counter must strictly increase)", async () => {
    const { pair, spki } = await freshKeyPair();
    const a1 = await buildAssertion({ challenge, body, counter: 5, privateKey: pair.privateKey });
    const first = await verifyAssertion({ assertionB64u: a1, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: 0 });
    expect(first.newSignCount).toBe(5);

    const a2 = await buildAssertion({ challenge, body, counter: 6, privateKey: pair.privateKey });
    const second = await verifyAssertion({ assertionB64u: a2, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: first.newSignCount });
    expect(second.newSignCount).toBe(6);
  });

  it("rejects a replay: counter equal to storedSignCount", async () => {
    const { pair, spki } = await freshKeyPair();
    const assertionB64u = await buildAssertion({ challenge, body, counter: 1, privateKey: pair.privateKey });
    await expect(
      verifyAssertion({ assertionB64u, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: 1 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a non-increasing counter (counter < storedSignCount)", async () => {
    const { pair, spki } = await freshKeyPair();
    const assertionB64u = await buildAssertion({ challenge, body, counter: 3, privateKey: pair.privateKey });
    await expect(
      verifyAssertion({ assertionB64u, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: 10 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a tampered body (signature is over the original nonce)", async () => {
    const { pair, spki } = await freshKeyPair();
    const assertionB64u = await buildAssertion({ challenge, body, counter: 1, privateKey: pair.privateKey });
    const otherBody = new TextEncoder().encode(JSON.stringify({ email: "x@y.z", n: 999 }));
    await expect(
      verifyAssertion({ assertionB64u, challenge, rawBody: otherBody, publicKeyDer: spki, storedSignCount: 0 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a wrong rpIdHash (authenticatorData bound to a different app)", async () => {
    const { pair, spki } = await freshKeyPair();
    const wrongRp = new Uint8Array(32).fill(0xab); // not SHA256(APP_ID)
    const { authData, sigDer } = await makeAssertionParts({
      challenge,
      body,
      counter: 1,
      privateKey: pair.privateKey,
      rpIdHashOverride: wrongRp,
    });
    const assertionB64u = bytesToB64u(encodeCborAssertion(authData, sigDer));
    await expect(
      verifyAssertion({ assertionB64u, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: 0 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a bad signature (a flipped byte in the DER signature)", async () => {
    const { pair, spki } = await freshKeyPair();
    const { authData, sigDer } = await makeAssertionParts({ challenge, body, counter: 1, privateKey: pair.privateKey });
    const badSig = sigDer.slice();
    const last = badSig.length - 1;
    badSig[last] = badSig[last]! ^ 0x01; // corrupt the last byte of s
    const assertionB64u = bytesToB64u(encodeCborAssertion(authData, badSig));
    await expect(
      verifyAssertion({ assertionB64u, challenge, rawBody: body, publicKeyDer: spki, storedSignCount: 0 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });

  it("rejects a CBOR map missing the required byte-string fields", async () => {
    // {"signature": 1, "authenticatorData": 2} — numbers, not byte strings.
    // a2 69 "signature" 01 71 "authenticatorData" 02
    const hex = "a2" + "69" + "7369676e6174757265" + "01" + "71" + "61757468656e74696361746f7244617461" + "02";
    const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
    await expect(
      verifyAssertion({ assertionB64u: bytesToB64u(bytes), challenge, rawBody: body, publicKeyDer: new Uint8Array(91), storedSignCount: 0 }),
    ).rejects.toBeInstanceOf(AppAttestError);
  });
});

describe("derToRawEcdsa <-> rawToDerEcdsa round-trip", () => {
  it("is a faithful inverse for a real signature (incl. high-bit / leading-zero halves)", async () => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("round-trip")));
    const rawSig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, nonce));
    const der = rawToDerEcdsa(rawSig);
    const back = derToRawEcdsa(der);
    expect(back).toEqual(rawSig);
    // And crucially the DER we produce verifies against the original raw signature.
    expect(
      await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, derToRawEcdsa(der), nonce),
    ).toBe(true);
  });
});
