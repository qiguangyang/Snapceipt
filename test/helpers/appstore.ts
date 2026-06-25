import { env } from "cloudflare:test";
import { CompactSign, importPKCS8 } from "jose";
import type { TestChain } from "./appleChain";

// Build VERIFIABLE App Store Server Notifications V2 payloads for tests. The
// worker's webhook now verifies Apple's JWS x5c chain, so a throwaway
// header.payload.SIG no longer works — we sign with the test chain injected via
// the TEST_APPLE_CHAIN binding (its root is pinned as APPLE_TRUST_ANCHOR_PEM in
// vitest.config.ts). Pass a different chain to `chain` to simulate an UNTRUSTED
// signer (a chain whose root is not the pinned anchor → webhook rejects it).

function testChain(): TestChain {
  const raw = (env as unknown as { TEST_APPLE_CHAIN: string }).TEST_APPLE_CHAIN;
  return JSON.parse(raw) as TestChain;
}

/** Sign `payload` as the leaf of `chain` (ES256, x5c = chain DERs). */
async function signAsLeaf(chain: TestChain, payload: unknown): Promise<string> {
  const key = await importPKCS8(chain.leafPrivateKeyPkcs8Pem, "ES256");
  return new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: "ES256", x5c: chain.x5c })
    .sign(key);
}

/**
 * Build a verifiable `signedPayload` whose decoded data carries the given
 * notification type, productId, originalTransactionId and expiry — the exact
 * shape our webhook reads. Both the outer envelope and the inner transaction (+
 * renewal) JWS are signed with `opts.chain` (defaults to the trusted test chain).
 * `signedDateMs` is the top-level responseBodyV2 timestamp (epoch ms); defaults to
 * Date.now() when not supplied.
 */
export async function makeSignedNotification(opts: {
  notificationType: string;
  subtype?: string;
  productId?: string;
  originalTransactionId: string;
  expiresDateMs?: number;
  /** Top-level signedDate (epoch ms). Defaults to Date.now(). */
  signedDateMs?: number;
  /** Override the signing chain — pass an UNTRUSTED chain to simulate a forgery. */
  chain?: TestChain;
}): Promise<string> {
  const chain = opts.chain ?? testChain();
  const productId = opts.productId ?? "app.snapceipt.pro.monthly";
  const expiresDateMs = opts.expiresDateMs ?? 9_999_999_999_000;
  const signedDate = opts.signedDateMs ?? Date.now();

  const signedTransactionInfo = await signAsLeaf(chain, {
    productId,
    originalTransactionId: opts.originalTransactionId,
    expiresDate: expiresDateMs,
  });
  const signedRenewalInfo = await signAsLeaf(chain, {
    productId,
    originalTransactionId: opts.originalTransactionId,
    autoRenewStatus: 1,
  });
  return signAsLeaf(chain, {
    notificationType: opts.notificationType,
    subtype: opts.subtype,
    signedDate,
    data: { signedTransactionInfo, signedRenewalInfo },
  });
}

/**
 * Build a verifiable StoreKit 2 signed transaction JWS (the shape
 * Transaction.jwsRepresentation carries) for the /me/subscription tests. Signed
 * with `opts.chain` (defaults to the trusted test chain); pass an untrusted chain
 * to simulate a forgery.
 */
export async function makeSignedTransaction(opts: {
  bundleId: string;
  productId: string;
  originalTransactionId: string;
  expiresDate?: number;
  /** epoch ms; present on a refunded/revoked transaction. */
  revocationDate?: number;
  /** "Sandbox" | "Production" — the StoreKit environment claim. */
  environment?: string;
  chain?: TestChain;
}): Promise<string> {
  const chain = opts.chain ?? testChain();
  return signAsLeaf(chain, {
    bundleId: opts.bundleId,
    productId: opts.productId,
    originalTransactionId: opts.originalTransactionId,
    expiresDate: opts.expiresDate ?? 9_999_999_999_000,
    ...(opts.revocationDate !== undefined ? { revocationDate: opts.revocationDate } : {}),
    ...(opts.environment !== undefined ? { environment: opts.environment } : {}),
    transactionId: opts.originalTransactionId,
  });
}
