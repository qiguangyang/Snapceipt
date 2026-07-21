// Apple App Attest — ATTESTATION verifier.
//
// When an iPhone first generates an App Attest key in the Secure Enclave it can
// produce a one-time ATTESTATION object (CBOR) proving the key is hardware-backed,
// bound to THIS app (App ID), and fresh (server challenge). We verify it per Apple's
// "Validating Apps That Connect to Your Server" algorithm and return the attested
// public key so later assertions (Task 5) can be checked against it.
//
// RUNTIME NOTE: like src/lib/appleJws.ts, node:crypto's X509Certificate cannot do
// the cryptographic chain check on workerd (its EC publicKey getter throws and
// checkIssued() is DN-only). We use @peculiar/x509, whose cert.verify({publicKey})
// performs a real ECDSA signature verification and works inside workerd. The private
// helpers here (certFromDer/certFromPem, issuedBy, isWithinValidity) mirror
// appleJws.ts intentionally — this file does not modify or depend on that one.

import "reflect-metadata"; // tsyringe (peculiar's DI) needs the reflect polyfill
import * as x509 from "@peculiar/x509";
import { decodeCbor, b64uToBytes, bytesToB64u } from "./cbor";

// Bind peculiar to the runtime WebCrypto (workerd / Node both expose `crypto`).
x509.cryptoProvider.set(crypto as unknown as Crypto);

/** Thrown for ANY attestation verification failure (bad CBOR, wrong format, broken
 *  chain, untrusted root, nonce/rpId/keyId mismatch, expired cert). Callers reject
 *  the request and do NOT persist the key on this error. */
export class AppAttestError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "AppAttestError";
  }
}

/** Our Apple App ID: `<TeamID>.<bundle id>`. rpIdHash in authData must equal
 *  SHA-256 of this exact string. */
export const APP_ID = "2SU47GHJQX.app.snapceipt.Snapceipt";

/**
 * Apple App Attest Root CA — the public, self-signed root that anchors App Attest
 * credential-certificate chains. This is a DIFFERENT root than appleJws.ts's Apple
 * Root CA - G3. Source (public, not a secret):
 * https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
 * Subject/Issuer CN: "Apple App Attestation Root CA" (Apple Inc., California).
 */
export const APPLE_APP_ATTEST_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

/** SHA-256 over the concatenation of its parts. */
async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    buf.set(p, o);
    o += p.length;
  }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
}

/** SHA-256 of the pinned App ID (the expected rpIdHash in authData). */
export async function rpIdHash(): Promise<Uint8Array> {
  return sha256(new TextEncoder().encode(APP_ID));
}

/** Constant-time byte comparison (length + XOR accumulator). */
function eq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i]! ^ b[i]!;
  return d === 0;
}

/** Wrap a base64-DER cert (from x5c) into a peculiar X509Certificate. */
function certFromDer(der: Uint8Array): x509.X509Certificate {
  try {
    return new x509.X509Certificate(der);
  } catch (cause) {
    throw new AppAttestError("attest: invalid x5c certificate (not parseable DER)", { cause });
  }
}

/** Wrap the pinned root PEM into a peculiar X509Certificate. */
function certFromPem(pem: string): x509.X509Certificate {
  try {
    return new x509.X509Certificate(pem);
  } catch (cause) {
    throw new AppAttestError("attest: invalid pinned root PEM", { cause });
  }
}

/** True iff `nowMs` falls within [notBefore, notAfter] of `cert`. */
function isWithinValidity(cert: x509.X509Certificate, nowMs: number): boolean {
  return nowMs >= cert.notBefore.getTime() && nowMs <= cert.notAfter.getTime();
}

/** Cryptographically verify that `child` was signed by `issuer`'s key. */
async function issuedBy(child: x509.X509Certificate, issuer: x509.X509Certificate): Promise<boolean> {
  try {
    return await child.verify({ publicKey: await issuer.publicKey.export() });
  } catch {
    return false;
  }
}

/**
 * Extract the 32-byte nonce from the Apple App Attest credential cert extension
 * (OID 1.2.840.113635.100.8.2). The extension's octet-string value wraps
 * `SEQUENCE { [1] OCTET STRING nonce }`. We locate the OID's DER bytes, then read
 * the innermost 32-byte OCTET STRING (`04 20 <32 bytes>`) that follows it. Scanning
 * forward for `04 20` is a robust, allocation-free way to reach the nonce without a
 * full ASN.1 parser.
 *
 * BYTE-FORMAT ASSUMPTION (real-device confirmation deferred to Task 10): that the
 * FIRST `04 20 ..` occurring after the OID is exactly the nonce OCTET STRING.
 */
export function extractAppAttestNonce(certDer: Uint8Array): Uint8Array {
  // OID 1.2.840.113635.100.8.2 encoded as DER: 06 09 2A 86 48 86 F7 63 64 08 02
  // (the length byte is 0x09 = 9 content bytes: 2a 86 48 86 f7 63 64 08 02).
  const oid = Uint8Array.from([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]);
  let i = -1;
  outer: for (let p = 0; p + oid.length <= certDer.length; p++) {
    for (let k = 0; k < oid.length; k++) if (certDer[p + k] !== oid[k]) continue outer;
    i = p;
    break;
  }
  if (i < 0) throw new AppAttestError("attest: nonce extension OID not found");
  // After the OID: OCTET STRING (extnValue) -> SEQUENCE -> [1] OCTET STRING (32 bytes).
  let p = i + oid.length;
  while (p + 2 <= certDer.length) {
    if (certDer[p] === 0x04 && certDer[p + 1] === 0x20 && p + 2 + 32 <= certDer.length) {
      return certDer.subarray(p + 2, p + 2 + 32).slice();
    }
    p++;
  }
  throw new AppAttestError("attest: nonce octet-string not found");
}

/** Big-endian read of a 4-byte unsigned int at `off`. */
function readU32BE(b: Uint8Array, off: number): number {
  return ((b[off]! << 24) | (b[off + 1]! << 16) | (b[off + 2]! << 8) | b[off + 3]!) >>> 0;
}

export interface AttestationResult {
  /** base64url of SHA-256(EC public-key point) — the App Attest key identifier. */
  keyId: string;
  /** Leaf cert SubjectPublicKeyInfo DER — importable via crypto.subtle.importKey("spki", ...). */
  publicKeyDer: Uint8Array;
  /** Attestation sign counter — always 0 at attestation time. */
  signCount: number;
  /** "appattest" (production) or "appattestdevelop" (development). */
  aaguid: string;
}

/**
 * Verify an Apple App Attest ATTESTATION blob and return the attested public key.
 *
 * @throws {AppAttestError} on ANY failure — callers MUST treat this as a hard
 *   rejection (do not persist the key; respond 4xx).
 */
export async function verifyAttestation(args: {
  attestationB64u: string;
  challenge: string;
  keyId: string;
}): Promise<AttestationResult> {
  // 1. Decode CBOR and validate the top-level shape.
  let obj: unknown;
  try {
    obj = decodeCbor(b64uToBytes(args.attestationB64u));
  } catch (cause) {
    throw new AppAttestError("attest: attestation is not valid CBOR", { cause });
  }
  if (!obj || typeof obj !== "object") throw new AppAttestError("attest: attestation is not a CBOR object");
  const att = obj as Record<string, unknown>;
  if (att.fmt !== "apple-appattest") throw new AppAttestError(`attest: unexpected fmt '${String(att.fmt)}'`);
  const attStmt = att.attStmt as Record<string, unknown> | undefined;
  if (!attStmt || typeof attStmt !== "object") throw new AppAttestError("attest: missing attStmt");
  const x5c = attStmt.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2 || !x5c.every((c) => c instanceof Uint8Array)) {
    throw new AppAttestError("attest: attStmt.x5c must be an array of >=2 DER certs");
  }
  const authData = att.authData;
  if (!(authData instanceof Uint8Array)) throw new AppAttestError("attest: authData missing or not a byte string");
  // Fixed prefix: rpIdHash(32) + flags(1) + signCount(4) + aaguid(16) + credIdLen(2) = 55 bytes.
  if (authData.length < 55) throw new AppAttestError("attest: authData too short");

  // 2. Chain: credCert <- intermediate <- pinned Apple App Attest Root CA. Real
  //    ECDSA signature checks (not DN matching), and every cert within validity.
  const nowMs = Date.now();
  const credCert = certFromDer(x5c[0] as Uint8Array);
  const intermediate = certFromDer(x5c[1] as Uint8Array);
  const root = certFromPem(APPLE_APP_ATTEST_ROOT_CA);
  if (!(await issuedBy(credCert, intermediate))) {
    throw new AppAttestError("attest: credential cert is not signed by the presented intermediate");
  }
  if (!(await issuedBy(intermediate, root))) {
    throw new AppAttestError("attest: intermediate is not signed by the pinned App Attest root");
  }
  for (const [label, cert] of [
    ["credCert", credCert],
    ["intermediate", intermediate],
    ["root", root],
  ] as const) {
    if (!isWithinValidity(cert, nowMs)) {
      throw new AppAttestError(`attest: ${label} certificate is outside its validity window`);
    }
  }

  // 3. nonce = SHA256(authData || SHA256(challenge)).
  const clientDataHash = await sha256(new TextEncoder().encode(args.challenge));
  const computedNonce = await sha256(authData, clientDataHash);

  // 4. Compare the computed nonce to the credCert's App Attest nonce extension.
  const certNonce = extractAppAttestNonce(new Uint8Array(credCert.rawData));
  if (!eq(computedNonce, certNonce)) throw new AppAttestError("attest: nonce mismatch");

  // 5. rpIdHash (authData[0..32)) must equal SHA256(APP_ID).
  const rp = authData.subarray(0, 32);
  if (!eq(rp, await rpIdHash())) throw new AppAttestError("attest: rpIdHash mismatch");

  // 6. signCount (authData[33..37), big-endian) must be 0 at attestation time.
  const counter = readU32BE(authData, 33);
  if (counter !== 0) throw new AppAttestError("attest: initial signCount != 0");

  // 7. aaguid (authData[37..53)) must be "appattest" (prod) or "appattestdevelop" (dev).
  const aaguidBytes = authData.subarray(37, 53);
  const aaguid = new TextDecoder().decode(aaguidBytes).replace(/\0+$/, "");
  if (aaguid !== "appattest" && aaguid !== "appattestdevelop") {
    throw new AppAttestError(`attest: unexpected aaguid '${aaguid}'`);
  }

  // 8. credentialId: 2-byte big-endian length at [53..55) then the id.
  const credIdLen = (authData[53]! << 8) | authData[54]!;
  if (55 + credIdLen > authData.length) throw new AppAttestError("attest: credentialId length overruns authData");
  const credentialId = authData.subarray(55, 55 + credIdLen);

  // 9. keyId = SHA256(EC public-key point). The point is the uncompressed
  //    ANSI X9.63 form (0x04 || X || Y) = the last 65 bytes of the SPKI DER for
  //    P-256. It must equal BOTH the authData credentialId AND the client keyId.
  //
  //    BYTE-FORMAT ASSUMPTION (Task 10): that the leaf key is P-256, so its SPKI
  //    DER ends in exactly the 65-byte 0x04||X||Y point.
  const publicKeyDer = new Uint8Array(credCert.publicKey.rawData); // SubjectPublicKeyInfo DER
  if (publicKeyDer.length < 65 || publicKeyDer[publicKeyDer.length - 65] !== 0x04) {
    throw new AppAttestError("attest: leaf public key is not an uncompressed P-256 point");
  }
  const ecPoint = publicKeyDer.subarray(publicKeyDer.length - 65);
  const keyIdBytes = await sha256(ecPoint);
  if (!eq(keyIdBytes, credentialId)) throw new AppAttestError("attest: keyId != credentialId");
  const keyId = bytesToB64u(keyIdBytes);
  // Constant-time compare of the derived keyId string against the client-declared one.
  const derivedKeyIdBytes = new TextEncoder().encode(keyId);
  const claimedKeyIdBytes = new TextEncoder().encode(args.keyId);
  if (!eq(derivedKeyIdBytes, claimedKeyIdBytes)) throw new AppAttestError("attest: keyId != client keyId");

  // 10. Return the trusted key material for storage (Task 5 verifies assertions against it).
  return { keyId, publicKeyDer, signCount: 0, aaguid };
}

/**
 * DER-encoded ECDSA signature (`SEQUENCE { INTEGER r, INTEGER s }`) → raw 64-byte
 * `r || s`, the fixed-width form WebCrypto's `crypto.subtle.verify` expects. Apple
 * emits assertion signatures in DER; each INTEGER may carry a DER leading-zero pad
 * (added when the high bit is set) which we strip, then left-pad each half to 32
 * bytes. For P-256 signatures the SEQUENCE and INTEGER lengths are always short-form
 * (< 128 bytes), so a 1-byte length read is sufficient.
 */
export function derToRawEcdsa(der: Uint8Array): Uint8Array {
  if (der[0] !== 0x30) throw new AppAttestError("assert: bad DER (not a SEQUENCE)");
  let p = 2; // skip SEQUENCE tag + short-form length byte
  if (der[1]! & 0x80) p = 2 + (der[1]! & 0x7f); // (defensive) long-form SEQUENCE length
  const readInt = (): Uint8Array => {
    if (der[p] !== 0x02) throw new AppAttestError("assert: bad DER integer");
    const len = der[p + 1]!;
    p += 2;
    let v = der.subarray(p, p + len);
    p += len;
    while (v.length > 32 && v[0] === 0) v = v.subarray(1); // strip DER leading-zero pad
    if (v.length > 32) throw new AppAttestError("assert: DER integer too large for P-256");
    return v;
  };
  const r = readInt();
  const s = readInt();
  const out = new Uint8Array(64);
  out.set(r, 32 - r.length); // left-pad each half to 32 bytes
  out.set(s, 64 - s.length);
  return out;
}

/**
 * Verify an Apple App Attest ASSERTION and enforce the anti-replay sign counter.
 *
 * An assertion is a plain ECDSA-P256 signature (from the previously-attested key) over
 * `nonce = SHA256(authenticatorData || SHA256(challenge || SHA256(rawBody)))`, wrapped in a
 * CBOR map `{ signature, authenticatorData }`. We recompute that nonce, verify the signature
 * against the stored public key, confirm the assertion is bound to OUR app (rpIdHash), and
 * require the sign counter to strictly increase over what we last stored (replay defense).
 *
 * @throws {AppAttestError} on ANY failure — bad shape, rpIdHash mismatch, non-increasing
 *   counter, or invalid signature. Callers MUST reject the request and NOT advance the
 *   stored counter on error.
 */
export async function verifyAssertion(args: {
  assertionB64u: string;
  challenge: string;
  rawBody: Uint8Array;
  publicKeyDer: Uint8Array;
  storedSignCount: number;
}): Promise<{ newSignCount: number }> {
  // 1. Decode CBOR and require the two byte-string fields.
  let obj: unknown;
  try {
    obj = decodeCbor(b64uToBytes(args.assertionB64u));
  } catch (cause) {
    throw new AppAttestError("assert: assertion is not valid CBOR", { cause });
  }
  if (!obj || typeof obj !== "object") throw new AppAttestError("assert: assertion is not a CBOR object");
  const a = obj as Record<string, unknown>;
  const sigDer = a.signature;
  const authData = a.authenticatorData;
  if (!(sigDer instanceof Uint8Array) || !(authData instanceof Uint8Array)) {
    throw new AppAttestError("assert: signature/authenticatorData missing or not byte strings");
  }
  // authenticatorData = rpIdHash(32) + flags(1) + signCount(4).
  if (authData.length < 37) throw new AppAttestError("assert: authenticatorData too short");

  // 2. rpIdHash (authData[0..32)) must equal SHA256(APP_ID) — constant-time compare.
  if (!eq(authData.subarray(0, 32), await rpIdHash())) throw new AppAttestError("assert: rpIdHash mismatch");

  // 3. signCount (authData[33..37), big-endian) must strictly exceed the stored value.
  const counter = readU32BE(authData, 33);
  if (counter <= args.storedSignCount) throw new AppAttestError("assert: counter not increasing (replay)");

  // 4. nonce = SHA256(authData || SHA256(challenge || SHA256(rawBody))).
  const bodyHash = await sha256(args.rawBody);
  const clientDataHash = await sha256(new TextEncoder().encode(args.challenge), bodyHash);
  const nonce = await sha256(authData, clientDataHash);

  // 5. Verify the (DER → raw) ECDSA signature over the nonce with the attested key.
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey("spki", args.publicKeyDer, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch (cause) {
    throw new AppAttestError("assert: stored public key is not importable SPKI P-256", { cause });
  }
  let ok = false;
  try {
    const rawSig = derToRawEcdsa(sigDer);
    ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSig, nonce);
  } catch (cause) {
    throw new AppAttestError("assert: signature could not be verified", { cause });
  }
  if (!ok) throw new AppAttestError("assert: signature invalid");

  // 6. Success — return the new counter so the caller can persist it.
  return { newSignCount: counter };
}
