// Shared test helpers for the App Attest ASSERTION verifier.
//
// Unlike attestation (which needs a real Secure Enclave + Apple cert chain), an
// assertion is a plain ECDSA-P256 signature over a server-derived nonce. So we can
// mint genuine, end-to-end-valid assertions here from a self-signed WebCrypto keypair
// and prove verifyAssertion() accepts them — no Apple hardware involved.
//
// The pieces mirror what an iPhone produces:
//   authenticatorData = rpIdHash(32) || flags(1) || signCount(4 BE)
//   nonce             = SHA256(authData || SHA256(challenge || SHA256(body)))
//   assertion CBOR    = { "signature": <DER ECDSA sig>, "authenticatorData": <authData> }
// Apple's signature is DER-encoded; WebCrypto emits raw r||s, so rawToDerEcdsa() is the
// exact inverse of the verifier's derToRawEcdsa().

import { rpIdHash } from "../src/lib/appAttest";
import { bytesToB64u } from "../src/lib/cbor";

/** Concatenate byte arrays into a fresh Uint8Array. */
function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/**
 * Raw 64-byte ECDSA r||s (WebCrypto output) → DER `SEQUENCE { INTEGER r, INTEGER s }`
 * (Apple's on-the-wire format). Inverse of appAttest.derToRawEcdsa: strips each half's
 * fixed-width leading zeros to the minimal magnitude, and re-adds a single 0x00 pad
 * byte whenever the top bit is set so the DER INTEGER stays positive. For P-256 each
 * INTEGER is <= 33 bytes and the whole SEQUENCE < 128 bytes, so short-form lengths
 * are always sufficient.
 */
export function rawToDerEcdsa(raw64: Uint8Array): Uint8Array {
  if (raw64.length !== 64) throw new Error("rawToDerEcdsa: expected 64-byte r||s");
  const encodeInt = (fixed: Uint8Array): Uint8Array => {
    // Strip leading zero bytes down to the minimal magnitude (keep >=1 byte).
    let i = 0;
    while (i < fixed.length - 1 && fixed[i] === 0) i++;
    let v = fixed.subarray(i);
    // If the high bit is set the value would read as negative — prepend 0x00.
    if (v[0]! & 0x80) v = concat(Uint8Array.of(0x00), v);
    return concat(Uint8Array.of(0x02, v.length), v);
  };
  const r = encodeInt(raw64.subarray(0, 32));
  const s = encodeInt(raw64.subarray(32, 64));
  const body = concat(r, s);
  return concat(Uint8Array.of(0x30, body.length), body);
}

/**
 * Minimal CBOR encoder for exactly `{ "signature": <bytes>, "authenticatorData": <bytes> }`.
 * major-5 map(2); text keys via major-3; byte strings via major-2 using the 0x58 (1-byte
 * length) form for lengths in [24, 255] (both values here are ~37 and ~70 bytes). Key order
 * is irrelevant to the decoder, so we keep the natural order.
 */
export function encodeCborAssertion(authData: Uint8Array, sigDer: Uint8Array): Uint8Array {
  const textKey = (s: string): Uint8Array => {
    const b = new TextEncoder().encode(s);
    if (b.length >= 24) throw new Error("encodeCborAssertion: key too long for minimal encoder");
    return concat(Uint8Array.of(0x60 | b.length), b); // major 3 (text), short length
  };
  const byteStr = (b: Uint8Array): Uint8Array => {
    if (b.length < 24) return concat(Uint8Array.of(0x40 | b.length), b); // major 2, short length
    if (b.length <= 0xff) return concat(Uint8Array.of(0x58, b.length), b); // major 2, 1-byte length
    return concat(Uint8Array.of(0x59, (b.length >> 8) & 0xff, b.length & 0xff), b); // major 2, 2-byte length
  };
  return concat(
    Uint8Array.of(0xa2), // map(2)
    textKey("signature"),
    byteStr(sigDer),
    textKey("authenticatorData"),
    byteStr(authData),
  );
}

/**
 * Build the raw assertion pieces (authenticatorData + DER signature) the way an iPhone
 * would, computing the nonce EXACTLY as verifyAssertion does. `rpIdHashOverride` lets a
 * test forge a wrong-app authenticatorData while still producing a genuine signature over
 * it (so the test is robust to check ordering).
 */
export async function makeAssertionParts(opts: {
  challenge: string;
  body: Uint8Array;
  counter: number;
  privateKey: CryptoKey;
  rpIdHashOverride?: Uint8Array;
}): Promise<{ authData: Uint8Array; sigDer: Uint8Array; rawSig: Uint8Array; nonce: Uint8Array }> {
  const rp = opts.rpIdHashOverride ?? (await rpIdHash());
  const authData = new Uint8Array(37);
  authData.set(rp.subarray(0, 32), 0);
  authData[32] = 0; // flags
  new DataView(authData.buffer).setUint32(33, opts.counter, false); // big-endian signCount

  const bodyHash = new Uint8Array(await crypto.subtle.digest("SHA-256", opts.body));
  const clientDataHash = new Uint8Array(
    await crypto.subtle.digest("SHA-256", concat(new TextEncoder().encode(opts.challenge), bodyHash)),
  );
  const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(authData, clientDataHash)));

  const rawSig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, opts.privateKey, nonce),
  );
  const sigDer = rawToDerEcdsa(rawSig);
  return { authData, sigDer, rawSig, nonce };
}

/** Convenience wrapper: full valid assertion as base64url CBOR (Task-8 wire shape). */
export async function buildAssertion(opts: {
  challenge: string;
  body: Uint8Array;
  counter: number;
  privateKey: CryptoKey;
}): Promise<string> {
  const { authData, sigDer } = await makeAssertionParts(opts);
  return bytesToB64u(encodeCborAssertion(authData, sigDer));
}
