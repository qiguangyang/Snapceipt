// Test-only Apple-JWS chain factory. Generates a 3-cert ES256 chain
// (root -> intermediate -> leaf) that mirrors Apple's [leaf, intermediate, root]
// x5c layout, plus a JWS signer keyed off the leaf cert. The generated
// PEM/x5c/JWS strings are handed to the worker, which verifies them with
// @peculiar/x509 + jose exactly as it would a real Apple payload.
//
// IMPORTANT: this fixture exists only so tests can inject their OWN trust anchor.
// Production embeds the real AppleRootCA-G3 (see src/lib/appleJws.ts); these test
// certs are never trusted there.
import "reflect-metadata";
import * as x509 from "@peculiar/x509";
import { CompactSign, importPKCS8 } from "jose";

// Global WebCrypto — available in both the Node test-transform context (where
// vitest.config.ts calls makeTestChain) and the worker. The @cloudflare/workers
// SubtleCrypto types are broader (CryptoKey | CryptoKeyPair, ArrayBuffer |
// JsonWebKey) than the DOM lib; narrow via this thin facade so the helper types
// cleanly under the worker tsconfig.
const subtle = crypto.subtle as unknown as {
  generateKey(alg: unknown, ext: boolean, usages: string[]): Promise<CryptoKeyPair>;
  exportKey(format: "pkcs8", key: CryptoKey): Promise<ArrayBuffer>;
};
x509.cryptoProvider.set(crypto as unknown as Crypto);

const ALG = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;

function pemBody(pem: string): string {
  return pem.replace(/-----BEGIN CERTIFICATE-----/g, "")
    .replace(/-----END CERTIFICATE-----/g, "")
    .replace(/\s+/g, "");
}

export interface TestChain {
  /** x5c array as the JWS header carries it: [leafDER, intermediateDER, rootDER] (base64 DER). */
  x5c: string[];
  leafCertPem: string;
  intermediateCertPem: string;
  rootCertPem: string;
  /** Leaf private key (PKCS8 PEM) for signing JWS payloads as the leaf. */
  leafPrivateKeyPkcs8Pem: string;
}

interface MakeChainOpts {
  /** Override the leaf validity window (e.g. an already-expired leaf). */
  leafNotBefore?: Date;
  leafNotAfter?: Date;
}

function bytesToBase64(bytes: ArrayBuffer): string {
  const view = new Uint8Array(bytes);
  let bin = "";
  for (let i = 0; i < view.length; i++) bin += String.fromCharCode(view[i] ?? 0);
  return btoa(bin);
}

async function pkcs8Pem(key: CryptoKey): Promise<string> {
  const der = await subtle.exportKey("pkcs8", key);
  const b64 = bytesToBase64(der);
  const lines = b64.match(/.{1,64}/g)?.join("\n") ?? b64;
  return `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
}

/**
 * Build a fresh root -> intermediate -> leaf ES256 chain. Each call is a NEW root
 * (so a test can pass one chain's root PEM as the trust anchor and another chain
 * as an UNTRUSTED signer to prove rejection).
 */
export async function makeTestChain(opts: MakeChainOpts = {}): Promise<TestChain> {
  const now = Date.now();
  const farFuture = new Date(now + 3_600_000);
  const past = new Date(now - 60_000);

  const rootKeys = await subtle.generateKey(ALG, true, ["sign", "verify"]);
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Snapceipt Test Root CA",
    notBefore: past,
    notAfter: farFuture,
    keys: rootKeys,
    signingAlgorithm: ALG,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });

  const intKeys = await subtle.generateKey(ALG, true, ["sign", "verify"]);
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Snapceipt Test Intermediate CA",
    issuer: root.subject,
    notBefore: past,
    notAfter: farFuture,
    signingKey: rootKeys.privateKey,
    publicKey: intKeys.publicKey,
    signingAlgorithm: ALG,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });

  const leafKeys = await subtle.generateKey(ALG, true, ["sign", "verify"]);
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=Snapceipt Test Leaf",
    issuer: intermediate.subject,
    notBefore: opts.leafNotBefore ?? past,
    notAfter: opts.leafNotAfter ?? farFuture,
    signingKey: intKeys.privateKey,
    publicKey: leafKeys.publicKey,
    signingAlgorithm: ALG,
  });

  const leafCertPem = leaf.toString("pem");
  const intermediateCertPem = intermediate.toString("pem");
  const rootCertPem = root.toString("pem");

  return {
    x5c: [pemBody(leafCertPem), pemBody(intermediateCertPem), pemBody(rootCertPem)],
    leafCertPem,
    intermediateCertPem,
    rootCertPem,
    leafPrivateKeyPkcs8Pem: await pkcs8Pem(leafKeys.privateKey),
  };
}

/**
 * Sign `payload` as a real Apple-shaped JWS: ES256, x5c = the chain's
 * [leaf, intermediate, root] DERs, signed with the chain's leaf private key.
 * This is exactly what verifyAppleSignedPayload expects.
 */
export async function signAsLeaf(chain: TestChain, payload: unknown): Promise<string> {
  const key = await importPKCS8(chain.leafPrivateKeyPkcs8Pem, "ES256");
  return new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: "ES256", x5c: chain.x5c })
    .sign(key);
}
