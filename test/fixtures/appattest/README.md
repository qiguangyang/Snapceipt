# App Attest test fixtures (real-device capture — DEFERRED)

The App Attest verifier (`src/lib/appAttest.ts`) is fully implemented and unit-tested here for:
- **Negatives** (garbage/wrong-format attestation rejected) — `test/appAttest.attestation.test.ts`.
- The **nonce-extension extractor** against a synthetic DER buffer — same file.
- The **assertion path end-to-end** with a self-signed P-256 key (real crypto round-trip) — `test/appAttest.assertion.test.ts`.

What CANNOT be produced in CI / on the Simulator is a **genuine Apple attestation blob** (the Secure Enclave + Apple cert chain only exist on a physical device — `DCAppAttestService.isSupported == false` on the Simulator). That positive-acceptance test is intentionally left as an `it.todo` in `test/appAttest.attestation.test.ts`.

## How to capture the vector (once, on a physical iPhone)

1. Run an internal **development**-environment build (`Snapceipt.entitlements` → `appattest-environment = development`) on a real iPhone against a Worker that has the `/attest/*` routes deployed.
2. In `AppAttestor` (or via a temporary log), capture one **attestation** exchange and one **assertion** exchange:
   - `attestation.json`: `{ "attestationB64u": "<base64url of the attestation object>", "challenge": "<the challenge string from GET /attest/challenge>", "keyId": "<the base64url keyId>" }`
   - `assertion.json`: `{ "assertionB64u": "<base64url assertion>", "challenge": "<challenge>", "body": "<the exact request body bytes, base64>", "publicKeyDer": "<base64 of the leaf SPKI DER returned by /attest/verify>", "storedSignCount": 0 }`
3. Drop both files in this directory.

## Wiring the positive test

Replace the `it.todo(...)` in `test/appAttest.attestation.test.ts` with a real test that loads `attestation.json` and asserts `verifyAttestation(...)` returns the expected `keyId`.

**IMPORTANT — validity window / replay:** `verifyAttestation` enforces the leaf cert's validity window via `Date.now()` (no injectable clock, to keep the required signature). Apple App Attest credCerts are short-lived, so a captured vector will be **expired** when replayed later. In the test, freeze time with `vi.setSystemTime(<the capture instant>)`, or re-capture fresh each time.

Until then, do NOT flip `ATTEST_MODE` past `soft` in production without at least one successful real-device round-trip through `/attest/verify` + an assertion-gated auth call (which is itself a live acceptance test).
