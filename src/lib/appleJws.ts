// Apple JWS (x5c) signature + certificate-chain verifier.
//
// Apple signs App Store Server Notifications V2 payloads and StoreKit 2 signed
// transactions as JWS (ES256) whose protected header carries an `x5c` array:
// [leafDER, intermediateDER, rootDER] (base64-encoded DER certs). Trusting the
// payload requires:
//   1. the JWS signature verifies under the LEAF cert's public key, AND
//   2. the cert CHAIN is intact (leaf cryptographically signed by intermediate,
//      intermediate by root — real signature checks, not DN matching), AND
//   3. the chain root EQUALS a pinned trust anchor (Apple Root CA - G3), AND
//   4. every cert is within its validity window at verification time.
//
// RUNTIME NOTE: node:crypto's X509Certificate is available under nodejs_compat
// but on workerd its EC `publicKey` getter throws ("Unrecognized or
// unimplemented EC curve") and `checkIssued()` is DN-only (it does NOT verify the
// issuer signature). So node:crypto CANNOT do the cryptographic chain check here.
// We use @peculiar/x509 instead, whose `cert.verify({publicKey})` performs a real
// ECDSA signature verification and works inside workerd. jose handles the JWS
// signature off the leaf cert.

import "reflect-metadata"; // tsyringe (peculiar's DI) needs the reflect polyfill
import * as x509 from "@peculiar/x509";
import { compactVerify, importX509 } from "jose";

// Bind peculiar to the runtime WebCrypto (workerd / Node both expose `crypto`).
x509.cryptoProvider.set(crypto as unknown as Crypto);

/** Thrown for ANY verification failure (bad signature, broken chain, untrusted
 *  root, expired cert, malformed JWS). Callers reject the request and do not
 *  touch the DB on this error. */
export class AppleJwsError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "AppleJwsError";
  }
}

export interface VerifyOptions {
  /**
   * PEM of the root cert the chain must terminate in. Defaults to the real
   * Apple Root CA - G3 (production). Tests inject their own chain's root here.
   */
  trustAnchorPEM?: string;
  /** Verification time in epoch ms (for cert-validity-window checks). Defaults to Date.now(). */
  nowMs?: number;
}

/**
 * Apple Root CA - G3 — the public, self-signed root that anchors Apple's App
 * Store Server API / StoreKit JWS chains. Source:
 * https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (DER → PEM).
 * SHA-256 fingerprint:
 * 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
 */
export const APPLE_ROOT_CA_G3 = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

interface JwsHeader {
  alg?: string;
  x5c?: string[];
}

function base64UrlToString(segment: string): string {
  const b64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "=");
  return atob(padded);
}

/** Parse the JWS protected header without trusting it. */
function parseHeader(jws: string): JwsHeader {
  const part = jws.split(".")[0];
  if (!part) throw new AppleJwsError("malformed JWS: missing header");
  try {
    return JSON.parse(base64UrlToString(part)) as JwsHeader;
  } catch (cause) {
    throw new AppleJwsError("malformed JWS: undecodable header", { cause });
  }
}

/** Wrap a base64-DER cert (from x5c) into a peculiar X509Certificate. */
function certFromX5c(b64Der: string): x509.X509Certificate {
  try {
    return new x509.X509Certificate(b64Der);
  } catch (cause) {
    throw new AppleJwsError("invalid x5c certificate (not parseable DER)", { cause });
  }
}

function certFromPem(pem: string): x509.X509Certificate {
  try {
    return new x509.X509Certificate(pem);
  } catch (cause) {
    throw new AppleJwsError("invalid trust-anchor PEM", { cause });
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

/** Constant-shape comparison of two certs by raw DER. */
function sameCert(a: x509.X509Certificate, b: x509.X509Certificate): boolean {
  const da = new Uint8Array(a.rawData);
  const db = new Uint8Array(b.rawData);
  if (da.length !== db.length) return false;
  let diff = 0;
  for (let i = 0; i < da.length; i++) diff |= (da[i] ?? 0) ^ (db[i] ?? 0);
  return diff === 0;
}

/**
 * Verify an Apple-signed JWS and return its decoded JSON payload.
 *
 * @throws {AppleJwsError} on any failure — the caller MUST treat this as a hard
 *   rejection (no DB writes, respond 4xx).
 */
export async function verifyAppleSignedPayload<T>(jws: string, opts: VerifyOptions = {}): Promise<T> {
  const nowMs = opts.nowMs ?? Date.now();
  const trustAnchorPEM = opts.trustAnchorPEM ?? APPLE_ROOT_CA_G3;

  // 1. Read the x5c chain from the (untrusted) header.
  const header = parseHeader(jws);
  if (header.alg !== "ES256") {
    throw new AppleJwsError(`unexpected JWS alg: ${header.alg ?? "(none)"} (expected ES256)`);
  }
  const x5c = header.x5c;
  // Apple always presents [leaf, intermediate, root]; require all three so we can
  // validate the full chain up to the anchor.
  if (!Array.isArray(x5c) || x5c.length < 3) {
    throw new AppleJwsError("x5c chain too short (expected leaf, intermediate, root)");
  }
  const [leafDer, intermediateDer, rootDer] = x5c;
  if (!leafDer || !intermediateDer || !rootDer) {
    throw new AppleJwsError("x5c chain has empty entries");
  }
  const leaf = certFromX5c(leafDer);
  const intermediate = certFromX5c(intermediateDer);
  const root = certFromX5c(rootDer);

  // 2. Verify the JWS ES256 signature using the LEAF cert's public key. (This
  //    binds the payload to the leaf; chain validation below binds the leaf to
  //    Apple's trust anchor.)
  let payload: Uint8Array;
  try {
    const leafKey = await importX509(leaf.toString("pem"), "ES256");
    const result = await compactVerify(jws, leafKey);
    payload = result.payload;
  } catch (cause) {
    throw new AppleJwsError("JWS signature does not verify against the leaf certificate", { cause });
  }

  // 3. Validate the cert chain (real signature checks): leaf <- intermediate <- root.
  if (!(await issuedBy(leaf, intermediate))) {
    throw new AppleJwsError("leaf certificate is not signed by the presented intermediate");
  }
  if (!(await issuedBy(intermediate, root))) {
    throw new AppleJwsError("intermediate certificate is not signed by the presented root");
  }

  // The presented root must be exactly the pinned trust anchor (Apple Root CA - G3
  // in production). Compare by raw DER, not subject/issuer strings (which a forged
  // self-signed cert could spoof).
  const anchor = certFromPem(trustAnchorPEM);
  if (!sameCert(root, anchor)) {
    throw new AppleJwsError("chain root does not match the trusted anchor");
  }
  // Defence in depth: the anchor must be a self-signed root under its own key.
  if (!(await issuedBy(root, anchor))) {
    throw new AppleJwsError("chain root signature does not verify under the trust anchor key");
  }

  // 4. Validity window for every cert in the chain.
  for (const [label, cert] of [
    ["leaf", leaf],
    ["intermediate", intermediate],
    ["root", root],
  ] as const) {
    if (!isWithinValidity(cert, nowMs)) {
      throw new AppleJwsError(`${label} certificate is outside its validity window`);
    }
  }

  // 5. Decode + return the (now trusted) payload.
  try {
    return JSON.parse(new TextDecoder().decode(payload)) as T;
  } catch (cause) {
    throw new AppleJwsError("verified payload is not valid JSON", { cause });
  }
}
