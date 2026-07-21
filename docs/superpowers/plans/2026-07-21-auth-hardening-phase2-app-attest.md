# Auth Hardening — Phase 2 (Apple App Attest) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that requests to the six auth-bootstrap *entry* endpoints come from a genuine, unmodified Snapceipt install on a real Apple device, via Apple App Attest, with phased enforcement that never breaks existing App Store users.

**Architecture:** iOS generates a Secure-Enclave App Attest key, attests it once (`/attest/verify`), then signs a server nonce on each auth-bootstrap call (assertion headers). The Worker verifies the attestation cert chain against the pinned Apple App Attest Root CA (reusing the `jose` + node `X509Certificate` pattern already in `src/lib/appleJws.ts`) and verifies each assertion's ECDSA-P256 signature + anti-replay counter with WebCrypto. A single `ATTEST_MODE` flag graduates from `off` → `soft` → `enforce-new` (version-gated) → `enforce-all`.

**Tech Stack:** Cloudflare Workers (`nodejs_compat`), Hono, D1, KV, `jose`, node `X509Certificate`, WebCrypto (`crypto.subtle`), a minimal in-repo CBOR decoder; iOS `DeviceCheck`/`DCAppAttestService`, Keychain; Vitest + XCTest.

## Global Constraints

- App Attest App ID = **`2SU47GHJQX.app.snapceipt.Snapceipt`** ⇒ `rpIdHash = SHA256("2SU47GHJQX.app.snapceipt.Snapceipt")`.
- Attested endpoints (six): `/auth/otp/request`, `/auth/otp/verify`, `/auth/password/login`, `/auth/apple`, `/auth/magic-link/request`, `/auth/magic-link/verify`. **`/auth/refresh` is NOT attested** (high-frequency; already protected by rotating-token reuse detection).
- Enforcement modes: `off` (default) → `soft` (verify+log, never reject) → `enforce-new` (reject only when `X-App-Build ≥ ATTEST_MIN_BUILD`) → `enforce-all`. Dev/E2E stay `off`.
- iOS deployment target 17.0 (App Attest requires 14+). App Attest is UNAVAILABLE on Simulator (`DCAppAttestService.isSupported == false`) → attestation MUST be skipped there and under `-uiTestStub`/E2E.
- New table `attest_keys` is device-scoped; add it to the account-delete purge (device subquery) + the account-delete test seed (per the FK-violation trap in `src/routes/account.ts`).
- Phase-1 caps remain in force under Phase 2 (defense in depth).
- Never pipe test output through `grep` before `&& git commit`.

---

### Task 1: `attest_keys` table + account-delete purge + test seed

**Files:**
- Create: `migrations/0019_attest_keys.sql`
- Modify: `src/routes/account.ts` (add `DEVICE_SCOPED_PURGE_TABLES` + wire into the delete batch, around lines 22–46 and 141–165)
- Test: `test/account-delete-attest.test.ts` (create)

**Interfaces:**
- Produces: table `attest_keys(key_id PK, device_id, public_key BLOB, sign_count, aaguid, created_at, last_used_at)`; `DEVICE_SCOPED_PURGE_TABLES = ["attest_keys"] as const`.

- [ ] **Step 1: Write the migration**

Create `migrations/0019_attest_keys.sql`:

```sql
-- App Attest keys: one row per attested Secure-Enclave key (per install).
-- key_id = base64(sha256(pubkey)); device_id is the X-Device-Id at attestation time.
-- No FK to devices (device_id is informational) so account-delete never 500s on ordering;
-- account delete purges these via a device subquery for hygiene.
CREATE TABLE attest_keys (
  key_id       TEXT PRIMARY KEY,
  device_id    TEXT,
  public_key   BLOB NOT NULL,
  sign_count   INTEGER NOT NULL DEFAULT 0,
  aaguid       TEXT,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER
);
CREATE INDEX ix_attest_keys_device ON attest_keys (device_id);
```

- [ ] **Step 2: Write the failing test**

Create `test/account-delete-attest.test.ts`:

```ts
import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
// Reuse the project's existing helper for seeding an authed user + bearer token.
import { seedUserWithSession } from "./helpers/seed"; // if absent, inline per the pattern in test/account-delete.test.ts

describe("account delete purges attest_keys", () => {
  it("removes the user's device attest_keys rows", async () => {
    const { userId, deviceId, bearer } = await seedUserWithSession(env);
    await env.DB.prepare(
      "INSERT INTO attest_keys (key_id, device_id, public_key, sign_count, aaguid, created_at) VALUES (?,?,?,?,?,?)",
    ).bind("k_" + userId, deviceId, new Uint8Array([1, 2, 3]), 0, "appattest", Date.now()).run();

    const res = await SELF.fetch("https://x/account", {
      method: "DELETE",
      headers: { authorization: `Bearer ${bearer}` },
    });
    expect(res.status).toBe(200);

    const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM attest_keys WHERE device_id = ?")
      .bind(deviceId).first<{ n: number }>();
    expect(left?.n).toBe(0);
  });
});
```

If `./helpers/seed` does not exist, inline the seed by copying the setup block from `test/account-delete.test.ts` (create a user + device + session, mint a bearer via the same path that suite uses).

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run test/account-delete-attest.test.ts`
Expected: FAIL — attest_keys row remains (purge not wired).

- [ ] **Step 4: Wire the purge in `src/routes/account.ts`**

Below `PROFILE_SCOPED_PURGE_TABLES` (line 46) add:

```ts
// Device-scoped user data (keyed by device_id, no user_id column): purge via a device subquery,
// and BEFORE `devices` is deleted in PURGE_ORDER.
export const DEVICE_SCOPED_PURGE_TABLES = ["attest_keys"] as const;
```

In the delete handler's batch (around line 156, alongside the `PROFILE_SCOPED_PURGE_TABLES.map(...)` spread), add a spread that runs first:

```ts
    ...DEVICE_SCOPED_PURGE_TABLES.map((t) =>
      c.env.DB
        .prepare(`DELETE FROM ${t} WHERE device_id IN (SELECT id FROM devices WHERE user_id = ?)`)
        .bind(userId),
    ),
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run test/account-delete-attest.test.ts`
Expected: PASS.

- [ ] **Step 6: Confirm the migration applies in the test harness + existing delete test still green**

Run: `npx vitest run test/account-delete.test.ts test/account-delete-attest.test.ts`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add migrations/0019_attest_keys.sql src/routes/account.ts test/account-delete-attest.test.ts test/helpers/seed.ts
git commit -m "feat(attest): add attest_keys table + account-delete purge"
```

---

### Task 2: `ATTEST_MODE` / `ATTEST_MIN_BUILD` env

**Files:**
- Modify: `src/env.ts` (add two optional fields to `Env`, after `REVIEW_DEMO_EMAIL`)
- Modify: `wrangler.jsonc` (add `"ATTEST_MODE": "off"` to prod + staging `vars`)

**Interfaces:**
- Produces: `env.ATTEST_MODE?: "off" | "soft" | "enforce-new" | "enforce-all"`, `env.ATTEST_MIN_BUILD?: string` (numeric string).

- [ ] **Step 1: Add the fields to `Env`**

In `src/env.ts`, before the closing `};` of `Env`:

```ts
  /**
   * App Attest enforcement mode for the six auth-bootstrap entry endpoints:
   *  - "off"          (default when unset): attestation ignored.
   *  - "soft"         : verify assertion if present, log validity, never reject.
   *  - "enforce-new"  : reject un-attested/invalid ONLY when X-App-Build >= ATTEST_MIN_BUILD.
   *  - "enforce-all"  : reject all un-attested auth-bootstrap requests.
   * Dev/E2E stay "off".
   */
  ATTEST_MODE?: "off" | "soft" | "enforce-new" | "enforce-all";
  /** First app build (CFBundleVersion) that ships App Attest; used by "enforce-new". Numeric string. */
  ATTEST_MIN_BUILD?: string;
```

- [ ] **Step 2: Default `off` in `wrangler.jsonc`**

Add `"ATTEST_MODE": "off"` to the top-level `vars` block and the `env.staging.vars` block (leave `ATTEST_MIN_BUILD` unset until the attest app build number is known).

- [ ] **Step 3: Typecheck**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/env.ts wrangler.jsonc
git commit -m "feat(attest): add ATTEST_MODE/ATTEST_MIN_BUILD env (default off)"
```

---

### Task 3: minimal CBOR decoder + base64url helpers

**Files:**
- Create: `src/lib/cbor.ts`
- Test: `test/cbor.test.ts`

**Interfaces:**
- Produces: `decodeCbor(bytes: Uint8Array): unknown` (supports the subset App Attest uses: unsigned/negative ints, byte strings, text strings, arrays, maps); `b64uToBytes(s: string): Uint8Array`, `bytesToB64u(b: Uint8Array): string`, `bytesToHex(b: Uint8Array): string`.

- [ ] **Step 1: Write the failing test**

Create `test/cbor.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { decodeCbor, b64uToBytes, bytesToB64u } from "../src/lib/cbor";

describe("decodeCbor", () => {
  it("decodes a small map with byte/text/int values", () => {
    // {"fmt":"a","c":1,"b":h'0102'}  (CBOR)
    const hex = "a3636662746161616301616249420102";
    const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
    const obj = decodeCbor(bytes) as Record<string, unknown>;
    expect(obj.fmt).toBe("a");
    expect(obj.c).toBe(1);
    expect(obj.b).toEqual(new Uint8Array([1, 2]));
  });
  it("round-trips base64url", () => {
    const b = new Uint8Array([0, 255, 16, 32]);
    expect(b64uToBytes(bytesToB64u(b))).toEqual(b);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/cbor.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/lib/cbor.ts`**

```ts
// Minimal CBOR decoder — only the subset Apple App Attest uses: uint (maj 0), negint (maj 1),
// byte string (maj 2), text string (maj 3), array (maj 4), map (maj 5). Indefinite lengths and
// tags/floats are not needed and throw. Enough to parse attestation/assertion objects.

export function b64uToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64u(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function bytesToHex(b: Uint8Array): string {
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

class Reader {
  constructor(public buf: Uint8Array, public pos = 0) {}
  u8(): number { return this.buf[this.pos++]!; }
  bytes(n: number): Uint8Array { const s = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return s; }
  uint(info: number): number {
    if (info < 24) return info;
    if (info === 24) return this.u8();
    if (info === 25) { const b = this.bytes(2); return (b[0]! << 8) | b[1]!; }
    if (info === 26) { const b = this.bytes(4); return ((b[0]! << 24) | (b[1]! << 16) | (b[2]! << 8) | b[3]!) >>> 0; }
    if (info === 27) { // 64-bit; App Attest counters fit in <=53 bits
      const b = this.bytes(8); let v = 0; for (const x of b) v = v * 256 + x; return v;
    }
    throw new Error(`cbor: unsupported length info ${info}`);
  }
}

function decodeItem(r: Reader): unknown {
  const ib = r.u8();
  const major = ib >> 5;
  const info = ib & 0x1f;
  switch (major) {
    case 0: return r.uint(info);
    case 1: return -1 - r.uint(info);
    case 2: return r.bytes(r.uint(info)).slice(); // copy
    case 3: return new TextDecoder().decode(r.bytes(r.uint(info)));
    case 4: { const n = r.uint(info); const a: unknown[] = []; for (let i = 0; i < n; i++) a.push(decodeItem(r)); return a; }
    case 5: {
      const n = r.uint(info); const m: Record<string, unknown> = {};
      for (let i = 0; i < n; i++) { const k = decodeItem(r); m[String(k)] = decodeItem(r); }
      return m;
    }
    default: throw new Error(`cbor: unsupported major type ${major}`);
  }
}

export function decodeCbor(bytes: Uint8Array): unknown {
  return decodeItem(new Reader(bytes));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/cbor.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/cbor.ts test/cbor.test.ts
git commit -m "feat(attest): minimal CBOR decoder + base64url helpers"
```

---

### Task 4: App Attest attestation verifier

**Files:**
- Create: `src/lib/appAttest.ts` (root pin + `verifyAttestation`)
- Create: `test/fixtures/appattest/` (captured real-device vectors — see Task 10 for capture; a placeholder unit test uses a synthetic negative until the vector lands)
- Test: `test/appAttest.attestation.test.ts`

**Interfaces:**
- Consumes: `decodeCbor`, `b64uToBytes`, `bytesToB64u`, `bytesToHex` (Task 3); `jose` `importX509`; node `X509Certificate`.
- Produces:
  ```ts
  export const APP_ID = "2SU47GHJQX.app.snapceipt.Snapceipt";
  export async function rpIdHash(): Promise<Uint8Array>;               // sha256(APP_ID)
  export interface AttestationResult { keyId: string; publicKeyDer: Uint8Array; signCount: number; aaguid: string; }
  export async function verifyAttestation(args: {
    attestationB64u: string; challenge: string; keyId: string;
  }): Promise<AttestationResult>;  // throws AppAttestError on any check failure
  ```

- [ ] **Step 1: Write the failing tests (negative cases first — no real device needed)**

Create `test/appAttest.attestation.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { verifyAttestation, APP_ID } from "../src/lib/appAttest";

describe("verifyAttestation (negatives)", () => {
  it("rejects a non-CBOR / garbage attestation", async () => {
    await expect(
      verifyAttestation({ attestationB64u: "AAAA", challenge: "c", keyId: "k" }),
    ).rejects.toThrow();
  });
  it("exposes the correct App ID", () => {
    expect(APP_ID).toBe("2SU47GHJQX.app.snapceipt.Snapceipt");
  });
});
```

> A positive test is added in Task 10 once a real-device attestation blob is captured into `test/fixtures/appattest/attestation.json` (`{ attestationB64u, challenge, keyId }`). The verifier is written now against Apple's published algorithm; the real vector is the acceptance oracle.

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/appAttest.attestation.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/lib/appAttest.ts` attestation path**

```ts
import { X509Certificate } from "node:crypto";
import { importX509 } from "jose";
import { decodeCbor, b64uToBytes, bytesToB64u, bytesToHex } from "./cbor";

export class AppAttestError extends Error {}

export const APP_ID = "2SU47GHJQX.app.snapceipt.Snapceipt";

// Apple App Attest Root CA (download DER from
// https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem and paste the PEM).
export const APPLE_APP_ATTEST_ROOT_CA = `-----BEGIN CERTIFICATE-----
<PASTE Apple_App_Attestation_Root_CA.pem CONTENTS — this is a public, pinned root cert, not a secret>
-----END CERTIFICATE-----`;

async function sha256(...parts: Uint8Array[]): Promise<Uint8Array> {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const buf = new Uint8Array(total);
  let o = 0; for (const p of parts) { buf.set(p, o); o += p.length; }
  return new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
}
export async function rpIdHash(): Promise<Uint8Array> {
  return sha256(new TextEncoder().encode(APP_ID));
}
function eq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a[i]! ^ b[i]!; return d === 0;
}

/** Extract the DER value of extension OID 1.2.840.113635.100.8.2 (Apple App Attest nonce) from a
 *  cert's DER. The extension's extnValue is an OCTET STRING wrapping `SEQUENCE { [1] OCTET STRING nonce }`.
 *  We locate the OID bytes then read the wrapped nonce (the innermost 32-byte OCTET STRING). */
function extractAppAttestNonce(certDer: Uint8Array): Uint8Array {
  // OID 1.2.840.113635.100.8.2 encoded: 06 0A 2A 86 48 86 F7 63 64 08 02
  const oid = Uint8Array.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]);
  let i = -1;
  outer: for (let p = 0; p + oid.length <= certDer.length; p++) {
    for (let k = 0; k < oid.length; k++) if (certDer[p + k] !== oid[k]) continue outer;
    i = p; break;
  }
  if (i < 0) throw new AppAttestError("attest: nonce extension OID not found");
  // After the OID: OCTET STRING (extnValue) → SEQUENCE → [1] tagged OCTET STRING (32 bytes).
  // Walk forward to the last 0x04 0x20 (OCTET STRING, len 32) before running out.
  let p = i + oid.length;
  while (p + 2 <= certDer.length) {
    if (certDer[p] === 0x04 && certDer[p + 1] === 0x20 && p + 2 + 32 <= certDer.length) {
      return certDer.subarray(p + 2, p + 2 + 32).slice();
    }
    p++;
  }
  throw new AppAttestError("attest: nonce octet-string not found");
}

export interface AttestationResult { keyId: string; publicKeyDer: Uint8Array; signCount: number; aaguid: string; }

export async function verifyAttestation(args: {
  attestationB64u: string; challenge: string; keyId: string;
}): Promise<AttestationResult> {
  let obj: any;
  try { obj = decodeCbor(b64uToBytes(args.attestationB64u)); } catch (e) { throw new AppAttestError("attest: bad CBOR"); }
  if (!obj || obj.fmt !== "apple-appattest" || !obj.attStmt || !(obj.authData instanceof Uint8Array)) {
    throw new AppAttestError("attest: wrong format");
  }
  const x5c: Uint8Array[] = obj.attStmt.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2) throw new AppAttestError("attest: x5c too short");
  const credCert = new X509Certificate(Buffer.from(x5c[0]!));
  const caCert = new X509Certificate(Buffer.from(x5c[1]!));
  const root = new X509Certificate(APPLE_APP_ATTEST_ROOT_CA);

  // 1. Chain: credCert signed by caCert signed by (pinned) root. (Same pattern as appleJws.ts.)
  if (!credCert.verify(caCert.publicKey)) throw new AppAttestError("attest: credCert not signed by CA");
  if (!caCert.verify(root.publicKey)) throw new AppAttestError("attest: CA not signed by pinned root");

  // 2. nonce = sha256(authData || sha256(challenge)); compare to the credCert extension nonce.
  const authData: Uint8Array = obj.authData;
  const clientDataHash = await sha256(new TextEncoder().encode(args.challenge));
  const computedNonce = await sha256(authData, clientDataHash);
  const certNonce = extractAppAttestNonce(new Uint8Array(credCert.raw));
  if (!eq(computedNonce, certNonce)) throw new AppAttestError("attest: nonce mismatch");

  // 3. rpIdHash (first 32 bytes of authData) == sha256(APP_ID).
  const rp = authData.subarray(0, 32);
  if (!eq(rp, await rpIdHash())) throw new AppAttestError("attest: rpIdHash mismatch");

  // 4. counter (bytes 33..37) must be 0.
  const counter = ((authData[33]! << 24) | (authData[34]! << 16) | (authData[35]! << 8) | authData[36]!) >>> 0;
  if (counter !== 0) throw new AppAttestError("attest: initial counter != 0");

  // 5. aaguid (bytes 37..53) must be appattest or appattestdevelop.
  const aaguidBytes = authData.subarray(37, 53);
  const aaguid = new TextDecoder().decode(aaguidBytes).replace(/\0+$/, "");
  if (aaguid !== "appattest" && aaguid !== "appattestdevelop") throw new AppAttestError(`attest: bad aaguid '${aaguid}'`);

  // 6. keyId = sha256(credCert SubjectPublicKeyInfo EC point) must equal credentialId in authData
  //    AND the client-declared keyId. credentialId: after aaguid, 2-byte len then id.
  const credIdLen = (authData[53]! << 8) | authData[54]!;
  const credentialId = authData.subarray(55, 55 + credIdLen);
  const spkiDer = new Uint8Array(credCert.publicKey.export({ type: "spki", format: "der" }));
  // Apple computes keyId over the raw uncompressed EC public key (0x04||X||Y), the last 65 bytes of SPKI.
  const ecPoint = spkiDer.subarray(spkiDer.length - 65);
  const keyIdBytes = await sha256(ecPoint);
  if (!eq(keyIdBytes, credentialId)) throw new AppAttestError("attest: keyId != credentialId");
  const keyId = bytesToB64u(keyIdBytes);
  if (keyId !== args.keyId) throw new AppAttestError("attest: keyId != client keyId");

  return { keyId, publicKeyDer: spkiDer, signCount: 0, aaguid };
}
```

> The `<PASTE …>` in `APPLE_APP_ATTEST_ROOT_CA` is a **required literal** the implementer fills from Apple's published root PEM (public, not a secret) — download from https://www.apple.com/certificateauthority/ . Do not leave the placeholder.

- [ ] **Step 4: Run tests to verify negatives pass**

Run: `npx vitest run test/appAttest.attestation.test.ts`
Expected: PASS (garbage rejected; APP_ID correct).

- [ ] **Step 5: Commit**

```bash
git add src/lib/appAttest.ts test/appAttest.attestation.test.ts
git commit -m "feat(attest): App Attest attestation verifier (chain+nonce+rpId+keyId)"
```

---

### Task 5: App Attest assertion verifier

**Files:**
- Modify: `src/lib/appAttest.ts` (add `verifyAssertion`)
- Test: `test/appAttest.assertion.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export async function verifyAssertion(args: {
    assertionB64u: string; challenge: string; rawBody: Uint8Array;
    publicKeyDer: Uint8Array; storedSignCount: number;
  }): Promise<{ newSignCount: number }>; // throws on invalid sig / non-increasing counter / rpId
  ```

- [ ] **Step 1: Write the failing test (positive, self-signed vector)**

Create `test/appAttest.assertion.test.ts` — generate a P-256 key, build an authenticatorData + signature exactly as the device would, and assert the verifier accepts it, then rejects a replay (non-increasing counter):

```ts
import { describe, expect, it } from "vitest";
import { verifyAssertion, rpIdHash } from "../src/lib/appAttest";
import { bytesToB64u } from "../src/lib/cbor";

async function makeAssertion(counter: number, challenge: string, body: Uint8Array, priv: CryptoKey, spki: Uint8Array) {
  const rp = await rpIdHash();
  const authData = new Uint8Array(37);
  authData.set(rp, 0);
  authData[32] = 0; // flags
  new DataView(authData.buffer).setUint32(33, counter, false);
  const bodyHash = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
  const cdh = new Uint8Array(await crypto.subtle.digest("SHA-256",
    new Uint8Array([...new TextEncoder().encode(challenge), ...bodyHash])));
  const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array([...authData, ...cdh])));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, priv, nonce));
  // Encode as CBOR map {"signature":sig,"authenticatorData":authData} — reuse a tiny inline encoder:
  return { authData, sig, cdh, nonce, spki };
}

describe("verifyAssertion", () => {
  it("accepts a valid assertion then rejects a replay", async () => {
    const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const spki = new Uint8Array(await crypto.subtle.exportKey("spki", kp.publicKey));
    const body = new TextEncoder().encode(JSON.stringify({ email: "x@y.z" }));
    // NOTE: build the assertion CBOR with the helper in Step 3's test util (buildAssertionCbor).
    // ... (see appAttest.testutil.ts) assert accept at counter=1, reject at counter=1 again.
  });
});
```

> The DER/CBOR assembly for the WebCrypto ECDSA signature (raw r||s → DER) is provided as a shared test util in Step 3. Keep the crypto in the util so both accept and replay cases share it.

- [ ] **Step 2: Add the shared test util + run to see it fail**

Create `test/appAttest.testutil.ts` with `buildAssertionCbor(authData, rawSigDerFromRaw(sig))` (encode the 2-key CBOR map; convert WebCrypto raw ECDSA to DER). Then:

Run: `npx vitest run test/appAttest.assertion.test.ts`
Expected: FAIL — `verifyAssertion` not implemented.

- [ ] **Step 3: Implement `verifyAssertion` in `src/lib/appAttest.ts`**

```ts
export async function verifyAssertion(args: {
  assertionB64u: string; challenge: string; rawBody: Uint8Array;
  publicKeyDer: Uint8Array; storedSignCount: number;
}): Promise<{ newSignCount: number }> {
  const obj: any = decodeCbor(b64uToBytes(args.assertionB64u));
  const sigDer: Uint8Array = obj.signature;
  const authData: Uint8Array = obj.authenticatorData;
  if (!(sigDer instanceof Uint8Array) || !(authData instanceof Uint8Array)) throw new AppAttestError("assert: bad shape");

  // rpIdHash + counter.
  if (!eqLen(authData.subarray(0, 32), await rpIdHash())) throw new AppAttestError("assert: rpIdHash mismatch");
  const counter = ((authData[33]! << 24) | (authData[34]! << 16) | (authData[35]! << 8) | authData[36]!) >>> 0;
  if (counter <= args.storedSignCount) throw new AppAttestError("assert: counter not increasing (replay)");

  // nonce = sha256(authData || sha256(challenge || sha256(body))).
  const bodyHash = new Uint8Array(await crypto.subtle.digest("SHA-256", args.rawBody));
  const cdh = new Uint8Array(await crypto.subtle.digest("SHA-256",
    concat(new TextEncoder().encode(args.challenge), bodyHash)));
  const nonce = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(authData, cdh)));

  const key = await crypto.subtle.importKey("spki", args.publicKeyDer, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  const rawSig = derToRawEcdsa(sigDer); // 64-byte r||s for WebCrypto
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSig, nonce);
  if (!ok) throw new AppAttestError("assert: signature invalid");
  return { newSignCount: counter };
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; }
function eqLen(a: Uint8Array, b: Uint8Array): boolean { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a[i]! ^ b[i]!; return d === 0; }
/** DER-encoded ECDSA (SEQUENCE{INTEGER r, INTEGER s}) → raw 64-byte r||s. */
export function derToRawEcdsa(der: Uint8Array): Uint8Array {
  let p = 2; // skip SEQUENCE tag+len (short form for P-256 sigs)
  if (der[1]! & 0x80) p = 2 + (der[1]! & 0x7f);
  const readInt = () => { if (der[p]! !== 0x02) throw new AppAttestError("assert: bad DER int"); let len = der[++p]!; p++; let v = der.subarray(p, p + len); p += len; while (v.length > 32 && v[0] === 0) v = v.subarray(1); return v; };
  const r = readInt(); const s = readInt();
  const out = new Uint8Array(64); out.set(r, 32 - r.length); out.set(s, 64 - s.length); return out;
}
```

- [ ] **Step 4: Run test to verify it passes (accept + replay reject)**

Run: `npx vitest run test/appAttest.assertion.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/appAttest.ts test/appAttest.assertion.test.ts test/appAttest.testutil.ts
git commit -m "feat(attest): App Attest assertion verifier (ECDSA + anti-replay counter)"
```

---

### Task 6: challenge store (KV)

**Files:**
- Create: `src/lib/attestChallenge.ts`
- Test: `test/attestChallenge.test.ts`

**Interfaces:**
- Produces: `mintChallenge(kv: KVNamespace): Promise<string>`; `consumeChallenge(kv: KVNamespace, challenge: string): Promise<boolean>` (true iff it existed and was unused; deletes it).

- [ ] **Step 1: Write the failing test**

```ts
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
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/attestChallenge.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement `src/lib/attestChallenge.ts`**

```ts
import { bytesToB64u } from "./cbor";

const TTL_SECONDS = 120;

export async function mintChallenge(kv: KVNamespace): Promise<string> {
  const c = bytesToB64u(crypto.getRandomValues(new Uint8Array(32)));
  await kv.put(`att_chal:${c}`, "1", { expirationTtl: TTL_SECONDS });
  return c;
}
export async function consumeChallenge(kv: KVNamespace, challenge: string): Promise<boolean> {
  const key = `att_chal:${challenge}`;
  const hit = await kv.get(key);
  if (hit === null) return false;
  await kv.delete(key);
  return true;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx vitest run test/attestChallenge.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/attestChallenge.ts test/attestChallenge.test.ts
git commit -m "feat(attest): single-use KV challenge store"
```

---

### Task 7: `/attest/challenge` + `/attest/verify` routes

**Files:**
- Create: `src/routes/attest.ts`
- Modify: `src/app.ts` (mount + rate limit), `src/middleware/auth.ts` (`PUBLIC_PATHS` add `"/attest/"`)
- Test: `test/attest.routes.test.ts`

**Interfaces:**
- Consumes: `mintChallenge`, `consumeChallenge`, `verifyAttestation`.
- Produces: `attestRoutes` Hono app; `GET /attest/challenge → { challenge }`; `POST /attest/verify { keyId, attestation, challenge } → { ok: true }` (stores the key row).

- [ ] **Step 1: Write the failing test**

```ts
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("/attest routes", () => {
  it("challenge returns a token; verify rejects garbage", async () => {
    const ch = await SELF.fetch("https://x/attest/challenge");
    expect(ch.status).toBe(200);
    const { challenge } = (await ch.json()) as { challenge: string };
    expect(challenge.length).toBeGreaterThan(20);

    const v = await SELF.fetch("https://x/attest/verify", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ keyId: "k", attestation: "AAAA", challenge }),
    });
    expect(v.status).toBe(400); // bad attestation
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/attest.routes.test.ts`
Expected: FAIL — 404 (routes not mounted).

- [ ] **Step 3: Implement `src/routes/attest.ts`**

```ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { mintChallenge, consumeChallenge } from "../lib/attestChallenge";
import { verifyAttestation, AppAttestError } from "../lib/appAttest";

export const attestRoutes = new Hono<AppEnv>();

attestRoutes.get("/challenge", async (c) => {
  return c.json({ challenge: await mintChallenge(c.env.KV) });
});

attestRoutes.post("/verify", async (c) => {
  const body = (await c.req.json().catch(() => null)) as
    | { keyId?: string; attestation?: string; challenge?: string } | null;
  if (!body?.keyId || !body.attestation || !body.challenge) {
    throw new ApiError("VALIDATION_FAILED", "keyId, attestation, challenge required");
  }
  if (!(await consumeChallenge(c.env.KV, body.challenge))) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Unknown or used challenge");
  }
  let result;
  try {
    result = await verifyAttestation({
      attestationB64u: body.attestation, challenge: body.challenge, keyId: body.keyId,
    });
  } catch (e) {
    if (e instanceof AppAttestError) throw new ApiError("VALIDATION_FAILED", "Attestation failed");
    throw e;
  }
  const deviceId = c.req.header("X-Device-Id") ?? null;
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO attest_keys (key_id, device_id, public_key, sign_count, aaguid, created_at, last_used_at)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(key_id) DO UPDATE SET device_id = excluded.device_id, last_used_at = excluded.last_used_at`,
  ).bind(result.keyId, deviceId, result.publicKeyDer, result.signCount, result.aaguid, now, now).run();
  return c.json({ ok: true });
});
```

- [ ] **Step 4: Mount + allowlist + rate limit**

- `src/middleware/auth.ts`: add `"/attest/"` to `PUBLIC_PATHS`.
- `src/app.ts`: after the `app.use("/auth/*", rateLimit("auth"));` line add `app.use("/attest/*", rateLimit("auth"));`, and with the other `app.route(...)` calls add `app.route("/attest", attestRoutes);` (import it at top).

- [ ] **Step 5: Run to verify it passes**

Run: `npx vitest run test/attest.routes.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/routes/attest.ts src/app.ts src/middleware/auth.ts test/attest.routes.test.ts
git commit -m "feat(attest): /attest/challenge + /attest/verify routes"
```

---

### Task 8: `attestMiddleware` + enforcement modes + version gate

**Files:**
- Create: `src/middleware/attest.ts`
- Modify: `src/routes/auth.ts` (insert `attestMiddleware()` on the six entry routes)
- Test: `test/attest.middleware.test.ts`

**Interfaces:**
- Consumes: `consumeChallenge`, `verifyAssertion`, `env.ATTEST_MODE`, `env.ATTEST_MIN_BUILD`.
- Produces: `attestMiddleware(): MiddlewareHandler<AppEnv>` — sets `c.var.attested` and rejects per mode. Adds `attested?: boolean` to `Variables` in `src/env.ts`.

- [ ] **Step 1: Write the failing tests (one per mode)**

```ts
import { env, SELF } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

afterEach(() => vi.restoreAllMocks());
const req = (mode: string, headers: Record<string,string> = {}) => {
  (env as any).ATTEST_MODE = mode; (env as any).ATTEST_MIN_BUILD = "70";
  vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  return SELF.fetch("https://x/auth/otp/request", {
    method: "POST", headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ email: "m@e.co" }),
  });
};

describe("attestMiddleware modes", () => {
  it("off: un-attested request passes (202)", async () => { expect((await req("off")).status).toBe(202); });
  it("soft: un-attested request passes (202) and is logged", async () => { expect((await req("soft")).status).toBe(202); });
  it("enforce-new: old build (no header) is EXEMPT → 202", async () => {
    expect((await req("enforce-new", { "x-app-build": "60" })).status).toBe(202);
  });
  it("enforce-new: new build without valid attestation → 401", async () => {
    expect((await req("enforce-new", { "x-app-build": "70" })).status).toBe(401);
  });
  it("enforce-all: un-attested → 401", async () => { expect((await req("enforce-all")).status).toBe(401); });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx vitest run test/attest.middleware.test.ts`
Expected: FAIL — no middleware; all return 202.

- [ ] **Step 3: Add `attested` to `Variables`**

In `src/env.ts` `Variables`, add: `/** True when a valid App Attest assertion accompanied the request. */ attested?: boolean;`

- [ ] **Step 4: Implement `src/middleware/attest.ts`**

```ts
import type { MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { consumeChallenge } from "../lib/attestChallenge";
import { verifyAssertion, AppAttestError } from "../lib/appAttest";

/** Verify an App Attest assertion (if present) and enforce per env.ATTEST_MODE. Mount on the six
 *  auth-bootstrap ENTRY routes (not /auth/refresh). Reads the raw body and re-exposes it so the
 *  downstream zod validator still parses (Hono lets handlers re-read via c.req.json()). */
export function attestMiddleware(): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const mode = c.env.ATTEST_MODE ?? "off";
    if (mode === "off") return next();

    const keyId = c.req.header("X-Attest-Key-Id");
    const assertion = c.req.header("X-Attest-Assertion");
    const challenge = c.req.header("X-Attest-Challenge");
    const build = Number(c.req.header("X-App-Build") ?? "0");

    let attested = false;
    if (keyId && assertion && challenge) {
      try {
        const rawBody = new Uint8Array(await c.req.raw.clone().arrayBuffer());
        if (!(await consumeChallenge(c.env.KV, challenge))) throw new AppAttestError("stale challenge");
        const row = await c.env.DB.prepare(
          "SELECT public_key, sign_count FROM attest_keys WHERE key_id = ?",
        ).bind(keyId).first<{ public_key: ArrayBuffer; sign_count: number }>();
        if (!row) throw new AppAttestError("unknown keyId");
        const { newSignCount } = await verifyAssertion({
          assertionB64u: assertion, challenge, rawBody,
          publicKeyDer: new Uint8Array(row.public_key), storedSignCount: row.sign_count,
        });
        await c.env.DB.prepare("UPDATE attest_keys SET sign_count = ?, last_used_at = ? WHERE key_id = ?")
          .bind(newSignCount, nowMs(), keyId).run();
        attested = true;
      } catch (e) {
        if (!(e instanceof AppAttestError)) throw e;
        attested = false;
      }
    }
    c.set("attested", attested);

    if (attested) return next();
    if (mode === "soft") { console.log("attest soft: unattested", { path: c.req.path, build }); return next(); }
    if (mode === "enforce-new") {
      const min = Number(c.env.ATTEST_MIN_BUILD ?? "0");
      if (build < min) return next(); // older installs exempt
      throw new ApiError("AUTH_INVALID_TOKEN", "App verification required");
    }
    // enforce-all
    throw new ApiError("AUTH_INVALID_TOKEN", "App verification required");
  };
}
```

- [ ] **Step 5: Wire onto the six entry routes in `src/routes/auth.ts`**

Import `attestMiddleware` and insert it as the first middleware on each of the six routes, e.g.:
```ts
authRoutes.post("/otp/request", attestMiddleware(), validate("json", otpRequestBody), async (c) => { ... });
```
Apply identically to `/otp/verify`, `/password/login`, `/apple`, `/magic-link/request`, `/magic-link/verify`. **Do NOT** add it to `/refresh`, `/magic`, `/signout`, `/me`.

- [ ] **Step 6: Run to verify it passes**

Run: `npx vitest run test/attest.middleware.test.ts`
Expected: PASS (all five mode cases).

- [ ] **Step 7: Full suite regression**

Run: `npx vitest run`
Expected: PASS (existing auth tests run with `ATTEST_MODE` unset → `off`, so they are unaffected).

- [ ] **Step 8: Commit**

```bash
git add src/middleware/attest.ts src/routes/auth.ts src/env.ts test/attest.middleware.test.ts
git commit -m "feat(attest): assertion middleware + phased enforcement (off/soft/enforce-new/all)"
```

---

### Task 9: iOS — `AppAttestor`, APIClient wiring, entitlements

**Files:**
- Create: `Snapceipt/Sync/AppAttestor.swift`
- Modify: `Snapceipt/Sync/APIClient.swift` (attach attest headers on the six routes; send `X-App-Build`)
- Modify: `Snapceipt/Snapceipt.entitlements`, `Snapceipt/Snapceipt.Release.entitlements`
- Test: `SnapceiptTests/AppAttestorTests.swift`

**Interfaces:**
- Produces: `actor AppAttestor { func headers(forBody: Data) async -> [String:String] }` returning `{}` when unsupported/failed (so the request proceeds unattested — server decides).

- [ ] **Step 1: Add entitlements**

`Snapceipt/Snapceipt.entitlements`: add
```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>development</string>
```
`Snapceipt/Snapceipt.Release.entitlements`: same key with `<string>production</string>`.

- [ ] **Step 2: Write the failing test**

`SnapceiptTests/AppAttestorTests.swift`:
```swift
import XCTest
@testable import Snapceipt

final class AppAttestorTests: XCTestCase {
    func testUnsupportedYieldsNoHeaders() async {
        // On the Simulator DCAppAttestService.isSupported == false → headers empty (fail-open to server).
        let a = AppAttestor(baseURL: URL(string: "https://api.snapceipt.cc")!, deviceId: "dev-1")
        let h = await a.headers(forBody: Data("{}".utf8))
        XCTAssertTrue(h.isEmpty)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AppAttestorTests`
Expected: FAIL — `AppAttestor` undefined.

- [ ] **Step 4: Implement `Snapceipt/Sync/AppAttestor.swift`**

```swift
import Foundation
import DeviceCheck
import CryptoKit

/// Produces App Attest headers for the six auth-bootstrap requests. Fails OPEN (returns [:]) on
/// Simulator / unsupported / any error, so the request still goes through and the server's
/// ATTEST_MODE decides acceptance. Persists the keyId in the Keychain.
actor AppAttestor {
    private let baseURL: URL
    private let deviceId: String
    private let service = DCAppAttestService.shared
    private var keyId: String?
    private var attested = false

    init(baseURL: URL, deviceId: String) { self.baseURL = baseURL; self.deviceId = deviceId }

    func headers(forBody body: Data) async -> [String: String] {
        guard service.isSupported else { return [:] }
        do {
            let keyId = try await ensureAttestedKey()
            let challenge = try await fetchChallenge()
            let bodyHash = Data(SHA256.hash(data: body))
            var cdhInput = Data(challenge.utf8); cdhInput.append(bodyHash)
            let clientDataHash = Data(SHA256.hash(data: cdhInput))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            return [
                "X-Attest-Key-Id": keyId,
                "X-Attest-Assertion": assertion.base64URLEncodedString(),
                "X-Attest-Challenge": challenge,
                "X-App-Build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            ]
        } catch { return [:] }
    }

    private func ensureAttestedKey() async throws -> String {
        if let k = keyId, attested { return k }
        let stored = KeychainBox.read("appattest.keyId")
        let key = try await (stored ?? service.generateKey())
        let challenge = try await fetchChallenge()
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await service.attestKey(key, clientDataHash: clientDataHash)
        try await postVerify(keyId: key, attestation: attestation, challenge: challenge)
        KeychainBox.write("appattest.keyId", key)
        self.keyId = key; self.attested = true
        return key
    }

    private func fetchChallenge() async throws -> String {
        var r = URLRequest(url: baseURL.appendingPathComponent("attest/challenge"))
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (d, _) = try await URLSession.shared.data(for: r)
        struct C: Decodable { let challenge: String }
        return try JSONDecoder().decode(C.self, from: d).challenge
    }
    private func postVerify(keyId: String, attestation: Data, challenge: String) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("attest/verify"))
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "keyId": keyId, "attestation": attestation.base64URLEncodedString(), "challenge": challenge,
        ])
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
```
> `KeychainBox.read/write` is a tiny Keychain helper — if the app lacks one, add `Snapceipt/Sync/KeychainBox.swift` with `SecItem` get/set for a `String` under a service+account key. (Mirror any existing Keychain usage in `AuthStore`.)

- [ ] **Step 5: Wire into `APIClient` (the six routes only)**

In `APIClient.swift`, hold an `AppAttestor` and, in the request builder for the six auth-bootstrap paths, merge `await attestor.headers(forBody: body)` into the request headers (skip under `-uiTestStub`/E2E, matching the existing stub flags). Do NOT attach on `/auth/refresh` or authenticated routes.

- [ ] **Step 6: Run to verify the sim test passes + build**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AppAttestorTests`
Expected: PASS (headers empty on sim). Then run the full auth UITests to confirm no regression (enforcement off in the test backend).

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Sync/AppAttestor.swift Snapceipt/Sync/APIClient.swift Snapceipt/Snapceipt.entitlements Snapceipt/Snapceipt.Release.entitlements SnapceiptTests/AppAttestorTests.swift
git commit -m "feat(attest): iOS AppAttestor + APIClient wiring + entitlements"
```

---

### Task 10: Real-device vector + acceptance test + rollout runbook

**Files:**
- Create: `test/fixtures/appattest/attestation.json`, `test/fixtures/appattest/assertion.json`
- Modify: `test/appAttest.attestation.test.ts` (add the positive vector test)

- [ ] **Step 1: Capture a real-device attestation + assertion**

On a physical iPhone running an internal (`development` env) build, log one `{ attestation, challenge, keyId }` from a real `/attest/verify` and one `{ assertion, challenge, body }` from a real signed auth call; paste into the two fixture JSON files. (App Attest cannot be exercised on the Simulator — this is the only step needing hardware.)

- [ ] **Step 2: Add the positive acceptance test**

```ts
import attestation from "./fixtures/appattest/attestation.json";
it("accepts a captured real-device attestation", async () => {
  const r = await verifyAttestation(attestation as any);
  expect(r.keyId).toBe((attestation as any).keyId);
  expect(r.publicKeyDer.length).toBeGreaterThan(80);
});
```

- [ ] **Step 3: Run the full attest suite**

Run: `npx vitest run test/appAttest.attestation.test.ts test/appAttest.assertion.test.ts`
Expected: PASS (negatives + captured positive).

- [ ] **Step 4: Rollout runbook (execute over days/weeks, not in one sitting)**

1. Deploy Worker (Tasks 1–8) with `ATTEST_MODE=off` (inert). `npx wrangler deploy`.
2. Ship the iOS build (Task 9) to TestFlight → App Store. Record its `CFBundleVersion` as `ATTEST_MIN_BUILD`.
3. `wrangler secret`/vars: set `ATTEST_MIN_BUILD=<that build>`, then `ATTEST_MODE=soft` → deploy. Watch Worker logs for `attest soft: unattested` rate from the new build; confirm valid assertions arrive.
4. When valid-assertion rate from the new build is high and false-positives ~0: set `ATTEST_MODE=enforce-new` → deploy. Abuse via the app path dies; older installs remain exempt.
5. (Optional, later) add a hard min-version gate in-app, then `ATTEST_MODE=enforce-all`.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/appattest/ test/appAttest.attestation.test.ts
git commit -m "test(attest): captured real-device attestation acceptance vector"
```

---

## Self-review notes (coverage vs. spec §5)
- §5.1 iOS AppAttestor/entitlements/headers/test-seam → Task 9. §5.2 challenge + verify + chain/nonce/rpId/keyId → Tasks 4,6,7. §5.3 assertion middleware + counter → Tasks 5,8. §5.4 migration + purge → Task 1. §5.5 modes + version gate → Tasks 2,8. §6 rollout → Task 10. §7 tests → each task's test + Task 10 vectors. §3 `/auth/refresh` excluded → Task 8 Step 5.
