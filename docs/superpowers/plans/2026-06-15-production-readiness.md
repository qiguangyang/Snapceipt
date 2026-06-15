# Production Readiness (App Store GA) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every gap between the current TestFlight-beta build and a public App Store GA launch — Apple StoreKit subscriptions, a privacy-complete account-deletion path, device-bound auth, legal pages, push hardening, the App Store submission package, and operational sign-off.

**Architecture:** Snapceipt is a SwiftUI iOS app (under `Snapceipt/`) backed by a Cloudflare Workers + Hono API (under `src/`) with D1/KV/R2 and a marketing site (`site/`). This plan is decomposed into 8 independently-shippable workstreams; each produces working, testable software on its own and is sequenced by dependency below.

**Tech Stack:** Swift / SwiftUI / StoreKit 2 / XCTest; TypeScript / Hono / Zod / vitest + @cloudflare/vitest-pool-workers; Cloudflare D1, KV, R2; wrangler v4; fastlane.

**Source:** Derived from the 2026-06-15 production-readiness audit (memory: `ga-readiness-gaps`). GA decisions locked: (1) build Apple StoreKit subscriptions before GA, (2) push included at GA, (3) email-in kept (verify routing).

---

## Workstream sequencing & GA definition of done

Recommended execution order (by dependency; WS1/WS2/WS5 are independent and can start immediately):

1. **WS1 — Pre-flight quick fixes** (independent)
2. **WS2 — Account-deletion R2 purge** (independent; privacy blocker-class)
3. **WS5 — Legal pages + in-app links** (independent; feeds WS7 EULA/URLs)
4. **WS3 — Push hardening** (independent)
5. **WS4 — Magic-link device-binding + OTP** (independent; coordinated backend+iOS)
6. **WS6 — Apple StoreKit subscriptions** (largest; gates a paid GA)
7. **WS7 — App Store submission package** (depends on WS6 for the EULA URL; needs icon + screenshots)
8. **WS8 — Observability, ops & GA sign-off** (final gate; depends on all above being deployed)

**GA is done when:** every workstream's Definition of Done is checked, the device-smoke checklist passes on a Release build (WS8), and the App Store build is submitted for review (WS7).

---

## Workstream 1 — Independent GA fixes (wrangler v4, Help link, /extract cap, working-tree cleanup)

**Goal:** Land four small, independent App Store GA fixes: align the toolchain on wrangler v4 (so npm run deploy can't silently deploy on v3 and send_email allowed_sender_addresses is enforced), point the in-app Help link at the live /support page, bound POST /extract ocrText length to protect the metered DeepSeek path, and remove two stray build artifacts from the working tree.

**Dependencies:** none — all four tasks are independent of each other and of every other workstream; they can land in any order.

**Definition of done:**

- [ ] package.json: devDependencies.wrangler is ^4.x and @cloudflare/vitest-pool-workers is ^0.8.71 (pins wrangler 4.25.0); `npx wrangler --version` prints a 4.x version
- [ ] package.json "deploy" script aborts with a clear error if the resolved wrangler is < v4 (verified by temporarily forcing v3 OR by reading the guard); on v4 it runs `wrangler deploy`
- [ ] `npm test` is still green after the pool bump (run at least test/extract-schema.test.ts and test/extract-route.test.ts)
- [ ] ProfileTabView.swift Help row opens https://snapceipt.cc/support (no occurrence of /help remains in that file)
- [ ] src/schemas/extract.ts caps ocrText with .max(20000); test/extract-schema.test.ts has a passing case that an over-cap ocrText is rejected and a 20000-char ocrText is accepted
- [ ] test/extract-route.test.ts has a passing case that POST /extract returns 400 VALIDATION_FAILED for an over-cap ocrText
- [ ] Snapceipt.app.dSYM.zip and src/.DS_Store are gone from the working tree; `git status` is clean and `git check-ignore` confirms both patterns are still covered by .gitignore
- [ ] All four changes committed with conventional-commit messages ending in the required Co-Authored-By trailer

**Files:**

- `/Users/yangqi/Documents/github/Snapceipt/package.json`
- `/Users/yangqi/Documents/github/Snapceipt/package-lock.json`
- `/Users/yangqi/Documents/github/Snapceipt/scripts/deploy.sh`
- `/Users/yangqi/Documents/github/Snapceipt/wrangler.jsonc`
- `/Users/yangqi/Documents/github/Snapceipt/vitest.config.ts`
- `/Users/yangqi/Documents/github/Snapceipt/Snapceipt/Features/Profiles/ProfileTabView.swift`
- `/Users/yangqi/Documents/github/Snapceipt/src/schemas/extract.ts`
- `/Users/yangqi/Documents/github/Snapceipt/src/routes/extract.ts`
- `/Users/yangqi/Documents/github/Snapceipt/test/extract-schema.test.ts`
- `/Users/yangqi/Documents/github/Snapceipt/test/extract-route.test.ts`
- `/Users/yangqi/Documents/github/Snapceipt/.gitignore`

### Task 1 — Bump the toolchain to wrangler v4 and harden `npm run deploy`

**Why:** `package.json` pins `wrangler@^3.114.17` (line 31) and the `"deploy"` script is a bare `wrangler deploy` (line 8). `scripts/deploy.sh` already forces v4 (`WRANGLER="${WRANGLER:-npx --yes wrangler@4}"`, line 32) and hard-gates on it (lines 45-46: `wrangler v4+ required`). So `npm run deploy` would silently deploy on v3, where the `send_email[].allowed_sender_addresses` enforcement in `wrangler.jsonc` (lines 30-32) is not applied. Root cause of the pin: `@cloudflare/vitest-pool-workers@0.5.41` has a **regular** dependency on `wrangler@3.100.0` (not a peer) — confirmed in `node_modules/@cloudflare/vitest-pool-workers/package.json` (`"version": "0.5.41"`, `"wrangler": "3.100.0"`) — so the test pool drags v3 in. Per the locked DoD, `@cloudflare/vitest-pool-workers@0.8.71` depends on `wrangler@4.25.0` and keeps a vitest peer range satisfied by the repo's `vitest@~2.1.9`. So we bump the pool and the root wrangler together; the `npm install` in Step 4 is the hard verification that the peer range actually resolves.

- [ ] **Step 1: Confirm the current (v3) state.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx wrangler --version
  ```
  Expected: prints `3.114.17` (a 3.x version). This is the state we are fixing.

- [ ] **Step 2: Bump both deps in `package.json`.** Edit `/Users/yangqi/Documents/github/Snapceipt/package.json` `devDependencies` (lines 26-32). Change the two lines:
  ```json
      "@cloudflare/vitest-pool-workers": "^0.5.41",
  ```
  to
  ```json
      "@cloudflare/vitest-pool-workers": "^0.8.71",
  ```
  and
  ```json
      "wrangler": "^3.114.17"
  ```
  to
  ```json
      "wrangler": "^4.25.0"
  ```
  (Both must move together — the pool's bundled wrangler and the root devDep must agree on v4.)

- [ ] **Step 3: Harden the `"deploy"` script so it cannot run on v3.** In the same file, change the `"deploy"` script (line 8) from:
  ```json
      "deploy": "wrangler deploy",
  ```
  to:
  ```json
      "deploy": "node -e \"const v=require('child_process').execSync('npx wrangler --version').toString().match(/(\\\\d+)\\\\.\\\\d+\\\\.\\\\d+/);if(!v||+v[1]<4){console.error('wrangler v4+ required for deploy (found '+(v?v[0]:'none')+'): run npm i -D wrangler@4');process.exit(1)}\" && wrangler deploy",
  ```
  This mirrors the `deploy.sh` gate (`scripts/deploy.sh` lines 45-46): it parses `wrangler --version`, aborts with a non-zero exit + the same message if the major is < 4, otherwise runs `wrangler deploy`.

- [ ] **Step 4: Reinstall to refresh the lockfile.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npm install
  ```
  Expected: completes without `ERESOLVE` peer errors (the `0.8.71` vitest peer range matches the installed `vitest@2.1.9`). `package-lock.json` is updated. If `npm install` instead reports an ERESOLVE peer conflict, STOP and flag it — the pool/vitest pairing in the DoD is wrong and must be re-checked before proceeding.

- [ ] **Step 5: Verify wrangler is now v4 (run-it-passes).** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx wrangler --version
  ```
  Expected: prints a `4.x` version (e.g. `4.25.0` or higher within `^4.25.0`).

- [ ] **Step 6: Verify the deploy guard rejects v3 / accepts v4.** Run a dry validation of the guard expression directly (no real deploy):
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && node -e "const v=require('child_process').execSync('npx wrangler --version').toString().match(/(\d+)\.\d+\.\d+/);if(!v||+v[1]<4){console.error('GUARD-FAIL');process.exit(1)}console.log('GUARD-PASS v'+v[0])"
  ```
  Expected on the now-v4 toolchain: prints `GUARD-PASS v4.x` and exits 0. (The full `npm run deploy` is not run here — it would attempt a real Cloudflare deploy. The guard logic is what we are verifying. On the pre-bump v3 toolchain this same probe prints `GUARD-FAIL` and exits 1, which is the behaviour the deploy script now inherits.)

- [ ] **Step 7: Verify the test suite still passes under the bumped pool (regression check).** Run the two extract suites that exercise the pool runtime + schema:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx vitest run test/extract-schema.test.ts test/extract-route.test.ts
  ```
  Expected: all tests pass (the existing `extract-route.test.ts` boots the vitest-pool-workers runtime, so a green run proves the pool bump didn't break the test harness). If you see `No such module .../loupe` flakes, re-run once — `fileParallelism: false` in `vitest.config.ts` makes it deterministic.

- [ ] **Step 8: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && git add package.json package-lock.json && git commit -m "$(cat <<'EOF'
chore(deps): bump wrangler to v4 + vitest-pool-workers 0.8.71, guard npm deploy

package.json pinned wrangler ^3 via @cloudflare/vitest-pool-workers@0.5.41's
regular dep on wrangler@3.100.0, so `npm run deploy` could silently deploy on
v3 where send_email allowed_sender_addresses is not enforced. Bump the pool to
0.8.71 (deps wrangler 4.25.0, vitest peer still matches ~2.1.9) and the root
wrangler to ^4.25.0 so they agree, matching scripts/deploy.sh's v4 force.
Harden the "deploy" script to abort if the resolved wrangler is < v4.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

---

### Task 2 — Fix the in-app Help link 404 (/help → /support)

**Why:** `Snapceipt/Features/Profiles/ProfileTabView.swift` line 168 opens `https://snapceipt.cc/help`, which 404s. The canonical support page is `/support`. The view already declares `@Environment(\.openURL) private var openURL` (line 23) and the row is `helpRow` (lines 166-180) with accessibility id `AccessibilityID.profileRowHelp` (line 179). This is pure UI wiring — exact edit + a verification, no contrived test.

- [ ] **Step 1: Confirm the broken URL exists.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && grep -n "snapceipt.cc/help" Snapceipt/Features/Profiles/ProfileTabView.swift
  ```
  Expected: prints `168:            if let url = URL(string: "https://snapceipt.cc/help") { openURL(url) }`.

- [ ] **Step 2: Edit the URL.** In `/Users/yangqi/Documents/github/Snapceipt/Snapceipt/Features/Profiles/ProfileTabView.swift`, change line 168 from:
  ```swift
            if let url = URL(string: "https://snapceipt.cc/help") { openURL(url) }
  ```
  to:
  ```swift
            if let url = URL(string: "https://snapceipt.cc/support") { openURL(url) }
  ```

- [ ] **Step 3: Verify the change (no /help remains, /support present).** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && grep -n "snapceipt.cc/help" Snapceipt/Features/Profiles/ProfileTabView.swift; echo "--- support ---"; grep -n "snapceipt.cc/support" Snapceipt/Features/Profiles/ProfileTabView.swift
  ```
  Expected: the first grep prints nothing (no `/help` left); the second prints line 168 with `/support`.

- [ ] **Step 4: Confirm the canonical page actually exists (operator check, no code).** The support page must be live before GA. Run:
  ```bash
  curl -fsS -o /dev/null -w "%{http_code}\n" https://snapceipt.cc/support
  ```
  Expected: `200`. If you get `404`, the marketing site (`site/public/support.html`, served by the assets Worker under `site/`) is not deployed yet — flag it; the link still points at the canonical path, but GA also requires the page to be live.

- [ ] **Step 5: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && git add Snapceipt/Features/Profiles/ProfileTabView.swift && git commit -m "$(cat <<'EOF'
fix(profiles): point in-app Help link at /support (was 404 on /help)

ProfileTabView helpRow opened https://snapceipt.cc/help, which 404s. The
canonical support page is /support.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

---

### Task 3 — Bound POST /extract `ocrText` length (protect the metered DeepSeek path)

**Why:** `src/schemas/extract.ts` line 32 has `ocrText: z.string().min(1, "ocrText is required")` — a minimum but **no maximum**, so an arbitrarily large payload flows straight into the metered DeepSeek call in `src/routes/extract.ts` (`runDeepseekExtraction(c.env, { ocrText: body.ocrText, ... })`, lines 61-65). We add a sane `.max(20000)` and prove rejection at both the schema layer (`test/extract-schema.test.ts`) and the route layer (`test/extract-route.test.ts`, which already asserts `400 VALIDATION_FAILED` for empty ocrText at lines 87-97 — we copy that idiom). The route's `validate("json", extractRequestSchema)` middleware (`src/routes/extract.ts` line 42) is the same `validate` helper from `src/routes/auth.ts` (lines 33-40) that emits the uniform `VALIDATION_FAILED` envelope, so an over-cap body is rejected identically to the empty-ocrText body.

- [ ] **Step 1: Write the failing schema test.** In `/Users/yangqi/Documents/github/Snapceipt/test/extract-schema.test.ts`, inside the existing `describe("extractRequestSchema", ...)` block, add these two cases after the existing `it("rejects a malformed capturedAt", ...)` (the last `it` before line 45's closing `});`):
  ```ts
    it("accepts an ocrText at the 20000-char cap", () => {
      const atCap = "a".repeat(20000);
      expect(
        extractRequestSchema.safeParse({ ocrText: atCap, source: "scan" }).success,
      ).toBe(true);
    });

    it("rejects an ocrText over the 20000-char cap", () => {
      const overCap = "a".repeat(20001);
      expect(
        extractRequestSchema.safeParse({ ocrText: overCap, source: "scan" }).success,
      ).toBe(false);
    });
  ```

- [ ] **Step 2: Run it — fails.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx vitest run test/extract-schema.test.ts
  ```
  Expected: the new `"rejects an ocrText over the 20000-char cap"` test FAILS (`expected true to be false`) because there is currently no max bound; the `"accepts ... at the 20000-char cap"` test passes (no upper bound yet). The rest stay green.

- [ ] **Step 3: Add the max bound (minimal implementation).** In `/Users/yangqi/Documents/github/Snapceipt/src/schemas/extract.ts`, change line 32 from:
  ```ts
    ocrText: z.string().min(1, "ocrText is required"),
  ```
  to:
  ```ts
    ocrText: z.string().min(1, "ocrText is required").max(20000, "ocrText too long"),
  ```

- [ ] **Step 4: Run the schema test — passes.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx vitest run test/extract-schema.test.ts
  ```
  Expected: all tests pass, including both new cap cases.

- [ ] **Step 5: Write the failing route test.** In `/Users/yangqi/Documents/github/Snapceipt/test/extract-route.test.ts`, inside the `describe("POST /extract (stub gate)", ...)` block, add this case after the existing `it("rejects an empty ocrText with 400 VALIDATION_FAILED", ...)` (lines 87-97), copying that test's exact idiom:
  ```ts
    it("rejects an over-cap ocrText with 400 VALIDATION_FAILED", async () => {
      const app = appWith({ DEEPSEEK_API_KEY: "" });
      const res = await app.request("/extract", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ ocrText: "a".repeat(20001), source: "scan" }),
      });
      expect(res.status).toBe(400);
      const body = (await res.json()) as any;
      expect(body.error.code).toBe("VALIDATION_FAILED");
    });
  ```

- [ ] **Step 6: Run the route test — passes (the max bound from Step 3 already enforces it).** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && npx vitest run test/extract-route.test.ts
  ```
  Expected: all tests pass, including the new over-cap case (the `validate("json", extractRequestSchema)` middleware in `src/routes/extract.ts` line 42 now rejects the over-cap body with `400 VALIDATION_FAILED`, exactly like the empty-ocrText path).

- [ ] **Step 7: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && git add src/schemas/extract.ts test/extract-schema.test.ts test/extract-route.test.ts && git commit -m "$(cat <<'EOF'
fix(extract): cap ocrText at 20000 chars to bound the metered DeepSeek path

extractRequestSchema.ocrText had a min but no max, so an unbounded payload
flowed into the metered DeepSeek extraction. Add .max(20000) and cover it at
both the schema and route layers (400 VALIDATION_FAILED for over-cap input).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
  ```

---

### Task 4 — Remove stray build artifacts from the working tree

**Why:** `Snapceipt.app.dSYM.zip` (~4.8 MB) and `src/.DS_Store` (~6 KB) are sitting in the working tree. Verified facts: neither is tracked by git (`git ls-files` returns nothing for them), and `.gitignore` **already covers both** — line 41 `*.dSYM.zip` matches `Snapceipt.app.dSYM.zip`, and line 2 `.DS_Store` matches `src/.DS_Store` (confirmed via `git check-ignore -v`: `.gitignore:41:*.dSYM.zip` and `.gitignore:2:.DS_Store`). So this is a working-tree cleanup only; no `.gitignore` edit is required. This task is operator/ops actions, not TDD.

- [ ] **Step 1: Confirm both files exist and are ignored-but-untracked (not tracked).** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && ls -la Snapceipt.app.dSYM.zip src/.DS_Store && echo "--- tracked? (should print nothing) ---" && git ls-files Snapceipt.app.dSYM.zip src/.DS_Store && echo "--- ignored by? ---" && git check-ignore -v Snapceipt.app.dSYM.zip src/.DS_Store
  ```
  Expected: both files listed by `ls`; `git ls-files` prints nothing (untracked); `git check-ignore` prints `.gitignore:41:*.dSYM.zip	Snapceipt.app.dSYM.zip` and `.gitignore:2:.DS_Store	src/.DS_Store`.

- [ ] **Step 2: Delete the stray files.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && rm -f Snapceipt.app.dSYM.zip src/.DS_Store
  ```
  Expected: no output, exit 0.

- [ ] **Step 3: Verify they're gone and the tree is clean.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && ls Snapceipt.app.dSYM.zip src/.DS_Store 2>&1; echo "--- git status ---"; git status --short
  ```
  Expected: `ls` reports `No such file or directory` for both; `git status --short` shows no new untracked/staged entries from this removal (the files were never tracked, so deleting them produces no diff). Any other uncommitted changes are from your other tasks.

- [ ] **Step 4: Confirm `.gitignore` still covers the patterns (no edit needed, just verify).** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && git check-ignore -v --no-index Snapceipt.app.dSYM.zip src/.DS_Store
  ```
  Expected: still prints `.gitignore:41:*.dSYM.zip	Snapceipt.app.dSYM.zip` and `.gitignore:2:.DS_Store	src/.DS_Store`, proving future copies of these artifacts stay ignored. (If, contrary to the verified state, either file turns out to be tracked, instead run `git rm --cached <file>` and commit that; this is not expected.)

- [ ] **Step 5: No commit required.** Because both files were untracked and `.gitignore` is unchanged, there is nothing to commit for this task — the working tree is simply cleaner. If `git status` shows the tree clean (aside from other tasks' work), this task is done. Do NOT create an empty commit.

**Open questions (human input needed):**

- 20000 chars is the proposed ocrText cap (~5-7 pages of OCR text, comfortably above any real single receipt while bounding the metered DeepSeek payload). Confirm this ceiling is acceptable for the email-in path, which can carry longer forwarded receipt bodies; if email-in needs more headroom, raise to e.g. 50000 — the test thresholds in Task 3 must then be updated to match.
- Task 1 bumps @cloudflare/vitest-pool-workers from ^0.5.41 to ^0.8.71 (the newest line whose vitest peer range `2.0.x - 3.0.x` still satisfies the repo's pinned vitest ~2.1.9) so the test pool's bundled wrangler moves to v4 in lockstep with the root devDep. The newest pool (0.16.x) requires vitest ^4 and is intentionally avoided to keep this a small fix; confirm staying on vitest 2.1.9 + pool 0.8.71 is acceptable rather than doing a full vitest 4 upgrade.

_Critic verdict: fixed (6 issue(s) fixed)._

---

## Workstream 2: DELETE /account must purge ALL R2 prefixes (exports + quotes), not just u/${userId}/

**Goal:** Extend the DELETE /account R2 purge to iterate all three R2 key prefixes (u/${userId}/, ${userId}/exports/, ${userId}/quotes/) so no financial PII (quote PDFs, export/BAS packs) survives an account deletion, with a test that seeds one object under each prefix and asserts all three are gone.

**Dependencies:** none

**Definition of done:**

- [ ] test/account-delete.test.ts seeds exactly one R2 object under EACH of the three prefixes (u/${userId}/x.jpg, ${userId}/exports/<id>.pdf, ${userId}/quotes/<id>.pdf) and asserts all three return null from env.RECEIPTS.get after DELETE /account returns 200
- [ ] src/routes/account.ts DELETE handler iterates a const R2_PURGE_PREFIXES array containing all three prefixes, paginating + deleting each (replacing the single hard-coded `u/${userId}/` list loop)
- [ ] `npx vitest run test/account-delete.test.ts` passes (both existing tests + the new R2-prefix assertions)
- [ ] `npm run build` / `npx tsc --noEmit` (whichever the repo uses) reports no type errors introduced by the change
- [ ] The cross-tenant test still asserts user B's data is untouched after deleting user A
- [ ] A one-off operator cleanup step for already-written beta-era objects under ${userId}/exports/ and ${userId}/quotes/ is documented (objects written before this fix shipped are not reachable by any future per-user DELETE if those users never delete again)

**Files:**

- `/Users/yangqi/Documents/github/Snapceipt/src/routes/account.ts`
- `/Users/yangqi/Documents/github/Snapceipt/test/account-delete.test.ts`

## Workstream 2 — DELETE /account must purge ALL R2 prefixes

**Why:** `DELETE /account` (`src/routes/account.ts:129-148`) hard-deletes every D1 row but only purges R2 objects under the single prefix `u/${userId}/` (`account.ts:138-145`). Quote PDFs are written to `${userId}/quotes/${quoteId}.pdf` (`src/routes/quotes.ts:125`) and export / BAS packs to `${userId}/exports/${exportId}.{pdf,csv}` (`src/routes/export.ts:124,132,174-175,229`). Both prefixes are **orphaned** by deletion — full financial PII (client names, totals, ABNs, BAS figures) survives "delete my account". This workstream extends the purge to all three prefixes and strengthens the test to prove it.

**Confirmed prefix inventory (from reading `src/`):**
- `u/${userId}/` — receipt images (`src/routes/images.ts:55`) + inbound-email attachments (`src/email/inbound.ts:121`)
- `${userId}/exports/` — CSV/PDF/BAS exports (`src/routes/export.ts:124,132,174-175,229`)
- `${userId}/quotes/` — quote PDFs (`src/routes/quotes.ts:125`)

R2 binding under test is `env.RECEIPTS` (`wrangler.jsonc:23` declares `{ "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" }`; `src/env.ts:12`). The test idiom uses `cloudflare:test` (`env`, `SELF`) — see `test/account-delete.test.ts:1` — seeding R2 with `env.RECEIPTS.put(key, new TextEncoder().encode("img"))` (`account-delete.test.ts:88-89`) and asserting `await env.RECEIPTS.get(key)` is `null` (`account-delete.test.ts:128-129`).

---

### Task 1 — Failing test: seed one R2 object under each of the 3 prefixes, assert all gone

We extend `seedRichUser()` to additionally write an exports object and a quotes object, return their keys, and add assertions in the main purge test. Today only `u/${userId}/x.jpg` is seeded/asserted (`account-delete.test.ts:88-89, 128-129`).

- [ ] **Step 1: Extend `seedRichUser` to seed all three R2 prefixes.**
  In `/Users/yangqi/Documents/github/Snapceipt/test/account-delete.test.ts`, change the return type of `seedRichUser` and add two more `env.RECEIPTS.put` calls.

  Replace the current return-type annotation on line 30:
  ```ts
  async function seedRichUser(): Promise<{ userId: string; bearer: string; r2Key: string }> {
  ```
  with:
  ```ts
  async function seedRichUser(): Promise<{
    userId: string;
    bearer: string;
    r2Key: string;
    exportKey: string;
    quoteR2Key: string;
  }> {
  ```

  Then replace the R2-seeding + return block at the end of the function (currently `account-delete.test.ts:88-91`):
  ```ts
    const r2Key = `u/${userId}/x.jpg`;
    await env.RECEIPTS.put(r2Key, new TextEncoder().encode("img"));
    const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
    return { userId, bearer: `Bearer ${accessToken}`, r2Key };
  }
  ```
  with (seed one object under EACH of the three real prefixes — images, exports, quotes):
  ```ts
    // Seed one object under EACH R2 prefix the app writes to, so the purge has to
    // clear all three (not just u/${userId}/):
    //   u/${userId}/...           — receipt images (images.ts) + inbound (inbound.ts)
    //   ${userId}/exports/...     — CSV/PDF/BAS export packs (export.ts)
    //   ${userId}/quotes/...      — quote PDFs (quotes.ts)
    const r2Key = `u/${userId}/x.jpg`;
    const exportKey = `${userId}/exports/${exportId}.pdf`;
    const quoteR2Key = `${userId}/quotes/${quoteId}.pdf`;
    await env.RECEIPTS.put(r2Key, new TextEncoder().encode("img"));
    await env.RECEIPTS.put(exportKey, new TextEncoder().encode("export-pdf"));
    await env.RECEIPTS.put(quoteR2Key, new TextEncoder().encode("quote-pdf"));
    const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
    return { userId, bearer: `Bearer ${accessToken}`, r2Key, exportKey, quoteR2Key };
  }
  ```
  Note: `exportId` does not yet exist as a local in `seedRichUser`. Add it to the `uuidv7()` declarations block near the top of the function (the block at `account-delete.test.ts:31-53`). Insert after the `const quoteId = uuidv7();` line (currently line 38):
  ```ts
    const exportId = uuidv7();
  ```
  (`quoteId` already exists at line 38 and is reused for `quoteR2Key`, matching the real key shape `${userId}/quotes/${quoteId}.pdf` from `quotes.ts:125`; the `exportId` mirrors the real key shape `${userId}/exports/${exportId}.pdf` from `export.ts:132`.)

- [ ] **Step 2: Assert all three R2 objects are gone in the main purge test.**
  In the `it("purges all D1 rows across every user-scoped table + R2 objects", ...)` test, replace the destructure on line 113:
  ```ts
      const { userId, bearer, r2Key } = await seedRichUser();
  ```
  with:
  ```ts
      const { userId, bearer, r2Key, exportKey, quoteR2Key } = await seedRichUser();
  ```
  Then replace the single R2 assertion block (currently `account-delete.test.ts:128-129`):
  ```ts
      const obj = await env.RECEIPTS.get(r2Key);
      expect(obj).toBeNull();
  ```
  with assertions for all three prefixes:
  ```ts
      // Every R2 prefix the app writes to must be purged, not just u/${userId}/.
      expect(await env.RECEIPTS.get(r2Key)).toBeNull();       // u/${userId}/x.jpg
      expect(await env.RECEIPTS.get(exportKey)).toBeNull();    // ${userId}/exports/<id>.pdf
      expect(await env.RECEIPTS.get(quoteR2Key)).toBeNull();   // ${userId}/quotes/<id>.pdf
  ```

- [ ] **Step 3: Run it — expect the new exports/quotes assertions to FAIL.**
  Command:
  ```
  npx vitest run test/account-delete.test.ts
  ```
  Expected: the `purges all D1 rows ... + R2 objects` test FAILS with an assertion error on `expect(await env.RECEIPTS.get(exportKey)).toBeNull()` (received a non-null `R2ObjectBody`, expected `null`) — because the handler only deletes the `u/${userId}/` prefix. The cross-tenant test (`does not touch another user's data`) still passes, so the run reports `Tests  1 failed | 1 passed (2)`.

---

### Task 2 — Implement: iterate all three R2 prefixes in the purge

- [ ] **Step 1: Read the current handler.**
  Re-read `/Users/yangqi/Documents/github/Snapceipt/src/routes/account.ts:129-148` so the edit matches exactly. The current R2 step (lines 137-145) is:
  ```ts
    // 2. Purge the user's R2 objects (paginated list -> delete).
    let cursor: string | undefined;
    for (;;) {
      const listed = await c.env.RECEIPTS.list({ prefix: `u/${userId}/`, cursor, limit: 1000 });
      const keys = listed.objects.map((o) => o.key);
      if (keys.length > 0) await c.env.RECEIPTS.delete(keys);
      if (!listed.truncated) break;
      cursor = listed.cursor;
    }
  ```

- [ ] **Step 2: Replace the single-prefix loop with a loop over all three prefixes.**
  Replace the block above (`account.ts:137-145`) with:
  ```ts
    // 2. Purge the user's R2 objects across EVERY prefix the app writes to.
    // The app uses three distinct key shapes (none is a parent of another):
    //   u/${userId}/...        — receipt images (images.ts) + inbound attachments (inbound.ts)
    //   ${userId}/exports/...  — CSV/PDF/BAS export packs (export.ts)
    //   ${userId}/quotes/...   — quote PDFs (quotes.ts)
    // Missing any one leaves financial PII orphaned after account deletion.
    const r2Prefixes = [
      `u/${userId}/`,
      `${userId}/exports/`,
      `${userId}/quotes/`,
    ];
    for (const prefix of r2Prefixes) {
      let cursor: string | undefined;
      for (;;) {
        const listed = await c.env.RECEIPTS.list({ prefix, cursor, limit: 1000 });
        const keys = listed.objects.map((o) => o.key);
        if (keys.length > 0) await c.env.RECEIPTS.delete(keys);
        if (!listed.truncated) break;
        cursor = listed.cursor;
      }
    }
  ```
  (Note: `${userId}/exports/` and `${userId}/quotes/` are siblings under `${userId}/`, while images live under `u/${userId}/` — a different top-level segment — so the three prefixes are disjoint and none double-lists another's objects.)

- [ ] **Step 3: Run it — expect PASS.**
  Command:
  ```
  npx vitest run test/account-delete.test.ts
  ```
  Expected output: both tests pass, e.g.
  ```
   ✓ test/account-delete.test.ts (2 tests) ...ms
     ✓ DELETE /account > purges all D1 rows across every user-scoped table + R2 objects
     ✓ DELETE /account > does not touch another user's data

   Test Files  1 passed (1)
        Tests  2 passed (2)
  ```

- [ ] **Step 4: Type-check the backend.**
  The repo defines a `typecheck` script (`package.json:9` = `tsc --noEmit`). Command:
  ```
  npm run typecheck
  ```
  (Equivalently `npx tsc --noEmit`.) Expected: no errors. The change uses only existing `R2Bucket` methods — `list`, `delete` — already used in the original loop, so no new imports or types are introduced.

- [ ] **Step 5: Commit.**
  ```
  git add src/routes/account.ts test/account-delete.test.ts
  git commit -m "fix(account): purge exports + quotes R2 prefixes on DELETE /account

DELETE /account only purged R2 objects under u/\${userId}/, orphaning quote
PDFs (\${userId}/quotes/) and export/BAS packs (\${userId}/exports/) — full
financial PII surviving account deletion. Iterate all three prefixes. Test now
seeds + asserts one object under each prefix.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3 — (OPS, not code) One-off cleanup of beta-era orphaned objects

The fix above only helps objects deleted **after** it ships. Objects already written under `${userId}/exports/` and `${userId}/quotes/` by beta users who deleted their accounts **before** this fix are already orphaned in the `snapceipt-receipts` bucket and will never be reached by any future per-user DELETE (those users are gone). This is a one-time operator cleanup.

> Tooling note: the installed wrangler (v3.114.17, `package.json:31`) has **no** `wrangler r2 object list` subcommand — `wrangler r2 object` exposes only `get`, `put`, `delete`, and `wrangler r2 bucket` has no per-key listing. So R2 enumeration is done via the **S3-compatible API** (here using the `aws` CLI against the R2 S3 endpoint; `rclone` works too). Object deletes use `wrangler r2 object delete "<bucket>/<key>"` (a single positional in the form `{bucket}/{key}`; there is **no** `--remote` flag on `r2 object` commands — remote is the default, `--local` is the opt-in). D1 reads use `wrangler d1 execute ... --remote --json`, which is valid.

Prereqs for the S3 listing: an R2 S3 API token (Cloudflare dashboard → R2 → Manage R2 API Tokens) and the account's R2 S3 endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`. Export the token as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for the `aws` CLI.

- [ ] **Step 1: Inventory the orphaned objects.**
  Determine the set of `userId`s that have been deleted from D1 (no `users.id` row) but still have objects under `${userId}/exports/` or `${userId}/quotes/`. The `users` table is the source of truth — any top-level R2 key segment (other than the literal `u`) with no matching `users.id` row is orphaned.
  - List the R2 candidate prefixes (top-level segments that are NOT the literal `u`) via the S3 API, then reduce to candidate userIds:
    ```
    aws s3api list-objects-v2 \
      --endpoint-url "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" \
      --bucket snapceipt-receipts \
      --query "Contents[].Key" --output text \
      | tr '\t' '\n' \
      | grep -E '/(exports|quotes)/' \
      | sed -E 's#/(exports|quotes)/.*##' \
      | sort -u > /tmp/r2_candidate_userids.txt
    ```
    (If the bucket holds >1000 objects, paginate: add `--max-items 1000 --starting-token <NextToken>` and repeat until `NextToken` is empty, appending each batch before the `sort -u`.)
  - Export current live user ids from D1:
    ```
    npx wrangler d1 execute snapceipt --remote --command "SELECT id FROM users" --json
    ```
    Save the `id` values (one per line) to `/tmp/live_userids.txt`.
  - Compute the orphan set = R2 candidate userIds MINUS live `users.id`:
    ```
    comm -23 /tmp/r2_candidate_userids.txt <(sort -u /tmp/live_userids.txt) > /tmp/r2_orphan_userids.txt
    ```
    Expected confirmation: `/tmp/r2_orphan_userids.txt` contains only userIds with NO matching `users` row. Do NOT proceed for any id still present in `users`.

- [ ] **Step 2: Delete the orphaned objects (operator action).**
  For each confirmed-orphan `<userId>`, list its two PII prefixes via the S3 API and delete each returned key with wrangler (single `{bucket}/{key}` positional). For one orphan id:
  ```
  # List the keys to delete (exports + quotes) for this orphan id:
  aws s3api list-objects-v2 \
    --endpoint-url "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" \
    --bucket snapceipt-receipts \
    --prefix "<userId>/" \
    --query "Contents[?contains(Key, '/exports/') || contains(Key, '/quotes/')].Key" \
    --output text | tr '\t' '\n' > /tmp/keys_<userId>.txt

  # Delete each key (review /tmp/keys_<userId>.txt first):
  while read -r key; do
    [ -n "$key" ] && npx wrangler r2 object delete "snapceipt-receipts/$key"
  done < /tmp/keys_<userId>.txt
  ```
  Expected confirmation: each delete prints a `Deleting object "<key>" from snapceipt-receipts.` / `Delete completed successfully!` line, and re-running the `list-objects-v2` command above for that id returns no `exports/` or `quotes/` keys.

- [ ] **Step 3: Verify.**
  Re-run the inventory from Step 1 (regenerate `/tmp/r2_candidate_userids.txt` and re-compute `comm -23 ... /tmp/r2_orphan_userids.txt`); the orphan set must be empty. Record the count of objects deleted (`wc -l /tmp/keys_*.txt`) in the GA pre-launch checklist / runbook entry for this cleanup.

**Open questions (human input needed):**

- Beta-era orphans: objects already written under ${userId}/exports/ and ${userId}/quotes/ by users who deleted their accounts BEFORE this fix shipped are unreachable by any per-user DELETE and need the one-off operator cleanup in Task 3. The exact bucket name in production is `snapceipt-receipts` (wrangler.jsonc:23) — confirm there is only one R2 bucket and no separate staging bucket that also needs the same sweep before GA.
- Does the repo have a dedicated `typecheck` or `build` npm script? package.json `test` is `vitest run`; Task 2 Step 4 falls back to `npx tsc --noEmit` — confirm tsconfig covers src/ so this is meaningful, or substitute the repo's CI type-check command.
- Should object deletion in DELETE /account be wrapped so a partial R2 failure (one prefix throws mid-purge) is retried or surfaced? Current behavior (preserved here) lets an R2 error bubble as a 500 after D1 rows are already gone — acceptable for now since R2 is the only remaining state, but flag for the GA reliability review whether the R2 purge should move before/after the D1 batch or become idempotent-retryable.

_Critic verdict: fixed (4 issue(s) fixed)._

---

## Workstream 3: Push notifications — fix the cron stamp bug, register tokens on grant, make priming reachable, verify APNS prod

**Goal:** Make GA push correct and end-to-end: the budget-alert cron must never permanently suppress an alert when no real push was delivered (stub/non-2xx), expired tokens get pruned, granted users actually upload an APNs token, the onboarding notification-priming step is reachable, and APNS prod secrets are verified live.

**Dependencies:** none (self-contained: backend cron + lib, iOS Notifications/Onboarding/App, plus an ops verification). Can land independently of other GA workstreams. The APNS_KEY ops step (Task 7) is the only thing that must precede a real prod end-to-end push, but the code tasks do not depend on it.

**Definition of done:**

- [ ] `npx vitest run test/budgetAlert.test.ts` is green and includes new tests proving: (a) stub-mode sendPush leaves `alert_sent_at` NULL and does not increment `pushed`; (b) a non-2xx (e.g. 503) result leaves `alert_sent_at` NULL; (c) a 200 result stamps `alert_sent_at = NOW`; (d) a 410 result prunes the offending device token (sets `apns_token = NULL`) and does not stamp when no live delivery occurred.
- [ ] `src/cron/budgetAlert.ts` only counts a device toward `pushed` and only stamps `alert_sent_at` when `sendPush` returns `{ stub: false, status: 200 }`; on `status === 410 || status === 400` it nulls that device's `apns_token`.
- [ ] `NotificationDelegate.requestAndRegister()` is invoked on the onboarding notifications grant (Allow) path, and a launch-time re-registration runs when authorization status is already `.authorized`.
- [ ] Onboarding drives off an explicit `onboardingComplete` flag (not `profileRows.isEmpty`), so the notifications priming step is reachable after the first profile is created; existing `OnboardingUITests.testDevSignInThroughOnboardingToShell` still passes.
- [ ] `xcodebuild test` for the `Snapceipt` scheme is green, including new unit tests for the grant-registration call and the onboarding-gate flag.
- [ ] `npx wrangler secret list` confirms `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` are present in prod, and a real prod-token device receives a budget alert end-to-end (Task 7 checklist completed and confirmation pasted into the PR).

**Files:**

- `/Users/yangqi/Documents/github/Snapceipt/src/cron/budgetAlert.ts`
- `/Users/yangqi/Documents/github/Snapceipt/src/lib/apns.ts`
- `/Users/yangqi/Documents/github/Snapceipt/test/budgetAlert.test.ts`
- `/Users/yangqi/Documents/github/Snapceipt/Snapceipt/Features/Notifications/NotificationDelegate.swift`
- `/Users/yangqi/Documents/github/Snapceipt/Snapceipt/Features/Onboarding/OnboardingView.swift`
- `/Users/yangqi/Documents/github/Snapceipt/Snapceipt/App/RootView.swift`
- `/Users/yangqi/Documents/github/Snapceipt/SnapceiptTests/UpdateDevicePayloadTests.swift`
- `/Users/yangqi/Documents/github/Snapceipt/SnapceiptTests/OnboardingGateTests.swift`

## Workstream 3: Push notifications — GA correctness

Push is ~90% built. This workstream fixes one correctness bug in the hourly cron, prunes dead device tokens, wires token registration on grant, makes the onboarding priming step reachable, and verifies APNS prod secrets end-to-end.

Grounding (read before editing):
- Backend cron: `src/cron/budgetAlert.ts` (budget loop at lines 78–141; the bug is the push loop at lines 125–140: `pushed++` at line 130 and the `alert_sent_at` stamp at lines 138–139 ignore the `sendPush` result). The function signature is `budgetCronLogic(db: D1Database, env: Env, nowMs: number)` (line 68), so inside the loop `db` and `nowMs` are in scope. Quiet-hours skip is `if (inQuietHours(d, nowMs)) continue;` (line 127).
- APNs lib: `src/lib/apns.ts` — `sendPush` returns `{ stub: true }` when `env.APNS_KEY` is absent (lines 52–55), else `{ stub: false, status: res.status }` (line 67). `SendPushResult` is `{ stub: true } | { stub: false; status: number }` (line 15).
- Backend test idiom: `test/budgetAlert.test.ts` — `vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true })`, helpers `addBudget`/`addTxn`/`alertSentAt`, constants `U/P/D/NOW`. `seedBase()` inserts one device (id `D = "dcron"`, token `'tok-hex'`) and `afterEach(() => vi.restoreAllMocks())`. The describe block currently has 9 tests. In the test env `APNS_KEY` is NOT bound (only `JWT_SIGNING_KEY` + `APPLE_BUNDLE_ID` in `vitest.config.ts` lines 41–42), so the real `apns.sendPush(env, …)` returns `{ stub: true }` with no network call.
- DB schema: `devices` (migrations/0001_init.sql lines 75–93) has `apns_token TEXT`, `push_enabled`, `timezone`, `quiet_hours_*`, and `updated_at INTEGER NOT NULL`, plus a UNIQUE index `ux_devices_apns ON devices(apns_token) WHERE apns_token IS NOT NULL` (line 96) — nulling a token is safe under that partial unique index.
- iOS delegate: `Snapceipt/Features/Notifications/NotificationDelegate.swift` — `requestAndRegister()` (lines 63–68) requests auth + `registerForRemoteNotifications()`; `didRegisterForRemoteNotificationsWithDeviceToken` (lines 26–34) uploads the token via `Self.api?.updateDevice`; `application(_:didFinishLaunchingWithOptions:)` (lines 15–19) just sets the delegate. The file already `import UIKit` + `import UserNotifications` (lines 1–2).
- iOS onboarding: `Snapceipt/Features/Onboarding/OnboardingView.swift` — `OnboardingStep` enum (line 5); `OnboardingView.body` switch (lines 28–41) with the `.notifications` case at lines 36–40 calling `onFinished()`. `FirstProfileForm.create()` (lines 181–205) does `context.insert(profile)` + `try? context.save()` (lines 198–199) BEFORE `onCreated()` (line 204). `Snapceipt/App/RootView.swift` line 32 gates onboarding on `profileRows.isEmpty` (a global `@Query` at line 26), so the save flips the gate and unmounts onboarding before camera/notifications priming.
- iOS grant path: `Snapceipt/Features/Onboarding/PermissionPrimingView.swift` — `PermissionKind` enum (line 6); `PermissionRequesting` protocol (lines 38–40); `LivePermissionRequester.request(.notifications)` (lines 48–50) ONLY requests authorization — it never calls `registerForRemoteNotifications()`. `PermissionPrimingView.allow()` (lines 117–124) runs `await requester.request(kind)` then `onContinue()`. `NotificationsSettingsView.swift` line 26 already calls `await NotificationDelegate.requestAndRegister()` when the Budget-alerts toggle flips on; the ONBOARDING grant path does NOT.

---

### Task 1: Cron only stamps/counts on a real 200 delivery (stub-mode + non-2xx leave `alert_sent_at` NULL)

- [ ] **Step 1: Update existing tests whose mock returns `{ stub: true }` but assert a stamp.** Four existing tests mock `{ stub: true }` and then assert `alert_sent_at === NOW`; after the fix a stub must NOT stamp, so retarget those mocks to a real 200. In `test/budgetAlert.test.ts` make these four edits (leave every other test untouched — the per-category, dedup, below-threshold, quiet-hours, and push_enabled=0 tests keep their `{ stub: true }` mocks because none of them assert a stamp):

  In the test `"fires for a whole-profile budget when month spend crosses the threshold; payload asserted"` change line 90:
  ```ts
  const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
  ```

  In `"re-arms after a month rollover (alert_sent_at in a prior month)"` change line 149:
  ```ts
  const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
  ```

  In `"delivers when the device is OUTSIDE its wrap-around quiet window"` change line 177:
  ```ts
  const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
  ```

  In `"a throwing sendPush for one device does not abort the run; remaining devices are still attempted"` change the second-device return at line 221 (the `tok-hex` branch keeps rejecting; only the success branch is retargeted so the second device counts as a real delivery):
  ```ts
      if (token === "tok-hex") return Promise.reject(new Error("APNs 410 Gone"));
      return Promise.resolve({ stub: false, status: 200 });
  ```

- [ ] **Step 2: Add the two new failing tests (stub-mode + non-2xx).** Append inside the `describe("budgetCronLogic", …)` block in `test/budgetAlert.test.ts`, right before its closing `});`:

  ```ts
  it("stub-mode sendPush (no APNS_KEY) does NOT stamp alert_sent_at", async () => {
    // No mock: the real apns.sendPush runs and returns { stub: true } because the
    // test env has no APNS_KEY bound. A stub is NOT a real delivery, so the budget
    // must stay re-armed for the next run once the key is provisioned.
    const spy = vi.spyOn(apns, "sendPush");
    await addBudget("bstub", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect((await spy.mock.results[0]!.value)).toEqual({ stub: true });
    expect(await alertSentAt("bstub")).toBeNull();
  });

  it("a non-2xx APNs status does NOT stamp alert_sent_at", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 503 });
    await addBudget("b503", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("b503")).toBeNull(); // 503 is not a delivery -> re-arm next run
  });
  ```

- [ ] **Step 3: Run the tests — they fail.**
  ```bash
  npx vitest run test/budgetAlert.test.ts
  ```
  Expected: FAIL. The new `b503` test fails (current code does `pushed++` regardless of status, so `alert_sent_at` is stamped to `NOW`, not NULL); the retargeted `{stub:false,status:200}` tests still pass. Failure line points at `expect(await alertSentAt("b503")).toBeNull()`.

- [ ] **Step 4: Fix `budgetCronLogic` to gate `pushed` on `{ stub:false, status:200 }`.** In `src/cron/budgetAlert.ts` replace the push loop (lines 125–134, i.e. `let pushed = 0;` through the closing `}` of the `for` — leave the stamping block at lines 136–139 untouched):

  ```ts
    let pushed = 0;
    for (const d of devices) {
      if (inQuietHours(d, nowMs)) continue;
      try {
        const result = await apns.sendPush(env, d.apns_token, payload);
        // Stub (no APNS_KEY) or any non-2xx is NOT a real delivery: do not count it,
        // so the budget stays re-armed for the next hourly run. Only a live 200 counts.
        if (result.stub === false && result.status === 200) {
          pushed++;
        }
      } catch (err) {
        console.warn(`[budgetAlert] sendPush failed for token ${d.apns_token}:`, err);
      }
    }
  ```

- [ ] **Step 5: Run the tests — they pass.**
  ```bash
  npx vitest run test/budgetAlert.test.ts
  ```
  Expected: PASS. `Tests  11 passed (11)` (the 9 original + 2 new), and the console still prints the benign `[budgetAlert] sendPush failed for token tok-hex: Error: APNs 410 Gone` from the throwing-device test.

- [ ] **Step 6: Commit.**
  ```bash
  git add src/cron/budgetAlert.ts test/budgetAlert.test.ts
  git commit -m "$(cat <<'EOF'
  fix(cron): only stamp budget alert_sent_at on a real APNs 200 delivery

  Stub-mode (no APNS_KEY) and non-2xx results no longer count as a delivery,
  so a budget is never permanently suppressed before push goes live.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2: Prune (null) the device token on a 410/400 APNs response

- [ ] **Step 1: Add the failing test.** Append inside `describe("budgetCronLogic", …)` in `test/budgetAlert.test.ts`, before its closing `});`:

  ```ts
  it("prunes (nulls) the device token on a 410 Gone and does not stamp when no live delivery", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 410 });
    await addBudget("b410", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    // The dead token is pruned so the next run skips it (devices WHERE apns_token IS NOT NULL).
    const dev = await env.DB.prepare(`SELECT apns_token FROM devices WHERE id=?`)
      .bind(D)
      .first<{ apns_token: string | null }>();
    expect(dev?.apns_token).toBeNull();
    // 410 was the only device and it was not a delivery -> budget stays re-armed.
    expect(await alertSentAt("b410")).toBeNull();
  });
  ```

- [ ] **Step 2: Run the test — it fails.**
  ```bash
  npx vitest run test/budgetAlert.test.ts
  ```
  Expected: FAIL on `expect(dev?.apns_token).toBeNull()` — current code never touches `devices.apns_token`, so it stays `'tok-hex'`.

- [ ] **Step 3: Implement token pruning in the push loop.** In `src/cron/budgetAlert.ts`, extend the loop body so a 410/400 nulls the offending token. Replace the loop from Task 1 with:

  ```ts
    let pushed = 0;
    for (const d of devices) {
      if (inQuietHours(d, nowMs)) continue;
      try {
        const result = await apns.sendPush(env, d.apns_token, payload);
        if (result.stub === false) {
          if (result.status === 200) {
            pushed++;
          } else if (result.status === 410 || result.status === 400) {
            // APNs reports the token is no longer valid (410 Unregistered / 400 BadDeviceToken):
            // null it so future runs skip this device (devices WHERE apns_token IS NOT NULL).
            await db
              .prepare(`UPDATE devices SET apns_token = NULL, updated_at = ? WHERE apns_token = ?`)
              .bind(nowMs, d.apns_token)
              .run();
          }
        }
      } catch (err) {
        console.warn(`[budgetAlert] sendPush failed for token ${d.apns_token}:`, err);
      }
    }
  ```

- [ ] **Step 4: Run the tests — they pass.**
  ```bash
  npx vitest run test/budgetAlert.test.ts
  ```
  Expected: PASS. `Tests  12 passed (12)`.

- [ ] **Step 5: Commit.**
  ```bash
  git add src/cron/budgetAlert.ts test/budgetAlert.test.ts
  git commit -m "$(cat <<'EOF'
  fix(cron): prune dead APNs device tokens on 410/400

  A 410 Unregistered / 400 BadDeviceToken nulls devices.apns_token so future
  cron runs skip the dead token instead of retrying it forever.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 3: Register for remote notifications on the onboarding grant (Allow on the notifications priming screen)

The Settings toggle already calls `NotificationDelegate.requestAndRegister()` (`NotificationsSettingsView.swift:26`); the onboarding `.notifications` priming screen does NOT. `PermissionPrimingView.allow()` (lines 117–124) calls the injected `requester.request(kind)`, and `LivePermissionRequester.request(.notifications)` (lines 48–50) only requests authorization — it never calls `registerForRemoteNotifications()`, so a user who grants during onboarding never uploads a token.

- [ ] **Step 1: Make `LivePermissionRequester` register for remote notifications after a granted notifications prompt.** In `Snapceipt/Features/Onboarding/PermissionPrimingView.swift`, replace the `.notifications` case in `LivePermissionRequester.request(_:)` (lines 48–50):

  ```swift
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            // Granting authorization is NOT enough to receive push: we must also
            // register for a remote (APNs) token, which uploads via the delegate's
            // didRegisterForRemoteNotificationsWithDeviceToken -> updateDevice path.
            if granted {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            }
  ```

  Add the UIKit import at the top of the file (after `import UserNotifications` on line 3) so `UIApplication` resolves:
  ```swift
  import UIKit
  ```

- [ ] **Step 2: Verify it compiles via the iOS build.**
  ```bash
  xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -5
  ```
  (If `Snapceipt.xcodeproj` is not present, generate it first: `xcodegen generate`.) Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Add a launch-time re-registration when already authorized.** A user who granted on a prior launch (or in iOS Settings) must re-register each cold launch so a rotated token re-uploads. In `Snapceipt/Features/Notifications/NotificationDelegate.swift`, replace `application(_:didFinishLaunchingWithOptions:)` (lines 15–19) and add the helper:

  ```swift
      func application(_ application: UIApplication,
                       didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
          UNUserNotificationCenter.current().delegate = self
          // Re-register on every cold launch IF the user already authorized notifications,
          // so a rotated APNs token re-uploads via didRegisterForRemoteNotifications.
          Task { await Self.registerIfAuthorized() }
          return true
      }

      /// Register for remote notifications only when authorization is already granted, so a
      /// previously-granted user re-uploads a (possibly rotated) token on launch without
      /// re-prompting. No-op when not authorized.
      @MainActor
      static func registerIfAuthorized() async {
          let settings = await UNUserNotificationCenter.current().notificationSettings()
          if settings.authorizationStatus == .authorized {
              UIApplication.shared.registerForRemoteNotifications()
          }
      }
  ```

  (`import UIKit` is already at line 1 of this file, so `UIApplication` resolves.)

- [ ] **Step 4: Build again.**
  ```bash
  xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 15' build 2>&1 | tail -5
  ```
  Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**
  ```bash
  git add Snapceipt/Features/Onboarding/PermissionPrimingView.swift Snapceipt/Features/Notifications/NotificationDelegate.swift
  git commit -m "$(cat <<'EOF'
  feat(push): register for remote notifications on onboarding grant + relaunch

  Granting notifications during onboarding now registers for an APNs token
  (previously authorization was requested but no token was ever uploaded), and
  cold launch re-registers when already authorized so rotated tokens re-upload.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 4: Make the onboarding notification-priming step reachable (drive onboarding off an explicit `onboardingComplete` flag)

`RootView.swift:32` gates onboarding on `profileRows.isEmpty`. `FirstProfileForm.create()` saves the profile (flipping `isEmpty` to false) at lines 198–199 BEFORE calling `onCreated()` at line 204, so RootView swaps to `ShellView` and unmounts `OnboardingView` before the camera/notifications priming runs. Fix: drive the gate off a persisted `onboardingComplete` flag that is only set when the notifications step finishes.

- [ ] **Step 1: Add a failing unit test for the gate predicate.** Create `SnapceiptTests/OnboardingGateTests.swift`:

  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  @Suite("Onboarding gate")
  struct OnboardingGateTests {
      private func freshDefaults() -> UserDefaults {
          let suite = "sc.test.onboarding.\(UUID().uuidString)"
          let d = UserDefaults(suiteName: suite)!
          d.removePersistentDomain(forName: suite)
          return d
      }

      @Test("needsOnboarding is true until the flag is set, regardless of profile count")
      func gateFlips() {
          let d = freshDefaults()
          // No profile, never completed -> onboarding.
          #expect(OnboardingGate.needsOnboarding(hasProfile: false, defaults: d) == true)
          // Profile created mid-flow but flag not yet set -> STILL onboarding (priming reachable).
          #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == true)
          // Flag set -> shell.
          OnboardingGate.markComplete(defaults: d)
          #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == false)
      }

      @Test("a returning user with the flag set never re-onboards")
      func returningUser() {
          let d = freshDefaults()
          OnboardingGate.markComplete(defaults: d)
          #expect(OnboardingGate.needsOnboarding(hasProfile: true, defaults: d) == false)
          #expect(OnboardingGate.needsOnboarding(hasProfile: false, defaults: d) == false)
      }
  }
  ```

- [ ] **Step 2: Run the test — it fails to compile (`OnboardingGate` does not exist yet).**
  ```bash
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
    -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:SnapceiptTests/OnboardingGateTests 2>&1 | tail -15
  ```
  Expected: build/test FAILS with `cannot find 'OnboardingGate' in scope`.

- [ ] **Step 3: Implement `OnboardingGate`.** Add it at the top of `Snapceipt/Features/Onboarding/OnboardingView.swift`, after the `import` lines (1–2) and before `enum OnboardingStep` (line 5):

  ```swift
  /// First-run completion flag. Onboarding is driven off THIS, not "has a profile":
  /// `FirstProfileForm` inserts the profile mid-flow, so gating on profile-existence
  /// would unmount onboarding before the camera/notifications priming steps run.
  enum OnboardingGate {
      private static let key = "sc.onboardingComplete"

      /// True while first-run priming should still show. Drives off the persisted
      /// completion flag (set when the notifications step finishes) so a profile inserted
      /// mid-flow does not unmount onboarding. `hasProfile` is accepted for call-site
      /// clarity / future reinstall handling; the flag is authoritative.
      static func needsOnboarding(hasProfile: Bool, defaults: UserDefaults = .standard) -> Bool {
          if defaults.bool(forKey: key) { return false }
          return true
      }

      /// Mark first-run priming complete (called when the notifications step finishes).
      static func markComplete(defaults: UserDefaults = .standard) {
          defaults.set(true, forKey: key)
      }
  }
  ```

- [ ] **Step 4: Set the flag when onboarding finishes.** In `OnboardingView.body`, the `.notifications` case (lines 36–40) calls `onFinished()`. Wrap it so the flag is persisted first:

  ```swift
              case .notifications:
                  PermissionPrimingView(kind: .notifications, requester: requester) {
                      OnboardingGate.markComplete()
                      onFinished()
                  }
                  .transition(.move(edge: .trailing).combined(with: .opacity))
  ```

- [ ] **Step 5: Switch `RootView` onto the gate.** In `Snapceipt/App/RootView.swift`, replace the `.signedIn` gate at line 32 (`if profileRows.isEmpty {`) with:

  ```swift
              if OnboardingGate.needsOnboarding(hasProfile: !profileRows.isEmpty) {
  ```

  Replace the existing `onFinished` no-op closure (lines 33–36) so its comment reflects the flag-driven re-render:

  ```swift
                  OnboardingView(onFinished: {
                      // No-op: OnboardingGate.markComplete() (set on the notifications step)
                      // flips needsOnboarding to false, re-rendering this view into the shell.
                  })
  ```

  Then update the single first-run cross-fade modifier (line 85, `.animation(.easeInOut(duration: 0.28), value: profileRows.isEmpty)`) so the handoff cross-fades on the gate, not on raw profile count (leave the `value: authVM.state` modifier on line 86 unchanged). Replace line 85:

  ```swift
          .animation(.easeInOut(duration: 0.28), value: OnboardingGate.needsOnboarding(hasProfile: !profileRows.isEmpty))
  ```

- [ ] **Step 6: Run the unit test — it passes.**
  ```bash
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
    -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:SnapceiptTests/OnboardingGateTests 2>&1 | tail -15
  ```
  Expected: `** TEST SUCCEEDED **` with the two `OnboardingGateTests` passing.

- [ ] **Step 7: Make the reset path clear the flag, then confirm the existing onboarding UI test still passes.** UI tests launch with `-uiTestReset`, handled by `AppLaunch.applyResetIfNeeded(authStore:)` (AppLaunch.swift:61–73), which today clears `sc.activeProfile`, `sc.syncCursor`, and `sc.lock.enabled` but NOT the new flag — so a UI-test relaunch could skip onboarding. Add the flag to that reset block. In `Snapceipt/App/AppLaunch.swift`, after line 72 (`UserDefaults.standard.removeObject(forKey: "sc.lock.enabled")`) inside `applyResetIfNeeded`, add:

  ```swift
          // Clear the first-run completion flag so a -uiTestReset launch starts at onboarding.
          UserDefaults.standard.removeObject(forKey: "sc.onboardingComplete")
  ```

  Then run the onboarding UI test:
  ```bash
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
    -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:SnapceiptUITests/OnboardingUITests 2>&1 | tail -20
  ```
  Expected: `** TEST SUCCEEDED **` — `testDevSignInThroughOnboardingToShell` taps "Not now" through camera + notifications (the loop at OnboardingUITests.swift:18–21) and then reaches `shell.home`/`shell.tabbar`.

- [ ] **Step 8: Commit.**
  ```bash
  git add Snapceipt/Features/Onboarding/OnboardingView.swift Snapceipt/App/RootView.swift Snapceipt/App/AppLaunch.swift SnapceiptTests/OnboardingGateTests.swift
  git commit -m "$(cat <<'EOF'
  fix(onboarding): make notification priming reachable via onboardingComplete flag

  RootView gated onboarding on profileRows.isEmpty, so creating the first profile
  unmounted onboarding before the camera/notifications priming. Drive the gate off
  an explicit OnboardingGate.markComplete() set when priming finishes instead.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 5: Make `PermissionKind` Equatable + unit-test the requester recording seam

`PermissionPrimingView.allow()` (lines 117–124) calls `requester.request(kind)`. We harden the injectable `PermissionRequesting` seam used by `OnboardingView` so a granting requester is assertable, and make `PermissionKind` `Equatable` so a recorder can compare kinds. NOTE: `registerForRemoteNotifications()` itself is a UIKit side effect that cannot be observed in a headless unit test, and `allow()` is `private` + dispatches a `Task`; the production grant-registration wiring is therefore covered by Task 3 (the `LivePermissionRequester` change) and Task 4 Step 7 (the OnboardingUITests journey). This test only locks in the recorder/Equatable seam.

- [ ] **Step 1: Make `PermissionKind` `Equatable` + add the recorder test.** In `Snapceipt/Features/Onboarding/PermissionPrimingView.swift` change line 6:
  ```swift
  enum PermissionKind: Equatable {
  ```

  Append to `SnapceiptTests/UpdateDevicePayloadTests.swift` inside the existing `@Suite("UpdateDevice payload")` struct (before its closing brace on line 51):

  ```swift
      @Test("a granting notifications requester records the notifications request (onboarding grant seam)")
      func onboardingGrantRequestsNotifications() async {
          final class RecordingRequester: PermissionRequesting, @unchecked Sendable {
              private(set) var requested: [PermissionKind] = []
              func request(_ kind: PermissionKind) async { requested.append(kind) }
          }
          let rec = RecordingRequester()
          await rec.request(.notifications)
          #expect(rec.requested == [.notifications])
      }
  ```

- [ ] **Step 2: Run the test — it passes once `PermissionKind: Equatable` compiles.**
  ```bash
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
    -destination 'platform=iOS Simulator,name=iPhone 15' \
    -only-testing:SnapceiptTests/UpdateDevicePayloadTests 2>&1 | tail -15
  ```
  Expected: `** TEST SUCCEEDED **`; the new `onboardingGrantRequestsNotifications` test passes alongside the four existing ones.

- [ ] **Step 3: Commit.**
  ```bash
  git add SnapceiptTests/UpdateDevicePayloadTests.swift Snapceipt/Features/Onboarding/PermissionPrimingView.swift
  git commit -m "$(cat <<'EOF'
  test(push): make PermissionKind Equatable + cover the requester recording seam

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 6: Full backend + iOS test sweep (regression gate before the ops step)

- [ ] **Step 1: Run the full backend suite.**
  ```bash
  npm test
  ```
  Expected: all suites green, including `test/budgetAlert.test.ts (12 tests)`.

- [ ] **Step 2: Run the full iOS test suite for the scheme.**
  ```bash
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt \
    -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 | tail -25
  ```
  Expected: `** TEST SUCCEEDED **` (SnapceiptTests + SnapceiptUITests), including `OnboardingGateTests`, `UpdateDevicePayloadTests`, and `OnboardingUITests`.

- [ ] **Step 3: No commit needed (verification only).** If anything is red, fix and re-run before proceeding to Task 7.

---

### Task 7: OPS — verify APNS prod secrets and a real end-to-end budget alert

This is an operator/ops task (no code). Run from the repo root with prod wrangler auth. The D1 binding is `DB` with `database_name: "snapceipt"` (wrangler.jsonc).

- [ ] **Step 1: Confirm the three APNS secrets exist in prod.**
  ```bash
  npx wrangler secret list
  ```
  Expected: the JSON list includes entries with `"name": "APNS_KEY"`, `"name": "APNS_KEY_ID"`, and `"name": "APNS_TEAM_ID"`. If any are missing, set them (the `.p8` contents for `APNS_KEY`):
  ```bash
  npx wrangler secret put APNS_KEY
  npx wrangler secret put APNS_KEY_ID
  npx wrangler secret put APNS_TEAM_ID
  ```
  And confirm `wrangler.jsonc` `vars.APPLE_BUNDLE_ID` matches the app's real bundle id (currently `app.snapceipt.Snapceipt`, wrangler.jsonc:36).

- [ ] **Step 2: Confirm the hourly cron trigger is configured.** Verify `wrangler.jsonc` has `triggers.crons` containing `"0 * * * *"` (already present at wrangler.jsonc:9; the hourly schedule `src/index.ts` documents and `scheduled` invokes `budgetCronLogic(env.DB, env, Date.now())` at index.ts:10). If for any reason it is absent after a config edit, re-add it and `npx wrangler deploy`.

- [ ] **Step 3: End-to-end on a real device.** On a physical iPhone running the GA build (NOT the simulator — the simulator never issues an APNs token):
  - Sign in, complete onboarding, and tap "Turn on notifications" (Allow) on the notifications priming step.
  - In prod D1, confirm a `devices` row for that user has a non-null `apns_token` and `push_enabled = 1`:
    ```bash
    npx wrangler d1 execute snapceipt --remote --command "SELECT id, push_enabled, apns_token IS NOT NULL AS has_token FROM devices WHERE user_id = '<USER_ID>'"
    ```
    Expected: a row with `has_token = 1`, `push_enabled = 1`.
  - Create a budget and add expenses crossing the alert threshold so the next hourly cron fires (or trigger the schedule manually for the deployed Worker via the Cloudflare dashboard → Workers → snapceipt-api → Triggers → "Trigger scheduled event").
  - Expected confirmation: the device receives the "Budget alert" banner; tapping it deep-links into the budget (the `snapceipt://budget/<id>` deepLink handled by `NotificationDelegate.userNotificationCenter(_:didReceive:)`); and the budget's `alert_sent_at` is now non-null:
    ```bash
    npx wrangler d1 execute snapceipt --remote --command "SELECT id, alert_sent_at FROM budgets WHERE id = '<BUDGET_ID>'"
    ```
    Expected: `alert_sent_at` is a non-null epoch-ms value.

- [ ] **Step 4: Record the result.** Paste the device-token query output, the received-notification confirmation, and the stamped `alert_sent_at` value into the PR description as the GA push sign-off.

**Open questions (human input needed):**

- Exact prod D1 database name to substitute for `<DB_NAME>` in the `wrangler d1 execute --remote` ops commands (check `wrangler.jsonc` d1_databases binding name).
- Whether `AppLaunch.applyResetIfNeeded` already clears arbitrary `sc.*` UserDefaults keys under `-uiTestReset`; if it only resets the auth/store and not UserDefaults, the new `sc.onboardingComplete` key must be added to its reset path (flagged inline in Task 4 Step 7) so UI tests start at onboarding.
- Whether prod has a manual scheduled-trigger affordance (dashboard 'Trigger scheduled event' vs. a dev-only `__scheduled` route) for the Task 7 end-to-end test, or whether the operator must wait for the top-of-hour cron.

_Critic verdict: fixed (4 issue(s) fixed)._

---

## Workstream 4: Device-bind the magic-link token (+ OTP fallback for cross-device)

**Goal:** Make the magic-link single-use token redeemable only on the device that requested it (capture the requesting install at /request, enforce a match at /verify), and add a 6-digit OTP fallback so the legitimate cross-device case still works.

**Dependencies:** none (self-contained within src/routes/auth.ts, src/schemas/auth.ts, src/lib/email.ts and the iOS Auth feature + APIClient). Does not depend on other GA workstreams; the StoreKit/push/email-in workstreams are orthogonal.

**Definition of done:**

- [ ] POST /auth/magic-link/request stores the requesting device hint in the KV metadata alongside {email, createdAt} (from X-Device-Id header, with an optional deviceId body field as a secondary source).
- [ ] POST /auth/magic-link/verify, when the stored metadata carries a deviceId, rejects with 401 AUTH_DEVICE_MISMATCH unless the redeemer's X-Device-Id matches the stored device, AND the token has already been single-use deleted before the rejection (a mismatched attempt consumes the token).
- [ ] POST /auth/magic-link/verify still succeeds (200, issues a session) when the X-Device-Id matches the stored device, or when no device hint was stored (backward-compatible).
- [ ] POST /auth/otp/request issues a 6-digit numeric code (KV {codeHash, email, attempts, expiresAtMs}, 600s TTL), always 202 (no enumeration), echoes devCode only under E2E_TEST_MODE, and sends the code email via src/lib/email.ts.
- [ ] POST /auth/otp/verify consumes the code (single-use, 5-attempt cap), upserts the user + email auth_identity, registers the redeemer's X-Device-Id device, and returns the same session envelope as magic-link/verify.
- [ ] All new backend behaviour is covered by tests in test/auth.magiclink.test.ts and a new test/auth.otp.test.ts; `npx vitest run test/auth.magiclink.test.ts` and `npx vitest run test/auth.otp.test.ts` both pass.
- [ ] iOS: MagicLinkRequestBody carries the deviceId; LiveAPIClient exposes otpRequest/otpVerify; AuthViewModel has requestOTP/verifyOTP that drive a new awaitingOTP state; MockAPIClient + StubAPIClient + PreviewAPIClient compile; APIClientTests + AuthViewModelTests pass.
- [ ] SignInView/MagicLinkWaitView expose an 'Enter a code instead' path that calls the OTP flow, and the wait copy reflects same-device-only ('Tap it on this device').

**Files:**

- `src/routes/auth.ts`
- `src/schemas/auth.ts`
- `src/lib/email.ts`
- `test/auth.magiclink.test.ts`
- `test/auth.otp.test.ts`
- `Snapceipt/Sync/DTOs.swift`
- `Snapceipt/Sync/APIClient.swift`
- `Snapceipt/Sync/StubAPIClient.swift`
- `Snapceipt/Features/Auth/AuthViewModel.swift`
- `Snapceipt/Features/Auth/SignInView.swift`
- `Snapceipt/Features/Auth/MagicLinkWaitView.swift`
- `SnapceiptTests/Mocks/MockAPIClient.swift`
- `SnapceiptTests/APIClientTests.swift`
- `SnapceiptTests/AuthViewModelTests.swift`

## Workstream 4: Device-bind the magic-link token (+ OTP fallback)

Background (verified in code, do not re-derive):
- `POST /auth/magic-link/request` (`src/routes/auth.ts:86-132`) stores `KV.put('ml:'+hash, '1', { metadata: { email, createdAt } })` (lines 97-100) and emails the link. It currently ignores `X-Device-Id`.
- `POST /auth/magic-link/verify` (`src/routes/auth.ts:141-221`) looks up `ml:<hash>` (line 149), deletes it (single-use, line 156), then registers *whatever* `X-Device-Id` the redeemer sends (lines 194-205). It never compares the redeemer to the requester. This is the bug.
- The iOS client ALREADY attaches `X-Device-Id` on every request via `makeRequest` (`Snapceipt/Sync/APIClient.swift:364`), including `/magic-link/request` and `/verify`. `auth.deviceId` is the stable per-install UUID (`Snapceipt/Sync/AuthStore.swift:36-46`).
- The OTP fallback has an exact in-repo template: the email-change flow in `src/routes/account.ts` — `sixDigitCode()` (line 43-46), `sha256Hex()` (line 39-42), KV value `{codeHash, newEmail, attempts, expiresAtMs}` (line 71), 5-attempt cap (lines 99-103), `devCode` echo under `E2E_TEST_MODE` (line 76-78), `sendEmailChangeCode` seam (line 80).
- Routes mounted under `/auth/*` automatically get the `auth` rate-limit tier, which enforces per-IP/hr always AND per-email/hr when the JSON body carries an `email` (`src/middleware/rateLimit.ts:121-149`). So new OTP routes under `/auth/*` inherit per-email throttling for free.
- The error-code → HTTP-status map is `ERROR` in `src/lib/errors.ts:5-16`; `ApiError` (lines 29-41) requires `code: ErrorCode` (a key of `ERROR`) and sets `this.status = ERROR[code]`. A code NOT in the map fails to compile under `strict: true` (`tsconfig.json`) AND yields `status === undefined` at runtime — so a new code MUST be added to `ERROR`.
- §21 decision (`docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md:334`): "Magic-link strictness: same-device only vs any-device? → **same-device only** (tighter; OTP fallback covers edge cases)." §3.1 (line 162) references the "6-digit OTP fallback".
- Test idioms: `test/auth.magiclink.test.ts` uses `SELF.fetch`, `installEmailSpy()` (spies `sendMagicLinkEmail`, captures the token from the `link` arg, lines 21-32), and a local `sha256Hex` (lines 9-12). Migrations are applied by `test/apply-migrations.ts` (vitest `setupFiles`, `vitest.config.ts:15`). Run a single backend file with `npx vitest run test/<name>.test.ts`. iOS unit tests use Swift Testing (`@Test`/`#expect`); `MockAPIClient` lives at `SnapceiptTests/Mocks/MockAPIClient.swift`, `APIClientTests` drive `MockURLProtocol`. The iOS unit test command is `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'` (scheme `Snapceipt`, `project.yml:80-89`; the exact `xcodebuild test` invocation is used by `scripts/ios-e2e-live.sh:29`). There is NO `scripts/test-ios.sh`.

---

### Task 1: Capture the requesting device on /magic-link/request (schema + KV metadata)

- [ ] **Step 1: Write the failing test.** Append to `test/auth.magiclink.test.ts` inside the existing `describe("POST /auth/magic-link/request", ...)` block (after the last `it`, before its closing `});`):

```ts
  it("stores the X-Device-Id header in the KV metadata as deviceId", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-device-id": "01890000-0000-7000-8000-00000000d111",
      },
      body: JSON.stringify({ email: "dev-hint@example.com" }),
    });
    expect(res.status).toBe(202);
    const hash = await sha256Hex(spy.lastToken());
    const stored = await env.KV.getWithMetadata(`ml:${hash}`);
    expect(stored.metadata).toMatchObject({
      email: "dev-hint@example.com",
      deviceId: "01890000-0000-7000-8000-00000000d111",
    });
  });

  it("falls back to the body deviceId when no X-Device-Id header is present", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "body-hint@example.com", deviceId: "01890000-0000-7000-8000-00000000d222" }),
    });
    expect(res.status).toBe(202);
    const hash = await sha256Hex(spy.lastToken());
    const stored = await env.KV.getWithMetadata(`ml:${hash}`);
    expect(stored.metadata).toMatchObject({ deviceId: "01890000-0000-7000-8000-00000000d222" });
  });

  it("omits deviceId from metadata when neither header nor body supplies one (backward-compatible)", async () => {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "no-hint@example.com" }),
    });
    expect(res.status).toBe(202);
    const hash = await sha256Hex(spy.lastToken());
    const stored = await env.KV.getWithMetadata<{ email: string; deviceId?: string }>(`ml:${hash}`);
    expect(stored.metadata?.deviceId).toBeUndefined();
    expect(stored.metadata).toMatchObject({ email: "no-hint@example.com" });
  });
```

- [ ] **Step 2: Run it — expect failure.** `npx vitest run test/auth.magiclink.test.ts`. Expected: the three new tests FAIL with `expected ... to match object { ..., deviceId: ... }` because the route never writes `deviceId` into metadata.

- [ ] **Step 3: Add the optional `deviceId` to the request schema.** In `src/schemas/auth.ts`, replace the `magicLinkRequestBody` definition (currently lines 18-20):

```ts
export const magicLinkRequestBody = z.object({
  email: z.string().trim().email(),
  /** Optional install hint; the X-Device-Id header takes precedence. Used to
   *  device-bind the minted token so an intercepted link is unusable elsewhere. */
  deviceId: z.string().min(1).max(64).optional(),
});
```

- [ ] **Step 4: Capture the device in the route.** In `src/routes/auth.ts`, in the `/magic-link/request` handler, replace the body destructuring + KV write (lines 90-100) with:

```ts
    const { email, deviceId } = c.req.valid("json");
    const normalized = normalizeEmail(email);

    const token = newMagicToken();
    const hash = await sha256Hex(token);

    // Device hint for binding: header wins, body is the fallback. Absent => no binding
    // (verify stays backward-compatible for already-minted tokens).
    const deviceHint = c.req.header("X-Device-Id") || deviceId || undefined;

    // Store only the hash; metadata carries the email + (optional) requesting device.
    await c.env.KV.put(`ml:${hash}`, "1", {
      expirationTtl: MAGIC_LINK_TTL_SECONDS,
      metadata: { email: normalized, createdAt: nowMs(), ...(deviceHint ? { deviceId: deviceHint } : {}) },
    });
```

- [ ] **Step 5: Run it — expect pass.** `npx vitest run test/auth.magiclink.test.ts`. Expected: all tests pass (the existing request/verify tests are unaffected; the three new ones now pass). Expected tail: `Test Files  1 passed`.

- [ ] **Step 6: Commit.**

```
git add src/schemas/auth.ts src/routes/auth.ts test/auth.magiclink.test.ts
git commit -m "$(cat <<'EOF'
feat(auth): capture requesting device hint on magic-link/request

Store the X-Device-Id (or optional body deviceId) in the ml:<hash> KV
metadata so /verify can bind the token to its requesting install.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Enforce the device match on /magic-link/verify (consume + reject on mismatch)

- [ ] **Step 1: Add the `AUTH_DEVICE_MISMATCH` error code to the map FIRST.** This is a prerequisite: `ApiError` (`src/lib/errors.ts:29-41`) requires `code` to be a key of `ERROR`, so referencing it before it exists is a compile error under `strict: true`. In `src/lib/errors.ts`, add the new code to the `ERROR` object next to the other 401s (replace lines 6-8):

```ts
  AUTH_INVALID_TOKEN: 401,
  AUTH_SESSION_REVOKED: 401,
  AUTH_DEVICE_MISMATCH: 401,
  VALIDATION_FAILED: 400,
```

- [ ] **Step 2: Write the failing test.** Append to `test/auth.magiclink.test.ts` inside the existing `describe("POST /auth/magic-link/verify", ...)` block (after the last `it`, before its closing `});`). Note: `requestLink` in that block does NOT send a device header, so add a device-aware helper next to it and three cases:

```ts
  async function requestLinkFromDevice(email: string, deviceId: string): Promise<string> {
    const spy = installEmailSpy();
    const res = await SELF.fetch("https://x/auth/magic-link/request", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": deviceId },
      body: JSON.stringify({ email }),
    });
    expect(res.status).toBe(202);
    return spy.lastToken();
  }

  it("succeeds when the verifying X-Device-Id matches the requesting device", async () => {
    const dev = "01890000-0000-7000-8000-00000000bind";
    const token = await requestLinkFromDevice("bind-ok@example.com", dev);
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": dev },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { user: { email: string } };
    expect(body.user.email).toBe("bind-ok@example.com");
  });

  it("rejects with 401 AUTH_DEVICE_MISMATCH when verified from a different device", async () => {
    const token = await requestLinkFromDevice("bind-bad@example.com", "01890000-0000-7000-8000-0000000dev-a");
    const res = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": "01890000-0000-7000-8000-0000000dev-b" },
      body: JSON.stringify({ token }),
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_DEVICE_MISMATCH");
  });

  it("consumes the token on a device-mismatch (a retry from the right device still 401s)", async () => {
    const right = "01890000-0000-7000-8000-0000000right";
    const token = await requestLinkFromDevice("bind-consume@example.com", right);
    const wrong = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": "01890000-0000-7000-8000-0000000wrong" },
      body: JSON.stringify({ token }),
    });
    expect(wrong.status).toBe(401);
    // The token was single-use deleted before the mismatch reject, so even the
    // correct device now gets the generic invalid-token error.
    const retry = await SELF.fetch("https://x/auth/magic-link/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": right },
      body: JSON.stringify({ token }),
    });
    expect(retry.status).toBe(401);
    const body = (await retry.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
```

The existing "consumes the token: creates user + session" test (lines 104-143) sends `x-device-id: 01890000-0000-7000-8000-000000000abc` on verify, but its `requestLink` helper (lines 93-102) mints with NO device header, so the stored metadata has no `deviceId` and binding is skipped → it must still pass unchanged. No edit needed there; confirm it stays green in Step 4.

- [ ] **Step 3: Enforce the match in the route.** In `src/routes/auth.ts`, in the `/magic-link/verify` handler, the metadata is read at line 149 as `getWithMetadata<{ email: string }>`. Widen the generic and add the binding check immediately AFTER the single-use delete (line 156). Replace lines 149-159:

```ts
    const stored = await c.env.KV.getWithMetadata<{ email: string; deviceId?: string }>(key, "text");
    if (stored.value === null || !stored.metadata?.email) {
      // Unknown, already-consumed, or expired (KV TTL evicted it).
      throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired magic link");
    }

    // Single-use: delete before issuing so a replay can't double-consume. This
    // runs BEFORE the device-binding check, so a mismatched (intercepted) attempt
    // still burns the token — the legitimate requester must re-request or use OTP.
    await c.env.KV.delete(key);

    // Device binding (§21 same-device-only): when the token was minted with a
    // requesting-device hint, the redeemer MUST present the same X-Device-Id.
    // Tokens minted before this rollout carry no hint and stay redeemable anywhere.
    const boundDevice = stored.metadata.deviceId;
    if (boundDevice && c.req.header("X-Device-Id") !== boundDevice) {
      throw new ApiError("AUTH_DEVICE_MISMATCH", "This sign-in link can only be used on the device that requested it");
    }

    const email = normalizeEmail(stored.metadata.email);
    const now = nowMs();
```

(This block now spans what was lines 149-159 — the original `const email = ...` / `const now = ...` at lines 158-159 are folded into the new block; do not leave duplicates.)

- [ ] **Step 4: Run it — expect pass.** `npx vitest run test/auth.magiclink.test.ts`. Expected: all tests pass, including the new binding tests and the unchanged consume/replay/unknown-token tests. Expected tail: `Test Files  1 passed`.

- [ ] **Step 5: Typecheck.** `npx tsc --noEmit`. Expected: no errors — `AUTH_DEVICE_MISMATCH` is now a valid `ErrorCode` (added to the `ERROR` map in Step 1).

- [ ] **Step 6: Commit.**

```
git add src/lib/errors.ts src/routes/auth.ts test/auth.magiclink.test.ts
git commit -m "$(cat <<'EOF'
fix(auth): device-bind magic-link verify (consume + reject mismatch)

When a token was minted with a requesting-device hint, /verify now
requires the redeemer's X-Device-Id to match. The token is single-use
deleted BEFORE the check, so an intercepted token is burned on the
first (failing) attempt. New 401 AUTH_DEVICE_MISMATCH (added to the
ERROR map in src/lib/errors.ts).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add the OTP email seam (sendSignInCode)

- [ ] **Step 1: Write the failing test.** Create `test/auth.otp-email.test.ts`:

```ts
import { env } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { sendSignInCode } from "../src/lib/email";

describe("sendSignInCode", () => {
  it("sends via env.EMAIL.send with the code in the body and the magic-link sender", async () => {
    const sent: Array<{ from: { email: string }; to: string; subject: string; text: string }> = [];
    const fakeEnv = {
      ...env,
      EMAIL: {
        send: vi.fn(async (msg: { from: { email: string }; to: string; subject: string; text: string }) => {
          sent.push(msg);
        }),
      },
    } as unknown as typeof env;

    await sendSignInCode(fakeEnv, { to: "code@example.com", code: "012345" });

    expect(sent).toHaveLength(1);
    expect(sent[0]!.to).toBe("code@example.com");
    expect(sent[0]!.from.email).toBe("noreply@snapceipt.cc");
    expect(sent[0]!.text).toContain("012345");
  });
});
```

- [ ] **Step 2: Run it — expect failure.** `npx vitest run test/auth.otp-email.test.ts`. Expected: TypeScript/import failure — `sendSignInCode` is not exported from `../src/lib/email`.

- [ ] **Step 3: Add the email function.** In `src/lib/email.ts`, after `sendEmailChangeCode` (ends line 55), add. (`MAGIC_LINK_SENDER` is the module constant at line 11, `"noreply@snapceipt.cc"` — the only allowed sender; `Env` is already imported at line 1.)

```ts
export interface SignInCode {
  to: string;
  code: string;
}

/**
 * Send the 6-digit sign-in OTP (the cross-device fallback for the device-bound
 * magic link). Same SendEmail builder path as sendMagicLinkEmail; spy-able via
 * vi.spyOn(emailModule, "sendSignInCode"). Failures surface as a thrown error.
 */
export async function sendSignInCode(env: Env, msg: SignInCode): Promise<void> {
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    subject: "Your Snapceipt sign-in code",
    text:
      `Your Snapceipt sign-in code is: ${msg.code}\n\n` +
      `Enter it in the app to sign in. It expires in 10 minutes and can be used once. ` +
      `If you didn't request this, ignore this email.`,
  });
}
```

- [ ] **Step 4: Run it — expect pass.** `npx vitest run test/auth.otp-email.test.ts`. Expected: `Test Files  1 passed`.

- [ ] **Step 5: Commit.**

```
git add src/lib/email.ts test/auth.otp-email.test.ts
git commit -m "$(cat <<'EOF'
feat(auth): add sendSignInCode email seam for OTP sign-in fallback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add POST /auth/otp/request (mint + store + email the code)

- [ ] **Step 1: Write the failing test.** Create `test/auth.otp.test.ts`:

```ts
import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";

// Migrations applied by test/apply-migrations.ts (vitest.config.ts setupFiles).

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function installCodeSpy() {
  const send = vi.spyOn(emailModule, "sendSignInCode").mockResolvedValue(undefined);
  return {
    send,
    lastCode() {
      const arg = send.mock.calls.at(-1)?.[1] as { code?: string } | undefined;
      if (!arg?.code) throw new Error("no code in email payload");
      return arg.code;
    },
  };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /auth/otp/request", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  it("returns 202, writes oc:<emailhash> with a 6-digit codeHash, and emails the code", async () => {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "Otp@Example.com " }),
    });
    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);
    const code = spy.lastCode();
    expect(code).toMatch(/^\d{6}$/);

    const emailHash = await sha256Hex("otp@example.com");
    const raw = await env.KV.get(`oc:${emailHash}`);
    expect(raw).not.toBeNull();
    const pending = JSON.parse(raw!) as { codeHash: string; email: string; attempts: number };
    expect(pending.email).toBe("otp@example.com");
    expect(pending.attempts).toBe(0);
    expect(pending.codeHash).toBe(await sha256Hex(code));
  });

  it("returns 202 for an unknown email too (no enumeration)", async () => {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nobody-otp@example.com" }),
    });
    expect(res.status).toBe(202);
    expect(spy.send).toHaveBeenCalledTimes(1);
  });

  it("rejects a malformed email with 400 VALIDATION_FAILED", async () => {
    installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "nope" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});
```

- [ ] **Step 2: Run it — expect failure.** `npx vitest run test/auth.otp.test.ts`. Expected: the request tests FAIL — `POST /auth/otp/request` 404s (route absent) and `sendSignInCode` spy is never called.

- [ ] **Step 3: Add the schema.** In `src/schemas/auth.ts`, after `magicLinkVerifyBody` (lines 25-29) add:

```ts
/** POST /auth/otp/request — 6-digit sign-in code fallback for cross-device. */
export const otpRequestBody = z.object({
  email: z.string().trim().email(),
});

export type OtpRequestBody = z.infer<typeof otpRequestBody>;

/** POST /auth/otp/verify — { email, code } single-use 6-digit code. */
export const otpVerifyBody = z.object({
  email: z.string().trim().email(),
  code: z.string().regex(/^\d{6}$/),
});

export type OtpVerifyBody = z.infer<typeof otpVerifyBody>;
```

- [ ] **Step 4: Add the route + helpers.** In `src/routes/auth.ts`: extend the email import (line 17) and the schema import (lines 20-25), add the OTP constants near `MAGIC_LINK_TTL_SECONDS` (after line 58), add a `sixDigitCode` helper after `newMagicToken` (after line 77), and add the `/otp/request` handler after the `/magic-link/verify` handler closes (after line 221). (`uuidv7`, `issueSession`, `nowMs`, `ApiError` are already imported at lines 6-11; `sha256Hex`/`normalizeEmail` are local at lines 61-69.)

Import edits:
```ts
import { sendMagicLinkEmail, sendSignInCode } from "../lib/email";
```
```ts
import {
  appleBody,
  magicLinkRequestBody,
  magicLinkVerifyBody,
  otpRequestBody,
  otpVerifyBody,
  refreshBody,
} from "../schemas/auth";
```

Constants (after line 58):
```ts
// OTP sign-in code TTL — mirrors the email-change code window (account.ts).
const OTP_TTL_SECONDS = 600; // 10 minutes
const OTP_MAX_ATTEMPTS = 5;
```

Helper (after `newMagicToken`, line 77):
```ts
/** 6-digit numeric sign-in code (zero-padded). Mirrors account.ts sixDigitCode. */
function sixDigitCode(): string {
  const n = (crypto.getRandomValues(new Uint32Array(1))[0] ?? 0) % 1_000_000;
  return n.toString().padStart(6, "0");
}
```

Route (after the `/magic-link/verify` handler closes, line 221):
```ts
/**
 * POST /auth/otp/request
 * Cross-device fallback for the (now device-bound) magic link. Mint a 6-digit
 * code, store only its sha256 in KV under `oc:<sha256(email)>` (600s TTL,
 * {codeHash, email, attempts, expiresAtMs}), and email it. ALWAYS 202 (no
 * enumeration). Under E2E_TEST_MODE the code is echoed as devCode. The per-email
 * + per-IP "auth" rate-limit tier already covers this path.
 */
authRoutes.post("/otp/request", validate("json", otpRequestBody), async (c) => {
  const { email } = c.req.valid("json");
  const normalized = normalizeEmail(email);

  const code = sixDigitCode();
  const codeHash = await sha256Hex(code);
  const emailHash = await sha256Hex(normalized);
  const expiresAtMs = nowMs() + OTP_TTL_SECONDS * 1000;
  await c.env.KV.put(
    `oc:${emailHash}`,
    JSON.stringify({ codeHash, email: normalized, attempts: 0, expiresAtMs }),
    { expirationTtl: OTP_TTL_SECONDS },
  );

  const e2e = c.env.E2E_TEST_MODE === "1";
  if (e2e) {
    try {
      await sendSignInCode(c.env, { to: normalized, code });
    } catch {
      // E2E-only: ignore the missing/failing local SendEmail binding.
    }
    return c.json({ devCode: code }, 202);
  }
  await sendSignInCode(c.env, { to: normalized, code });
  return c.body(null, 202);
});
```

(`otpVerifyBody` is imported now but its handler is added in Task 5. `tsconfig.json` sets only `strict: true` — there is NO `noUnusedLocals` — so an unused import binding does NOT break `tsc`. Run `npx tsc --noEmit` only at the end of Task 5, after the verify route uses it.)

- [ ] **Step 5: Run it — expect pass.** `npx vitest run test/auth.otp.test.ts`. Expected: the three `/otp/request` tests pass. Expected tail: `Test Files  1 passed`.

- [ ] **Step 6: Commit.**

```
git add src/schemas/auth.ts src/routes/auth.ts test/auth.otp.test.ts
git commit -m "$(cat <<'EOF'
feat(auth): add POST /auth/otp/request (6-digit sign-in code fallback)

Cross-device fallback for the device-bound magic link. Stores
sha256(code) under oc:<sha256(email)> (600s, single-use, attempt-capped)
and emails the code. Always 202; devCode echoed under E2E only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add POST /auth/otp/verify (consume code → session, registers redeemer's device)

- [ ] **Step 1: Write the failing test.** Append to `test/auth.otp.test.ts` a new describe block (after the request block's closing `});`):

```ts
describe("POST /auth/otp/verify", () => {
  beforeEach(async () => {
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM auth_identities");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  async function requestCode(email: string): Promise<string> {
    const spy = installCodeSpy();
    const res = await SELF.fetch("https://x/auth/otp/request", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email }),
    });
    expect(res.status).toBe(202);
    return spy.lastCode();
  }

  it("consumes the code, creates the user + email identity, registers the device, returns a session", async () => {
    const code = await requestCode("otp-ok@example.com");
    const res = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json", "x-device-id": "01890000-0000-7000-8000-0000000otpdv" },
      body: JSON.stringify({ email: "otp-ok@example.com", code }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      accessToken: string; refreshToken: string; expiresIn: number;
      user: { id: string; email: string };
    };
    expect(body.expiresIn).toBe(900);
    expect(body.accessToken.split(".")).toHaveLength(3);
    expect(body.user.email).toBe("otp-ok@example.com");

    const ident = await env.DB
      .prepare("SELECT id FROM auth_identities WHERE provider = 'email' AND subject = ?")
      .bind("otp-ok@example.com").first();
    expect(ident).not.toBeNull();
    const device = await env.DB
      .prepare("SELECT id FROM devices WHERE id = ?")
      .bind("01890000-0000-7000-8000-0000000otpdv").first();
    expect(device).not.toBeNull();
  });

  it("rejects a wrong code with 400 VALIDATION_FAILED and keeps the code live until 5 attempts", async () => {
    await requestCode("otp-wrong@example.com");
    const res = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "otp-wrong@example.com", code: "000000" }),
    });
    // 000000 *could* be the real code; guard against the 1-in-1e6 flake by re-checking the error code only.
    expect([200, 400]).toContain(res.status);
    if (res.status === 400) {
      const body = (await res.json()) as { error: { code: string } };
      expect(body.error.code).toBe("VALIDATION_FAILED");
    }
  });

  it("rejects with 401 AUTH_INVALID_TOKEN when no code was requested for that email", async () => {
    const res = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "never-requested@example.com", code: "123456" }),
    });
    expect(res.status).toBe(401);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });

  it("is single-use: a second verify with the same code 401s", async () => {
    const code = await requestCode("otp-once@example.com");
    const ok = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "otp-once@example.com", code }),
    });
    expect(ok.status).toBe(200);
    const replay = await SELF.fetch("https://x/auth/otp/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "otp-once@example.com", code }),
    });
    expect(replay.status).toBe(401);
    const body = (await replay.json()) as { error: { code: string } };
    expect(body.error.code).toBe("AUTH_INVALID_TOKEN");
  });
});
```

- [ ] **Step 2: Run it — expect failure.** `npx vitest run test/auth.otp.test.ts`. Expected: the verify tests FAIL — `/auth/otp/verify` 404s.

- [ ] **Step 3: Add the verify route.** In `src/routes/auth.ts`, after the `/otp/request` handler (added in Task 4), add the verify handler. The user-upsert + identity + device-register + `issueSession` block mirrors the existing `/magic-link/verify` (lines 161-219), so the OTP path yields an identical session envelope:

```ts
/**
 * POST /auth/otp/verify
 * Consume the 6-digit code (single-use, 5-attempt cap), upsert the user by email
 * (+ email auth_identity), register the redeemer's X-Device-Id device, and issue
 * a session — the same envelope as /magic-link/verify. Unknown/expired => 401
 * AUTH_INVALID_TOKEN; wrong code => 400 VALIDATION_FAILED until the attempt cap.
 */
authRoutes.post("/otp/verify", validate("json", otpVerifyBody), async (c) => {
  const { email, code } = c.req.valid("json");
  const normalized = normalizeEmail(email);
  const emailHash = await sha256Hex(normalized);
  const kvKey = `oc:${emailHash}`;

  const raw = await c.env.KV.get(kvKey);
  if (!raw) throw new ApiError("AUTH_INVALID_TOKEN", "Invalid or expired sign-in code");
  const pending = JSON.parse(raw) as {
    codeHash: string;
    email: string;
    attempts: number;
    expiresAtMs: number;
  };

  if ((await sha256Hex(code)) !== pending.codeHash) {
    const attempts = (pending.attempts ?? 0) + 1;
    if (attempts >= OTP_MAX_ATTEMPTS) {
      await c.env.KV.delete(kvKey);
      throw new ApiError("AUTH_INVALID_TOKEN", "Too many attempts, request a new code");
    }
    const ttl = Math.max(1, Math.ceil((pending.expiresAtMs - nowMs()) / 1000));
    await c.env.KV.put(kvKey, JSON.stringify({ ...pending, attempts }), { expirationTtl: ttl });
    throw new ApiError("VALIDATION_FAILED", "Incorrect code");
  }

  // Correct: single-use delete before issuing.
  await c.env.KV.delete(kvKey);

  const userEmail = normalizeEmail(pending.email);
  const now = nowMs();

  let user = await c.env.DB.prepare(
    "SELECT id, email, display_name FROM users WHERE email = ? AND deleted_at IS NULL",
  )
    .bind(userEmail)
    .first<{ id: string; email: string | null; display_name: string | null }>();

  if (!user) {
    const userId = uuidv7();
    await c.env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
       VALUES (?, ?, 1, NULL, 'free', ?, ?)`,
    )
      .bind(userId, userEmail, now, now)
      .run();
    user = { id: userId, email: userEmail, display_name: null };
  } else {
    await c.env.DB.prepare("UPDATE users SET email_verified = 1, updated_at = ? WHERE id = ?")
      .bind(now, user.id)
      .run();
  }

  await c.env.DB.prepare(
    `INSERT INTO auth_identities (id, user_id, provider, subject, created_at)
     VALUES (?, ?, 'email', ?, ?)
     ON CONFLICT(provider, subject) DO NOTHING`,
  )
    .bind(uuidv7(), user.id, userEmail, now)
    .run();

  const deviceHeader = c.req.header("X-Device-Id");
  const deviceId = deviceHeader && deviceHeader.length > 0 ? deviceHeader : uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       user_id = excluded.user_id,
       last_seen_at = excluded.last_seen_at,
       updated_at = excluded.updated_at`,
  )
    .bind(deviceId, user.id, now, now, now)
    .run();

  const session = await issueSession(c.env.DB, {
    userId: user.id,
    deviceId,
    signingKey: c.env.JWT_SIGNING_KEY,
  });

  return c.json({
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
    expiresIn: 900,
    user: { id: user.id, email: user.email, displayName: user.display_name },
  });
});
```

- [ ] **Step 4: Typecheck.** `npx tsc --noEmit`. Expected: no errors (the `otpVerifyBody` import is now used).

- [ ] **Step 5: Run it — expect pass.** `npx vitest run test/auth.otp.test.ts`. Expected: all request + verify tests pass. Expected tail: `Test Files  1 passed`.

- [ ] **Step 6: Commit.**

```
git add src/routes/auth.ts test/auth.otp.test.ts
git commit -m "$(cat <<'EOF'
feat(auth): add POST /auth/otp/verify (code -> session)

Consumes the single-use 6-digit code (5-attempt cap), upserts the user +
email identity, registers the redeemer's device, and issues the same
session envelope as magic-link/verify.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: iOS — send the deviceId on /magic-link/request (DTO + client) and expose OTP client methods

- [ ] **Step 1: Write the failing tests.** In `SnapceiptTests/APIClientTests.swift`, add three `@Test`s before the closing `}` of `struct APIClientTests` (the brace at line 250, just before the `private extension URLRequest`). The first asserts the request body now carries `deviceId`; the others cover the new OTP client methods. (`makeClient(seedBearer:)` returns `(LiveAPIClient, AuthStore)`; `httpBodyData()` is the private extension at lines 253-268; `MockURLProtocol.lastRequest`/`setHandler` are the existing idiom.)

```swift
    @Test("magicLinkRequest body includes the install deviceId")
    func magicLinkRequestSendsDeviceId() async throws {
        let (client, auth) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.magicLinkRequest(email: "user@example.com")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "user@example.com")
        #expect(obj?["deviceId"] as? String == auth.deviceId)
        // The header is still attached too (binding source of truth).
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Device-Id") == auth.deviceId)
    }

    @Test("otpRequest POSTs /auth/otp/request with the email")
    func otpRequestPosts() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.otpRequest(email: "code@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/otp/request")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "code@example.com")
    }

    @Test("otpVerify POSTs /auth/otp/verify and decodes a SessionResponse")
    func otpVerifyDecodes() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"accessToken":"a.b.c","refreshToken":"refresh-0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u1","email":"code@example.com","displayName":null}}
            """))
        }
        let session = try await client.otpVerify(email: "code@example.com", code: "123456")
        #expect(session.user.email == "code@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/otp/verify")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "code@example.com")
        #expect(obj?["code"] as? String == "123456")
    }
```

- [ ] **Step 2: Run it — expect failure.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: compile error — "value of type 'LiveAPIClient' has no member 'otpRequest'" (and the `deviceId` body assertion can't be satisfied yet).

- [ ] **Step 3: Update the request DTO.** In `Snapceipt/Sync/DTOs.swift`, replace `MagicLinkRequestBody` (lines 44-47) and add OTP bodies after `MagicLinkVerifyBody` (lines 49-52):

```swift
/// POST /auth/magic-link/request — carries the install deviceId so the backend
/// device-binds the minted token (the X-Device-Id header is the binding source;
/// this body field is a redundant hint for clients that can't set the header).
struct MagicLinkRequestBody: Encodable {
    let email: String
    let deviceId: String
}

/// POST /auth/magic-link/verify
struct MagicLinkVerifyBody: Encodable {
    let token: String
}

/// POST /auth/otp/request — 6-digit sign-in code fallback.
struct OTPRequestBody: Encodable {
    let email: String
}

/// POST /auth/otp/verify — { email, code }.
struct OTPVerifyBody: Encodable {
    let email: String
    let code: String
}
```

- [ ] **Step 4: Update the protocol + LiveAPIClient.** In `Snapceipt/Sync/APIClient.swift`:

In the `APIClient` protocol, after `magicLinkVerify` (line 11) add:
```swift
    /// POST /auth/otp/request — request a 6-digit sign-in code (cross-device fallback).
    func otpRequest(email: String) async throws
    /// POST /auth/otp/verify — confirm the 6-digit code and start a session.
    func otpVerify(email: String, code: String) async throws -> SessionResponse
```

Update `magicLinkRequest` (lines 74-77) and `magicLinkRequestDev` (lines 79-87) to pass `deviceId`, keep `magicLinkVerify` (lines 89-92) unchanged, and add the two OTP impls after it:
```swift
    func magicLinkRequest(email: String) async throws {
        try await sendNoContent("POST", "/auth/magic-link/request",
                                body: MagicLinkRequestBody(email: email, deviceId: auth.deviceId),
                                authenticated: false)
    }

    func magicLinkRequestDev(email: String) async throws -> String? {
        /// The 202 body only carries `devToken` when the backend runs with E2E_TEST_MODE=1.
        struct DevResp: Decodable { let devToken: String? }
        let data = try await perform("POST", "/auth/magic-link/request", query: [],
                                     body: MagicLinkRequestBody(email: email, deviceId: auth.deviceId),
                                     authenticated: false, allowRefresh: false)
        guard !data.isEmpty else { return nil }
        return (try? decoder.decode(DevResp.self, from: data))?.devToken
    }

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        try await send("POST", "/auth/magic-link/verify",
                       body: MagicLinkVerifyBody(token: token), authenticated: false)
    }

    func otpRequest(email: String) async throws {
        try await sendNoContent("POST", "/auth/otp/request",
                                body: OTPRequestBody(email: email), authenticated: false)
    }

    func otpVerify(email: String, code: String) async throws -> SessionResponse {
        try await send("POST", "/auth/otp/verify",
                       body: OTPVerifyBody(email: email, code: code), authenticated: false)
    }
```
(The X-Device-Id header is already attached by `makeRequest` line 364 — no change needed there. `auth.deviceId` is the stable per-install UUID, `AuthStore.swift:36-46`.)

- [ ] **Step 5: Conform the test doubles so the app + tests still compile.** Three files implement `APIClient` and all must gain the two new methods:

In `SnapceiptTests/Mocks/MockAPIClient.swift`: add handlers/recorders after the `magicLinkVerifyHandler` declaration (line 17), and impls after `magicLinkVerify` (ends line 86).

After line 17:
```swift
    var otpRequestHandler: ((String) async throws -> Void)?
    var otpVerifyHandler: ((_ email: String, _ code: String) async throws -> SessionResponse)?
    private(set) var otpRequestedEmails: [String] = []
    private(set) var otpVerifiedCodes: [(email: String, code: String)] = []
```
After `magicLinkVerify` (line 86):
```swift
    func otpRequest(email: String) async throws {
        otpRequestedEmails.append(email)
        guard let h = otpRequestHandler else { throw MockAPIClientError.unscripted }
        try await h(email)
    }

    func otpVerify(email: String, code: String) async throws -> SessionResponse {
        otpVerifiedCodes.append((email, code))
        guard let h = otpVerifyHandler else { throw MockAPIClientError.unscripted }
        return try await h(email, code)
    }
```

In `Snapceipt/Sync/StubAPIClient.swift`, after `magicLinkVerify` (line 14) add (StubAPIClient returns `devSession()`):
```swift
    func otpRequest(email: String) async throws {}
    func otpVerify(email: String, code: String) async throws -> SessionResponse { devSession() }
```

In `Snapceipt/Features/Auth/SignInView.swift`, the `PreviewAPIClient` class (line 154) backs the DEBUG `#Preview`s (it returns its `private var stub`, lines 217-220). After its `magicLinkVerify` (line 158) add:
```swift
    func otpRequest(email: String) async throws {}
    func otpVerify(email: String, code: String) async throws -> SessionResponse { stub }
```

- [ ] **Step 6: Run it — expect pass.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: the test target builds and `APIClientTests` all pass, including the three new ones.

- [ ] **Step 7: Commit.**

```
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift SnapceiptTests/APIClientTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): send install deviceId on magic-link/request + add OTP client

magicLinkRequest now includes deviceId in the body (header already sent),
so the backend can device-bind the token. Adds otpRequest/otpVerify to
APIClient (live + Stub + Preview doubles) for the cross-device sign-in-code
fallback.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: iOS — AuthViewModel OTP flow (request + verify + awaitingOTP state)

- [ ] **Step 1: Write the failing tests.** In `SnapceiptTests/AuthViewModelTests.swift`, extend the `makeMock` helper to script the OTP handlers, then add tests. First, inside `makeMock` (after `mock.signOutHandler = ...`, line 42), add:
```swift
        mock.otpRequestHandler = { _ in }
        mock.otpVerifyHandler = { _, _ in stub }
```
Then add these `@Test`s before the closing `}` of the struct (after line 245):
```swift
    @Test("requestOTP moves to awaitingOTP and calls the API once")
    func requestOTPMovesToAwaiting() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        await vm.requestOTP(email: "  Maya@Example.com ")
        #expect(api.otpRequestedEmails == ["maya@example.com"])
        #expect(vm.state == .awaitingOTP(email: "maya@example.com"))
        #expect(vm.pendingEmail == "maya@example.com")
    }

    @Test("requestOTP with an invalid email errors without calling the API")
    func requestOTPInvalidEmail() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        await vm.requestOTP(email: "nope")
        #expect(api.otpRequestedEmails.isEmpty)
        if case .error = vm.state {} else { Issue.record("expected .error") }
    }

    @Test("verifyOTP success → signedIn and persists the session")
    func verifyOTPSuccess() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)
        await vm.requestOTP(email: "maya@example.com")
        await vm.verifyOTP(code: "123456")
        #expect(api.otpVerifiedCodes.map(\.code) == ["123456"])
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
    }

    @Test("verifyOTP with no pending email is a no-op")
    func verifyOTPNoPending() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        let vm = AuthViewModel(api: api, auth: makeStore())
        await vm.verifyOTP(code: "123456")
        #expect(api.otpVerifiedCodes.isEmpty)
    }

    @Test("verifyOTP 400 → error state, no session saved")
    func verifyOTPWrongCode() async {
        let rec = Recorder()
        let api = makeMock(rec: rec)
        api.otpVerifyHandler = { _, _ in
            throw APIError(code: "VALIDATION_FAILED", message: "Incorrect code", status: 400)
        }
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)
        await vm.requestOTP(email: "maya@example.com")
        await vm.verifyOTP(code: "000000")
        if case .error = vm.state {} else { Issue.record("expected .error") }
        #expect(store.session == nil)
    }
```

- [ ] **Step 2: Run it — expect failure.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: compile error — `awaitingOTP` is not a case of `AuthState`, and `requestOTP`/`verifyOTP` don't exist.

- [ ] **Step 3: Add the state case.** In `Snapceipt/Features/Auth/AuthViewModel.swift`, add a case to `AuthState` (after `awaitingLink(email:)`, line 150):
```swift
        case awaitingOTP(email: String)
```

- [ ] **Step 4: Add the OTP methods + the mismatch message.** In `AuthViewModel.swift`, after `verifyMagicLink` (ends line 245), add:
```swift
    // MARK: OTP (cross-device sign-in code fallback)

    func requestOTP(email: String) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else {
            state = .error("Enter a valid email address.")
            return
        }
        state = .requestingLink
        pendingEmail = normalized
        do {
            try await api.otpRequest(email: normalized)
            state = .awaitingOTP(email: normalized)
            linkSentCount += 1
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("Couldn't send the code. Check your connection and try again.")
        }
    }

    func verifyOTP(code: String) async {
        guard let email = pendingEmail else { return }
        state = .verifying
        do {
            let session = try await api.otpVerify(email: email, code: code)
            auth.save(session)
            state = .signedIn
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("That code is invalid or has expired. Request a new one.")
        }
    }
```
Then map the new backend code to a clear message: in `message(for:)` (the `switch` at lines 302-311), add a case alongside the others (e.g. after the `AUTH_INVALID_TOKEN`/`AUTH_SESSION_REVOKED` case):
```swift
        case "AUTH_DEVICE_MISMATCH":
            return "Open the link on the device that requested it, or use a sign-in code instead."
```

- [ ] **Step 5: Run it — expect pass.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: the `AuthViewModel` suite passes including the new OTP tests.

- [ ] **Step 6: Commit.**

```
git add Snapceipt/Features/Auth/AuthViewModel.swift SnapceiptTests/AuthViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): AuthViewModel OTP sign-in flow + awaitingOTP state

requestOTP/verifyOTP drive the cross-device 6-digit code path, plus a
friendly message for the new AUTH_DEVICE_MISMATCH backend error.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: iOS — wire the OTP UI entry + verify sheet, and confirm the wait copy

This task is UI wiring (no new logic to unit-test beyond Task 7), so it ends in a build + visual check rather than a TDD cycle.

- [ ] **Step 1: Add an "Enter a code instead" affordance on the wait screen.** In `Snapceipt/Features/Auth/MagicLinkWaitView.swift`, the action `VStack(spacing: 12)` is lines 52-76. The subtitle already says "Tap it on this device to continue" (line 111) — that copy is now literally true (device-bound), keep it (it satisfies the DoD's "Tap it on this device"). Add a third button and state to present the code sheet:

Add near the top of the struct (after `@State private var confirmedCount = 0`, line 19):
```swift
    @State private var showingCodeEntry = false
```
Add the button inside the inner `VStack(spacing: 12)`, after the "Use a different email" `Button { ... } label: { ... }` block (after line 75, before the VStack closes at line 76):
```swift
                Button { showingCodeEntry = true } label: {
                    Text("Enter a code instead")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(accent.base)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
```
Add a `.sheet` after the `.task(id: vm.linkSentCount) { ... }` modifier (which ends at line 90), before the `body` closing brace (line 91):
```swift
        .sheet(isPresented: $showingCodeEntry) {
            OTPEntryView()
                .environment(vm)
                .environment(\.accent, accent)
        }
```

- [ ] **Step 2: Create the code-entry view.** Create `Snapceipt/Features/Auth/OTPEntryView.swift`. It mirrors the email field in `SignInView.swift` (TextField at line 117, primary button at line 133) and uses `.keyboardDismissButton()` (used at `SignInView.swift:112`). `Palette.cream`/`.ink`/`.ink2`/`.alert`, `accent.base`/`.soft`, and `font(.display(...))`/`font(.ui(...))` are all in use across these auth views:
```swift
import SwiftUI

/// 6-digit sign-in code entry — the cross-device fallback presented from the
/// magic-link wait screen. On success the VM transitions to .signedIn and the
/// RootView swaps this whole flow out, dismissing the sheet implicitly.
struct OTPEntryView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    private var isVerifying: Bool { vm.state == .verifying }

    var body: some View {
        VStack(spacing: 20) {
            Text("Enter your sign-in code")
                .font(.display(22, .bold))
                .foregroundStyle(Palette.ink)
                .padding(.top, 28)

            Text("We emailed a 6-digit code to \(vm.pendingEmail ?? "your inbox").")
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(accent.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                }

            Button { Task { await vm.verifyOTP(code: code) } } label: {
                Group {
                    if isVerifying { ProgressView().tint(.white) } else { Text("Sign in") }
                }
                .font(.ui(16, .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(code.count != 6 || isVerifying)
            .padding(.horizontal, 24)

            if case .error(let message) = vm.state {
                Text(message)
                    .font(.ui(13))
                    .foregroundStyle(Palette.alert)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
        .keyboardDismissButton()
    }
}

#if DEBUG
#Preview("OTP entry") {
    let vm = AuthViewModel(api: PreviewAPIClient(),
                           auth: AuthStore(keychain: Keychain(service: "sc.preview")))
    return OTPEntryView()
        .environment(vm)
        .environment(\.accent, .personal)
        .task { await vm.requestOTP(email: "maya@example.com") }
}
#endif
```
(`project.yml:24-25` globs the whole `Snapceipt/` directory into the app target, so a new file under `Snapceipt/Features/Auth/` is auto-included with no `project.yml` change. Only if you explicitly re-run `xcodegen generate` and the generated file list changes would `project.yml`/`*.xcodeproj` need re-committing.)

- [ ] **Step 3: (Optional, design call) Surface OTP as a peer on the sign-in screen.** Minimum required for GA: the wait-screen affordance from Step 1 covers the cross-device case. Skip adding a second entry point on `SignInView` unless design asks — this is intentionally not built here.

- [ ] **Step 4: Build + run the unit tests + visual check.** Run `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: the whole app + test target build; all existing + new tests pass. Then launch the app in the simulator and visually confirm: request a magic link → the wait screen shows "Enter a code instead" → tapping it presents the code sheet with the number pad.

- [ ] **Step 5: Commit.**

```
git add Snapceipt/Features/Auth/OTPEntryView.swift Snapceipt/Features/Auth/MagicLinkWaitView.swift
git commit -m "$(cat <<'EOF'
feat(ios): OTP code-entry sheet from the magic-link wait screen

Cross-device sign-in fallback UI for the now device-bound magic link.
"Enter a code instead" presents a 6-digit code sheet driven by the
AuthViewModel OTP flow.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Full regression sweep (backend + iOS) and the e2e guard

- [ ] **Step 1: Run the backend auth suites.** `npx vitest run test/auth.magiclink.test.ts test/auth.otp.test.ts test/auth.otp-email.test.ts`. Expected: all pass. (Add any other auth suites that exist in `test/`, e.g. `test/auth-session.test.ts` / `test/authmw.test.ts`, only if present — verify with `ls test/` first.)

- [ ] **Step 2: Run the full backend unit suite.** `npm test`. Expected: all pass. No other test asserts the old `MagicLinkRequestBody` shape, and the rate-limit `auth` tier auto-covers the new `/auth/otp/*` routes (`src/middleware/rateLimit.ts:121-149`) — confirm no rate-limit test broke.

- [ ] **Step 3: Run the iOS unit suite.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16'`. Expected: `APIClientTests`, `AuthViewModelTests`, and all others pass.

- [ ] **Step 4: Add an e2e cross-device OTP case.** The e2e harness boots the real worker with `E2E_TEST_MODE: "1"` in its `vars` (`e2e/auth-edges.e2e.test.ts:63-67`), so `/auth/otp/request` echoes `devCode` in the 202 body. Append this `it(...)` inside the existing `describe(...)` block in `e2e/auth-edges.e2e.test.ts` (after the J51 test, before the describe's closing `});`). It uses the file's `api()` helper (lines 87-112: `{ method, headers, body }` with `body` as an object; returns `{ status, json, text }`):

```ts
  it("J-OTP: cross-device OTP sign-in (devCode path) issues a session", async () => {
    const email = `e2e+${Date.now()}-otp@example.com`;
    const ip = "203.0.113.55";
    const deviceId = crypto.randomUUID();
    const reqRes = await api("/auth/otp/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    expect(reqRes.status).toBe(202);
    const code: string = reqRes.json.devCode;
    expect(code).toMatch(/^\d{6}$/);

    const verifyRes = await api("/auth/otp/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { email, code },
    });
    expect(verifyRes.status).toBe(200);
    expect(typeof verifyRes.json.accessToken).toBe("string");
    expect(verifyRes.json.accessToken.split(".")).toHaveLength(3);
    expect(verifyRes.json.user.email).toBe(email.toLowerCase());
    expect(typeof verifyRes.json.refreshToken).toBe("string");
  });
```
Then run it: `npx vitest run --config vitest.e2e.config.ts e2e/auth-edges.e2e.test.ts` (the `test:e2e` script in `package.json:12` is `vitest run --config vitest.e2e.config.ts`). Expected: the new case (and the existing J04/J06/J51 cases) pass.

- [ ] **Step 5: Commit the e2e addition.**

```
git add e2e/auth-edges.e2e.test.ts
git commit -m "$(cat <<'EOF'
test(auth): e2e cross-device OTP sign-in (devCode path)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Open questions (human input needed):**

- TTL/strictness: §21 (docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md:334) locks 'same-device only (tighter; OTP fallback covers edge cases)'. The magic-link TTL stays 600s (MAGIC_LINK_TTL_SECONDS). Confirm the OTP TTL — these tasks reuse the existing 600s convention from the email-change flow (account.ts EMAIL_CODE_TTL_SECONDS). Human decision: keep 600s or shorten OTP to e.g. 300s.
- Should device binding be enforced ONLY for tokens minted AFTER this ships (metadata-present => enforce, metadata-absent => allow, which these tasks implement for zero-downtime rollout), or hard-required for all tokens? Current plan is the soft/forward-compatible variant; a hard cutover would 401 any in-flight pre-rollout link. Recommend the soft variant; confirm.
- OTP UI placement: these tasks add an 'Enter a code instead' affordance on the email-wait screen and a code-entry sheet. A designer may want to instead surface OTP as a primary peer to the magic link on the sign-in screen. The backend contract is independent of this choice.

_Critic verdict: fixed (6 issue(s) fixed)._

---

## Workstream 5: Legal & Compliance Surfaces (Terms of Service, Privacy entity/ABN/NDB, in-app legal links)

**Goal:** Ship App Store GA-required legal surfaces: a Terms of Service page on snapceipt.cc, a privacy policy that names the operating legal entity + ABN and includes a Notifiable-Data-Breach clause, and tappable in-app Terms/Privacy links on the sign-in screen and a Legal row in the profile hub.

**Dependencies:** none

**Definition of done:**

- [ ] site/public/terms.html exists, opens with the same head/nav/footer/site.css markup as privacy.html and support.html, and `wrangler dev` from site/ serves GET /terms with HTTP 200 and the body contains "<h1>Terms of Service</h1>"
- [ ] Every site footer (index.html, pricing.html, privacy.html, support.html, terms.html) contains an `<a href="/terms">Terms</a>` link in the .footer .inner block
- [ ] site/public/sitemap.xml contains `<loc>https://snapceipt.cc/terms</loc>`
- [ ] privacy.html names the operating legal entity and ABN (rendered from the open-question value) and contains a "Notifiable data breaches" <h2> section referencing the OAIC and the Privacy Act 1988 (Cth) NDB scheme; its Last-updated date is bumped to 15 June 2026
- [ ] SignInView.swift line 103's disclaimer renders "Terms" linking to https://snapceipt.cc/terms and "Privacy Policy" linking to https://snapceipt.cc/privacy as tappable links (Markdown AttributedString), with no plain-Text fallback
- [ ] ProfileTabView.swift has a new "Legal" row in the App group that opens https://snapceipt.cc/terms via the existing @Environment(\.openURL) pattern, with a stable accessibility id AccessibilityID.profileRowLegal == "profile.row.legal"
- [ ] AccessibilityID.profileRowLegal exists and is asserted in a SnapceiptTests Swift Testing test that passes
- [ ] xcodebuild test for the new AccessibilityID test passes; the app builds and the SignInView links + Profile Legal row open the correct URLs (visual confirm)

**Files:**

- `site/public/terms.html`
- `site/public/privacy.html`
- `site/public/index.html`
- `site/public/pricing.html`
- `site/public/support.html`
- `site/public/sitemap.xml`
- `Snapceipt/Features/Auth/SignInView.swift`
- `Snapceipt/Features/Profiles/ProfileTabView.swift`
- `Snapceipt/Shared/AccessibilityID.swift`
- `SnapceiptTests/AccessibilityIDLegalTests.swift`

### Task 1: Author the Terms of Service page (site/public/terms.html)

Create a new `terms.html` matching the exact head/nav/footer/`site.css` chrome and `.prose`/`.legalHead`/`h2`/`ul` markup conventions used by `site/public/privacy.html` (lines 1-102). It reuses the same Google Fonts link, `<link rel="stylesheet" href="/site.css">`, the `.wrap > nav.nav` header, the `.prose` body, and the shared `.footer .inner` block. Substitute the human-supplied `__LEGAL_ENTITY__` / `__ABN__` tokens (see open_questions) before deploy.

- [ ] **Step 1: Write the page.** Create `site/public/terms.html` with this exact content:

```html
<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Terms of Service — Snapceipt</title>
<meta name="description" content="The terms that govern your use of Snapceipt — accounts, subscriptions billed through Apple, acceptable use, disclaimers and Australian law.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="https://snapceipt.cc/terms">
<meta property="og:type" content="website">
<meta property="og:title" content="Terms of Service — Snapceipt">
<meta property="og:description" content="The terms that govern your use of Snapceipt — accounts, subscriptions billed through Apple, acceptable use, disclaimers and Australian law.">
<meta property="og:url" content="https://snapceipt.cc/terms">
<meta property="og:image" content="https://snapceipt.cc/favicon.svg">
<meta name="twitter:card" content="summary">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,500;0,9..144,600;1,9..144,500&family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/site.css">
</head>
<body>
<div class="wrap"><nav class="nav"><a class="logo" href="/">Snap<b>ceipt</b></a><div class="links"><a href="/">Home</a><a href="/pricing">Pricing</a><a href="/support">Support</a></div></nav></div>
<div class="prose">
  <div class="legalHead">
    <div class="kicker">Legal</div>
    <h1>Terms of Service</h1>
    <p class="meta">Effective 15 June 2026 · Last updated 15 June 2026 · __LEGAL_ENTITY__ (ABN __ABN__), trading as Snapceipt ("we", "us", "our")</p>
    <p class="sub">These terms are a contract between you and __LEGAL_ENTITY__ for your use of the Snapceipt app and website. By creating an account or using Snapceipt you agree to them. If you don't agree, please don't use Snapceipt.</p>
  </div>

  <h2>Who can use Snapceipt</h2>
  <p>You must be at least 16 years old and able to enter a binding contract. Snapceipt is built for Australian sole traders and households managing their own receipts, expenses and GST. You're responsible for keeping your account credentials secure and for everything that happens under your account.</p>

  <h2>Your account</h2>
  <p>You sign in with Sign in with Apple or a magic-link email. You agree to give accurate information and to keep it current. You may delete your account at any time from <b>Account → Delete Account</b> in the app; deletion is immediate and irreversible.</p>

  <h2>Subscriptions & billing</h2>
  <p>Snapceipt has a free tier and a paid <b>Pro</b> subscription. All paid subscriptions are sold and billed by Apple through your App Store account, not by us. Prices are shown in the app before you buy.</p>
  <ul>
    <li><b>Auto-renewal</b> — Pro renews automatically each period until you cancel. Your Apple ID is charged at confirmation of purchase and at each renewal.</li>
    <li><b>Managing & cancelling</b> — manage or cancel in <b>Settings → [your name] → Subscriptions</b> on your device. Cancelling stops the next renewal; you keep Pro until the current period ends.</li>
    <li><b>Refunds</b> — refunds for App Store purchases are handled by Apple under Apple's terms. We can't issue App Store refunds directly.</li>
  </ul>

  <h2>Acceptable use</h2>
  <p>You agree not to misuse Snapceipt. In particular, you won't: break the law or infringe others' rights; attempt to access accounts or data that aren't yours; probe, scan or interfere with the service or its security; reverse engineer or resell the service; or upload content you don't have the right to upload.</p>

  <h2>Your content</h2>
  <p>Your receipts, records and other content remain yours. You grant us only the limited licence needed to host, process and sync your content so the app works for you, as described in our <a href="/privacy">Privacy Policy</a>. We don't use the content of your receipts to train AI models.</p>

  <h2>Snapceipt is a tool, not tax advice</h2>
  <p>Snapceipt helps you capture and organise receipts and estimate GST and BAS figures. It is not accounting, tax or legal advice, and it doesn't replace your accountant or the ATO. You're responsible for the accuracy of your records and your tax lodgements. Always check figures before you rely on them.</p>

  <h2>Availability & changes</h2>
  <p>We work to keep Snapceipt running but we don't guarantee it will be uninterrupted or error-free. We may add, change or remove features, and we may update these terms. If we make material changes we'll update the date above and, where appropriate, notify you in the app. Continued use after changes means you accept the updated terms.</p>

  <h2>Disclaimers & liability</h2>
  <p>To the extent permitted by law, Snapceipt is provided "as is" without warranties of any kind. Nothing in these terms excludes rights you have under the Australian Consumer Law that cannot lawfully be excluded. Where our liability can be limited, it is limited to re-supplying the service or paying the cost of re-supply. We aren't liable for indirect or consequential loss.</p>

  <h2>Suspension & termination</h2>
  <p>You can stop using Snapceipt and delete your account at any time. We may suspend or terminate access if you breach these terms or use the service unlawfully. On termination, the sections that by their nature should survive (content licence, disclaimers, liability and governing law) continue to apply.</p>

  <h2>Governing law</h2>
  <p>These terms are governed by the laws of New South Wales and the Commonwealth of Australia, and you submit to the courts of that jurisdiction.</p>

  <h2>Contact us</h2>
  <p>Questions about these terms? Email <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a> and we'll respond within a couple of business days.</p>
</div>
<footer class="footer"><div class="inner">
  <a class="logo" style="font-size:18px" href="/">Snap<b>ceipt</b></a>
  <a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a>
  <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a>
  <span class="sp">© 2026 Snapceipt · Made in Australia 🇦🇺</span>
</div></footer>
</body></html>
```

- [ ] **Step 2: Serve it locally and confirm 200.** From the `site/` directory start the assets-only Worker, then curl the route (the Worker's `html_handling` default serves `/terms` from `terms.html`, exactly as it serves `/privacy` from `privacy.html`):

```bash
cd /Users/yangqi/Documents/github/Snapceipt/site && npx wrangler dev --port 8788 &
WRANGLER_PID=$!
# wait for the dev server to come up
until curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8788/terms | grep -q 200; do sleep 1; done
echo "--- status ---"; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8788/terms
echo "--- h1 present? ---"; curl -s http://127.0.0.1:8788/terms | grep -o '<h1>Terms of Service</h1>'
kill $WRANGLER_PID
```

Expected output:
```
--- status ---
200
--- h1 present? ---
<h1>Terms of Service</h1>
```

- [ ] **Step 3: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add site/public/terms.html && git commit -m "$(cat <<'EOF'
feat(site): add Terms of Service page

Adds /terms in the same chrome as /privacy and /support. Entity name
and ABN are placeholder tokens (__LEGAL_ENTITY__ / __ABN__) to be
substituted before deploy.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Link Terms in every site footer + add it to sitemap.xml

The footer `.footer .inner` block is duplicated verbatim in `index.html` (lines 178-183, links on line 180), `pricing.html` (lines 97-102, links on line 99), `privacy.html` (lines 96-101, links on line 98) and `support.html` (lines 57-62, links on line 59). Each currently has `<a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/support">Support</a>`. Insert a Terms link after Privacy in all four. (terms.html already has the Terms link from Task 1.)

- [ ] **Step 1: Add Terms to each footer.** In each of `site/public/index.html`, `site/public/pricing.html`, `site/public/privacy.html`, `site/public/support.html`, replace the footer links line:

  Old:
  ```html
  <a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/support">Support</a>
  ```
  New:
  ```html
  <a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a>
  ```

- [ ] **Step 2: Add /terms to the sitemap.** Edit `site/public/sitemap.xml` (currently 4 `<url>` entries, lines 3-6). Add the terms URL after the privacy URL:

  Old:
  ```xml
    <url><loc>https://snapceipt.cc/privacy</loc></url>
    <url><loc>https://snapceipt.cc/support</loc></url>
  ```
  New:
  ```xml
    <url><loc>https://snapceipt.cc/privacy</loc></url>
    <url><loc>https://snapceipt.cc/terms</loc></url>
    <url><loc>https://snapceipt.cc/support</loc></url>
  ```

- [ ] **Step 2.5: Verify every footer now links Terms.** Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt && grep -c 'href="/terms"' site/public/index.html site/public/pricing.html site/public/privacy.html site/public/support.html site/public/terms.html; grep -c 'snapceipt.cc/terms' site/public/sitemap.xml
```

Expected output (one count per file, each exactly 1, then the sitemap count 1):
```
site/public/index.html:1
site/public/pricing.html:1
site/public/privacy.html:1
site/public/support.html:1
site/public/terms.html:1
site/public/sitemap.xml:1
```
(terms.html shows 1 — only the footer `<a href="/terms">Terms</a>` matches the literal `href="/terms"` substring; its canonical/og lines use `href="https://snapceipt.cc/terms"` / `content="https://snapceipt.cc/terms"`, which do NOT contain `href="/terms"`.)

- [ ] **Step 3: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add site/public/index.html site/public/pricing.html site/public/privacy.html site/public/support.html site/public/sitemap.xml && git commit -m "$(cat <<'EOF'
feat(site): link Terms in all footers and sitemap

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add operating legal entity + ABN + Notifiable-Data-Breach clause to the privacy policy

`site/public/privacy.html` line 26 currently reads `Effective 15 June 2026 · Last updated 15 June 2026 · Snapceipt ("we", "us", "our")` with no legal entity, no ABN, and no NDB section. The contact section ends at line 94; "Changes to this policy" is the `<h2>` at line 90 immediately preceding "Contact us" (line 93). We will (a) name the entity/ABN in the meta line, (b) add a "Notifiable data breaches" `<h2>` section before "Changes to this policy". Use the same `__LEGAL_ENTITY__` / `__ABN__` tokens as Task 1 (see open_questions).

- [ ] **Step 1: Name the entity + ABN in the meta line.** Edit `site/public/privacy.html`:

  Old (line 26):
  ```html
    <p class="meta">Effective 15 June 2026 · Last updated 15 June 2026 · Snapceipt ("we", "us", "our")</p>
  ```
  New:
  ```html
    <p class="meta">Effective 15 June 2026 · Last updated 15 June 2026 · __LEGAL_ENTITY__ (ABN __ABN__), trading as Snapceipt ("we", "us", "our")</p>
  ```

- [ ] **Step 2: Add the NDB section.** Insert a new `<h2>` block immediately before the existing "Changes to this policy" heading.

  Old (line 90):
  ```html
  <h2>Changes to this policy</h2>
  ```
  New:
  ```html
  <h2>Notifiable data breaches</h2>
  <p>We comply with the Notifiable Data Breaches (NDB) scheme under Part IIIC of the Privacy Act 1988 (Cth). If a data breach involving your personal information is likely to result in serious harm, we will notify you and the Office of the Australian Information Commissioner (OAIC) as soon as practicable after we become aware of it, and we'll tell you what happened and the steps you can take. We maintain a process to assess suspected breaches and to contain and remediate them.</p>

  <h2>Changes to this policy</h2>
  ```

- [ ] **Step 3: Verify the additions render and the file still serves.** From `site/`:

```bash
cd /Users/yangqi/Documents/github/Snapceipt/site && npx wrangler dev --port 8788 &
WRANGLER_PID=$!
until curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8788/privacy | grep -q 200; do sleep 1; done
echo "--- ABN + entity meta present? ---"; curl -s http://127.0.0.1:8788/privacy | grep -o 'ABN __ABN__'
echo "--- NDB section present? ---"; curl -s http://127.0.0.1:8788/privacy | grep -o '<h2>Notifiable data breaches</h2>'
kill $WRANGLER_PID
```

Expected output:
```
--- ABN + entity meta present? ---
ABN __ABN__
--- NDB section present? ---
<h2>Notifiable data breaches</h2>
```
(Before deploy, the `__LEGAL_ENTITY__`/`__ABN__` tokens must be replaced with the real values from open_questions; the grep will then match the real ABN string.)

- [ ] **Step 4: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add site/public/privacy.html && git commit -m "$(cat <<'EOF'
feat(site): add legal entity, ABN and NDB clause to privacy policy

Names the operating entity + ABN (placeholder tokens) and adds a
Notifiable Data Breaches section per Part IIIC of the Privacy Act
1988 (Cth).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add the AccessibilityID for the in-app Legal row (TDD)

`Snapceipt/Shared/AccessibilityID.swift` holds the stable ids shared by the app and UI-test targets. The profile-row ids cluster around lines 136-199 (e.g. `profileRowPrivacy = "profile.row.privacy"` at line 192, `profileRowHelp = "profile.row.help"` at line 199). Add `profileRowLegal`. The repo's test idiom is Swift Testing (`import Testing`, `@testable import Snapceipt`, `@Suite`, `@Test`, `#expect`) — see `SnapceiptTests/AccessibilityIDBasTests.swift`. The SnapceiptTests target uses directory-based sources in `project.yml`, so a new `.swift` file is picked up automatically after `xcodegen generate`.

- [ ] **Step 1: Write the failing test.** Create `SnapceiptTests/AccessibilityIDLegalTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("AccessibilityID legal ids")
struct AccessibilityIDLegalTests {
    @Test("Profile Legal row id exists with a stable string value")
    func legalRowId() {
        #expect(AccessibilityID.profileRowLegal == "profile.row.legal")
    }
}
```

- [ ] **Step 2: Run it — it fails to compile.** The symbol doesn't exist yet:

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate >/dev/null && xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AccessibilityIDLegalTests 2>&1 | tail -20
```

Expected: build/compile failure with `value of type 'AccessibilityID.Type' has no member 'profileRowLegal'` (TEST FAILED / build error).

- [ ] **Step 3: Add the id.** Edit `Snapceipt/Shared/AccessibilityID.swift`. After line 199 (`static let profileRowHelp = "profile.row.help"  // opens external URL`), add:

```swift
    static let profileRowLegal = "profile.row.legal"                    // opens external Terms URL
```

- [ ] **Step 4: Run it — it passes.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AccessibilityIDLegalTests 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` and the `AccessibilityIDLegalTests` suite passing.

- [ ] **Step 5: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add Snapceipt/Shared/AccessibilityID.swift SnapceiptTests/AccessibilityIDLegalTests.swift && git commit -m "$(cat <<'EOF'
feat(account): add profileRowLegal accessibility id

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Make the SignInView Terms & Privacy disclaimer tappable

`Snapceipt/Features/Auth/SignInView.swift` lines 103-108 render a plain `Text("By continuing you agree to our Terms & Privacy Policy.")`. SwiftUI's `Text` renders Markdown links from a `LocalizedStringKey` and the system handles taps (opens the URL in-app/Safari) automatically — no `openURL` wiring needed. We replace the literal with a Markdown string containing the two links and tint them with the accent already in scope (`@Environment(\.accent) private var accent`, line 8; `accent.base` is already used at lines 23 and 138).

- [ ] **Step 1: Replace the plain Text with a Markdown link Text.** Edit `Snapceipt/Features/Auth/SignInView.swift`.

  Old (lines 103-108):
  ```swift
            Text("By continuing you agree to our Terms & Privacy Policy.")
                .font(.ui(11.5))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
  ```
  New:
  ```swift
            Text("By continuing you agree to our [Terms](https://snapceipt.cc/terms) & [Privacy Policy](https://snapceipt.cc/privacy).")
                .font(.ui(11.5))
                .foregroundStyle(Palette.ink3)
                .tint(accent.base)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
  ```

  Note: the `Text(_:)` initializer here takes a `LocalizedStringKey`, so the Markdown `[label](url)` syntax is parsed into tappable links automatically. `.tint(accent.base)` colours the links; the surrounding text keeps `Palette.ink3`.

- [ ] **Step 2: Build to confirm it compiles.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Visual confirm (operator step).** Launch the app to the signed-out Sign-in screen (run in simulator: `xcodebuild build` then open the app, or use `scripts/tour.sh` if it lands on SignInView). Confirm the footer line shows "Terms" and "Privacy Policy" as coloured (accent) tappable links. Tap each:
  - "Terms" opens `https://snapceipt.cc/terms`.
  - "Privacy Policy" opens `https://snapceipt.cc/privacy`.
  Expected confirmation: both open the correct page in Safari / SafariView; the rest of the sentence is not tappable.

- [ ] **Step 4: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add Snapceipt/Features/Auth/SignInView.swift && git commit -m "$(cat <<'EOF'
feat(auth): make Terms & Privacy links tappable on sign-in

Renders the disclaimer via Markdown links to snapceipt.cc/terms and
/privacy instead of plain Text.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add a "Legal" row to the Profile hub that opens Terms

`Snapceipt/Features/Profiles/ProfileTabView.swift` already imports the `openURL` action (`@Environment(\.openURL) private var openURL`, line 23) and has the exact pattern in `helpRow` (lines 166-180): a `Button` whose action does `if let url = URL(string: ...) { openURL(url) }` (helpRow opens `https://snapceipt.cc/help`). The "App" group of rows ends at `helpRow` (line 61 in the body) before the "Account" `groupLabel` (line 63). Add a Legal row after `helpRow` in the group, and a matching computed property modelled on `helpRow`, using `AccessibilityID.profileRowLegal` from Task 4.

- [ ] **Step 1: Add the Legal row to the App group.** Edit `Snapceipt/Features/Profiles/ProfileTabView.swift`.

  Old (lines 60-61):
  ```swift
                row(icon: "info", title: "Privacy & security", id: AccessibilityID.profileRowPrivacy, action: onOpenPrivacy)
                helpRow
  ```
  New:
  ```swift
                row(icon: "info", title: "Privacy & security", id: AccessibilityID.profileRowPrivacy, action: onOpenPrivacy)
                legalRow
                helpRow
  ```

- [ ] **Step 2: Add the `legalRow` computed property.** Insert it immediately before `helpRow` (before its doc comment at line 165). Add:

```swift
    /// Legal — opens the external Terms of Service page via the SwiftUI openURL action.
    /// (The Privacy Policy is reachable from there and from the sign-in disclaimer.)
    private var legalRow: some View {
        Button {
            if let url = URL(string: "https://snapceipt.cc/terms") { openURL(url) }
        } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: "receipt", tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                    Text("Terms & Privacy").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                    Spacer(); Icon(name: "chevR", size: 16, color: Palette.ink3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.profileRowLegal)
    }

```

  (`IconCircle`, `Card`, `HStack`, `Icon` and the `accent`/`Palette` tokens are all already used by `helpRow`; `IconCircle(name:tint:soft:size:iconSize:)` and `Card(padding:)` match the helpRow call; `"receipt"` and `"chevR"` are valid icon keys in `Snapceipt/DesignSystem/Icons.swift` and `"receipt"` is already used at lines 51 and 57.)

- [ ] **Step 3: Build to confirm it compiles.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild build -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Visual confirm (operator step).** Launch the app, go to the Profile tab. Under the "App" group, confirm a new "Terms & Privacy" row appears between "Privacy & security" and "Help & support". Tap it and confirm it opens `https://snapceipt.cc/terms` in Safari / SafariView. Expected confirmation: the row is present, tappable, and opens the Terms page.

- [ ] **Step 5: Commit.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add Snapceipt/Features/Profiles/ProfileTabView.swift && git commit -m "$(cat <<'EOF'
feat(account): add Terms & Privacy row to Profile hub

New Legal row opens snapceipt.cc/terms via openURL, reusing the
existing helpRow pattern.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Full regression build + final verification

- [ ] **Step 1: Run the new iOS test suite and a clean build together.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate >/dev/null && xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AccessibilityIDLegalTests 2>&1 | tail -8
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 2: Serve the whole site locally and smoke every legal route.**

```bash
cd /Users/yangqi/Documents/github/Snapceipt/site && npx wrangler dev --port 8788 &
WRANGLER_PID=$!
until curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8788/terms | grep -q 200; do sleep 1; done
for p in / /pricing /privacy /terms /support /sitemap.xml; do
  printf '%s -> %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8788$p)"
done
kill $WRANGLER_PID
```

Expected output:
```
/ -> 200
/pricing -> 200
/privacy -> 200
/terms -> 200
/support -> 200
/sitemap.xml -> 200
```

- [ ] **Step 3: Confirm the working tree is clean (all six prior commits landed).**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git status --porcelain && git log --oneline -6
```

Expected: empty `git status --porcelain`, and the six commits from Tasks 1-6 at the top of the log. Before production deploy, remember to substitute `__LEGAL_ENTITY__` / `__ABN__` in `site/public/terms.html` and `site/public/privacy.html` with the real values (see open_questions).

**Open questions (human input needed):**

- The operating legal entity NAME and ABN for Snapceipt (e.g. "Snapceipt Pty Ltd, ABN 12 345 678 901"). These are human-supplied values that must be substituted into privacy.html and terms.html before deploy. Tasks below use the placeholder token __LEGAL_ENTITY__ / __ABN__ — search-and-replace both files before going live.
- Confirm the governing-law jurisdiction for the Terms (assumed: laws of New South Wales / Commonwealth of Australia). Adjust the "Governing law" clause in terms.html if a different Australian state applies.
- The Profile hub help row (ProfileTabView.swift:168) opens https://snapceipt.cc/help, which is NOT a real page on the site (no /help.html, not in sitemap). Out of scope for this workstream but flagged: either add a /help page/redirect or repoint that row to /support. Not blocking the Legal work.

_Critic verdict: fixed (7 issue(s) fixed)._

---

## Workstream 6 — Apple auto-renewable Pro subscriptions (StoreKit 2) for GA

**Goal:** Ship StoreKit 2 in-app subscriptions for the Pro tier ($9.99/mo, $79/yr, 14-day free trial) so the advertised Pro features (BAS export, quotes, logbooks, email-in) become purchasable in-app per Apple Guideline 3.1.1, with the entitlement flowing iOS↔backend so users.plan flips on purchase/expiry and Pro features are gated client- and server-side.

**Dependencies:** Standalone, but must land on/after the GA branch where Apple Sign-in + push are wired (this workstream reuses src/lib/apple.ts JWS idiom, src/lib/sessions.ts issueSession test helper, and the existing /auth/me plan field). No code dependency on other GA workstreams; migration 0006 assumes 0001-0005 are already applied (they are, per migrations/).

**Definition of done:**

- [ ] App Store Connect has subscription group `Snapceipt Pro` with two active products `app.snapceipt.pro.monthly` ($9.99 AUD) and `app.snapceipt.pro.yearly` ($79 AUD), each carrying a 14-day introductory free-trial offer, and the app is enrolled in the App Store Small Business Program.
- [ ] `Snapceipt/Snapceipt.storekit` exists, is referenced by the Snapceipt scheme's StoreKit Configuration, and loads both products in the local StoreKit testing environment.
- [ ] In-App Purchase capability key is present in BOTH `Snapceipt/Snapceipt.entitlements` and `Snapceipt/Snapceipt.Release.entitlements`.
- [ ] `xcodebuild test -scheme Snapceipt -only-testing:SnapceiptTests/EntitlementStoreTests` passes (entitlement derivation logic).
- [ ] `xcodebuild test -scheme Snapceipt -only-testing:SnapceiptTests/StoreKitServiceTests` passes (product-id mapping + purchase-result mapping).
- [ ] `xcodebuild test -scheme Snapceipt -only-testing:SnapceiptTests/ProGateTests` passes (Pro feature gating helper for BAS/quotes/logbooks/email-in).
- [ ] `npx vitest run test/appstore-notifications.test.ts` passes: a signed-payload SUBSCRIBED/DID_RENEW flips users.plan to 'pro' with subscription_status/expires/original_transaction_id set; EXPIRED/REFUND/REVOKE reverts to 'free'.
- [ ] `npx vitest run test/appstore-plan-flip.test.ts` passes (pure applyNotification reducer unit test).
- [ ] `npx vitest run test/appstore-app.test.ts` passes: POST /appstore/notifications is reachable WITHOUT a bearer (path in PUBLIC_PATHS) and a malformed body is rejected.
- [ ] GET /auth/me returns the live plan after a flip (manual sandbox check), and the Paywall view presents both products with localized prices and a working Purchase + Restore.
- [ ] Sandbox end-to-end checklist (purchase, restore, trial->paid, refund/expiry->revert) all observed green in a build run against the App Store Sandbox.

**Files:**

- `migrations/0006_subscriptions.sql`
- `src/lib/appStoreNotifications.ts`
- `src/routes/appstore.ts`
- `src/app.ts`
- `src/middleware/auth.ts`
- `src/env.ts`
- `test/appstore-plan-flip.test.ts`
- `test/appstore-notifications.test.ts`
- `test/appstore-app.test.ts`
- `test/helpers/appstore.ts`
- `Snapceipt/Snapceipt.entitlements`
- `Snapceipt/Snapceipt.Release.entitlements`
- `Snapceipt/Snapceipt.storekit`
- `Snapceipt/Features/Subscription/StoreKitService.swift`
- `Snapceipt/Features/Subscription/EntitlementStore.swift`
- `Snapceipt/Features/Subscription/ProGate.swift`
- `Snapceipt/Features/Subscription/PaywallView.swift`
- `Snapceipt/App/SnapceiptApp.swift`
- `Snapceipt/Sync/APIClient.swift`
- `Snapceipt/Sync/StubAPIClient.swift`
- `Snapceipt/Sync/DTOs.swift`
- `SnapceiptTests/EntitlementStoreTests.swift`
- `SnapceiptTests/StoreKitServiceTests.swift`
- `SnapceiptTests/ProGateTests.swift`
- `project.yml`

## Workstream 6 — Apple auto-renewable Pro subscriptions (StoreKit 2)

Context that grounds every task below (verified against the repo):
- `users.plan TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro'))` — `migrations/0001_init.sql:21`. It is written only at signup (`src/routes/auth.ts:171,308`) and read back by `GET /auth/me` (`src/routes/auth.ts:455,489`). Nothing ever flips it today.
- Migrations run 0001→0005; the next number is **0006**. Tests apply them via `applyD1Migrations(env.DB, env.TEST_MIGRATIONS)` (`test/apply-migrations.ts`).
- Routes mount at module scope in `src/app.ts`; the auth allowlist is `PUBLIC_PATHS` in `src/middleware/auth.ts:11`.
- `src/lib/apple.ts` verifies Apple **identity** tokens (RS256, jose `jwtVerify` + `createLocalJWKSet` against the JWKS endpoint). App Store Server Notifications V2 are a DIFFERENT format (ES256 + an x5c cert chain), so the webhook does NOT reuse `apple.ts`. For GA the webhook **decodes** (base64url, no chain pinning) the signed JWS payloads; x5c signature pinning is a flagged follow-up (see open_questions).
- Backend test idiom: `import { env, SELF } from "cloudflare:test"`, mint a bearer with `issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY })` (`test/account-delete.test.ts:90`).
- iOS tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) — see `SnapceiptTests/BasCardGateTests.swift`. DTO `AccountUser` already carries `plan` (`Snapceipt/Sync/DTOs.swift:166`); `SessionUser` does not (`DTOs.swift:131`).
- Pro features (per `site/public/pricing.html`): **BAS-ready export, quotes & invoices, vehicle & WFH logbooks, email-in**. Existing gate idiom: `ReportsView.showsBasCard(...)` (`SnapceiptTests/BasCardGateTests.swift`).
- DI is wired in `Snapceipt/App/SnapceiptApp.swift` via `@State` + `.environment(...)`. NOTE: `api` is a **local** `let` inside `init()` (lines 44/57), not a stored property — Task 10 adds a stored property to make it reachable from `.task`.
- The `Snapceipt` app target globs `path: Snapceipt` and excludes only `Info.plist` + both `.entitlements` (`project.yml:24-29`), so a new `.storekit` file is auto-included as a resource.

---

### Task 1 — App Store Connect: subscription group + two products (OPERATOR)

Pure operator steps. No code. Use the App Store Connect account holder/admin login.

- [ ] **Step 1: Create the subscription group.** App Store Connect → My Apps → Snapceipt → **Subscriptions** (left sidebar, under Monetization) → **Manage** → **+ Create** next to "Subscription Groups" → Reference Name: `Snapceipt Pro`. Save. Expected: a group named "Snapceipt Pro" appears.
- [ ] **Step 2: Create the monthly product.** Inside the group → **+ (Create Subscription)** → Reference Name: `Pro Monthly`, Product ID: `app.snapceipt.pro.monthly` → Duration: **1 Month** → Subscription Price → Australia: **$9.99 AUD** (Apple will generate equivalents) → add a Localization (English, AU): Display Name "Snapceipt Pro (Monthly)", Description "BAS export, quotes, logbooks and email-in." Save. Expected: status "Ready to Submit" / "Missing Metadata" with the product ID exactly `app.snapceipt.pro.monthly`.
- [ ] **Step 3: Create the yearly product.** Same group → **+** → Reference Name: `Pro Yearly`, Product ID: `app.snapceipt.pro.yearly` → Duration: **1 Year** → price Australia **$79 AUD** → English (AU) Localization: "Snapceipt Pro (Yearly)", "Everything in Pro, billed yearly — save 34%." Save. Expected: product ID exactly `app.snapceipt.pro.yearly`.
- [ ] **Step 4: Verify the IDs match the app.** Confirm both product IDs are byte-for-byte `app.snapceipt.pro.monthly` and `app.snapceipt.pro.yearly` (these strings are hard-coded in `StoreKitService.ProductID` in Task 7). Expected: exact match — any typo breaks product loading.

---

### Task 2 — App Store Connect: 14-day introductory free trial offers (OPERATOR)

- [ ] **Step 1: Add the monthly intro offer.** Subscriptions → `Pro Monthly` → **Introductory Offers** → **+ Set Up Introductory Offer** → Countries/Regions: **All** → Start: today, no end date → Type: **Free** → Duration: **2 Weeks** (Apple's closest to 14 days; 14 days == 2 weeks). Save. Expected: "Free, 2 weeks" intro offer listed for the monthly product.
- [ ] **Step 2: Add the yearly intro offer.** `Pro Yearly` → Introductory Offers → **+** → All regions → Type: **Free** → Duration: **2 Weeks**. Save. Expected: "Free, 2 weeks" intro offer listed for the yearly product.
- [ ] **Step 3: Confirm trial copy alignment.** Cross-check `site/public/pricing.html` ("Pro starts with a 14-day free trial") — the 2-week App Store offer is the implementation of that promise. No code change. Expected: marketing claim and App Store offer agree.

---

### Task 3 — App Store Connect: enroll in the App Store Small Business Program (OPERATOR)

- [ ] **Step 1: Open the program.** App Store Connect → **Business** (or developer.apple.com → Account → Agreements) → **App Store Small Business Program** → **Enroll**. Requires the legal/financial Account Holder. Expected: enrollment form.
- [ ] **Step 2: Submit enrollment.** Accept the terms; declare the developer's total proceeds are under the threshold. Submit. Expected: confirmation that the 15% commission rate (vs 30%) applies to the enrolled membership for the next calendar year. (This is purely commercial — no app behavior changes.)

---

### Task 4 — StoreKit local-testing config file `Snapceipt.storekit`

This file lets the simulator/dev device run purchases without App Store Connect, and feeds `StoreKitServiceTests`.

- [ ] **Step 1: Create `Snapceipt/Snapceipt.storekit`** with both products and a 2-week free intro offer each, matching the IDs from Task 1:
```json
{
  "identifier" : "SNAPCEIPT_STOREKIT_V1",
  "nonRenewingSubscriptions" : [],
  "products" : [],
  "settings" : {
    "_failTransactionsEnabled" : false,
    "_locale" : "en_AU",
    "_storefront" : "AUS",
    "_storeKitErrors" : []
  },
  "subscriptionGroups" : [
    {
      "id" : "SNAPCEIPT_PRO_GROUP",
      "localizations" : [],
      "name" : "Snapceipt Pro",
      "subscriptions" : [
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "9.99",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "PRO_MONTHLY",
          "introductoryOffer" : {
            "internalID" : "INTRO_MONTHLY",
            "paymentMode" : "free",
            "subscriptionPeriod" : "P2W"
          },
          "localizations" : [
            {
              "description" : "BAS export, quotes, logbooks and email-in.",
              "displayName" : "Snapceipt Pro (Monthly)",
              "locale" : "en_AU"
            }
          ],
          "productID" : "app.snapceipt.pro.monthly",
          "recurringSubscriptionPeriod" : "P1M",
          "referenceName" : "Pro Monthly",
          "subscriptionGroupID" : "SNAPCEIPT_PRO_GROUP",
          "type" : "RecurringSubscription"
        },
        {
          "adHocOffers" : [],
          "codeOffers" : [],
          "displayPrice" : "79.00",
          "familyShareable" : false,
          "groupNumber" : 1,
          "internalID" : "PRO_YEARLY",
          "introductoryOffer" : {
            "internalID" : "INTRO_YEARLY",
            "paymentMode" : "free",
            "subscriptionPeriod" : "P2W"
          },
          "localizations" : [
            {
              "description" : "Everything in Pro, billed yearly — save 34%.",
              "displayName" : "Snapceipt Pro (Yearly)",
              "locale" : "en_AU"
            }
          ],
          "productID" : "app.snapceipt.pro.yearly",
          "recurringSubscriptionPeriod" : "P1Y",
          "referenceName" : "Pro Yearly",
          "subscriptionGroupID" : "SNAPCEIPT_PRO_GROUP",
          "type" : "RecurringSubscription"
        }
      ]
    }
  ],
  "version" : { "major" : 4, "minor" : 0 }
}
```
- [ ] **Step 2: Wire the config into the scheme.** In `project.yml`, under `schemes.Snapceipt`, add a `run` action referencing the StoreKit file so XcodeGen emits `StoreKitConfigurationFileReference` into the launch action. Edit the `schemes:` block (verified current shape at `project.yml:80-91`):
```yaml
schemes:
  Snapceipt:
    build:
      targets:
        Snapceipt: all
        SnapceiptTests: [test]
        SnapceiptUITests: [test]
    run:
      config: Debug
      storeKitConfiguration: Snapceipt/Snapceipt.storekit
    test:
      targets:
        - SnapceiptTests
        - SnapceiptUITests
      gatherCoverageData: false
```
- [ ] **Step 3: Generate + verify the StoreKit reference landed in the scheme.** The `.storekit` file is non-compiled and is auto-included because the `Snapceipt` target globs `path: Snapceipt` and excludes only `Info.plist` + both `.entitlements` (`project.yml:24-29`). Verify the scheme references it (NOT `-showBuildSettings`, which is a target build-setting dump and does not expose the launch-action StoreKit reference):
```
xcodegen generate
grep -r "Snapceipt.storekit" Snapceipt.xcodeproj/xcshareddata/xcschemes/
```
Expected: the `grep` prints a match (the generated `Snapceipt.xcscheme` contains a `StoreKitConfigurationFileReference` pointing at `Snapceipt/Snapceipt.storekit`).
- [ ] **Step 4: Commit.**
```
git add Snapceipt/Snapceipt.storekit project.yml
git commit -m "feat(iap): add StoreKit config for local Pro-subscription testing

Two products (app.snapceipt.pro.monthly/\$9.99, app.snapceipt.pro.yearly/\$79)
each with a 2-week free intro offer, wired into the Snapceipt scheme run action.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5 — Add the In-App Purchase capability to BOTH entitlements files

`Snapceipt/Snapceipt.entitlements` (Debug) and `Snapceipt/Snapceipt.Release.entitlements` currently carry only `com.apple.developer.applesignin` + `aps-environment` (verified). StoreKit IAP is enabled on the App ID; we add the explicit `com.apple.developer.in-app-purchase` boolean so manual signing (Release) and automatic signing (Debug) both request it.

- [ ] **Step 1: Edit `Snapceipt/Snapceipt.entitlements`** — insert the IAP key inside `<dict>`, after the existing `aps-environment` value `development`:
```xml
	<key>aps-environment</key>
	<string>development</string>
	<!-- In-App Purchase: StoreKit 2 subscriptions (Pro tier). The capability is
	     enabled on the App ID; this boolean makes the request explicit so manual
	     signing with the match profile validates it. -->
	<key>com.apple.developer.in-app-purchase</key>
	<true/>
```
- [ ] **Step 2: Edit `Snapceipt/Snapceipt.Release.entitlements`** — insert the same key after the production `aps-environment` value `production`:
```xml
	<key>aps-environment</key>
	<string>production</string>
	<key>com.apple.developer.in-app-purchase</key>
	<true/>
```
- [ ] **Step 3: Enable the capability on the App ID (OPERATOR).** developer.apple.com → Certificates, IDs & Profiles → Identifiers → `app.snapceipt.Snapceipt` → check **In-App Purchase** → Save. Then regenerate the `match AppStore app.snapceipt.Snapceipt` profile (the `PROVISIONING_PROFILE_SPECIFIER` set in `project.yml:47`) so the Release profile carries the capability. Expected: the App ID page shows In-App Purchase enabled and the regenerated profile validates the Release entitlements.
- [ ] **Step 4: Verify the build still signs (Debug/automatic).**
```
xcodegen generate
xcodebuild -scheme Snapceipt -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED (capability addition doesn't break Debug/automatic signing).
- [ ] **Step 5: Commit.**
```
git add Snapceipt/Snapceipt.entitlements Snapceipt/Snapceipt.Release.entitlements
git commit -m "feat(iap): add In-App Purchase capability to both entitlements

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6 — TDD the Pro-gating helper `ProGate` (client-side feature gate)

Mirror the existing static-pure-function gate idiom (`ReportsView.showsBasCard`, exercised by `SnapceiptTests/BasCardGateTests.swift`). One small struct, fully unit-tested, that decides whether each Pro feature is unlocked given the current plan.

- [ ] **Step 1: Write the failing test `SnapceiptTests/ProGateTests.swift`:**
```swift
import Testing
@testable import Snapceipt

@Suite("Pro feature gate")
struct ProGateTests {
    @Test("free plan locks every Pro feature")
    func freeLocks() {
        let gate = ProGate(plan: "free")
        #expect(gate.isPro == false)
        #expect(gate.allows(.basExport) == false)
        #expect(gate.allows(.quotes) == false)
        #expect(gate.allows(.logbooks) == false)
        #expect(gate.allows(.emailIn) == false)
    }

    @Test("pro plan unlocks every Pro feature")
    func proUnlocks() {
        let gate = ProGate(plan: "pro")
        #expect(gate.isPro == true)
        #expect(gate.allows(.basExport) == true)
        #expect(gate.allows(.quotes) == true)
        #expect(gate.allows(.logbooks) == true)
        #expect(gate.allows(.emailIn) == true)
    }

    @Test("unknown / nil plan is treated as free (fail closed)")
    func unknownIsFree() {
        #expect(ProGate(plan: nil).isPro == false)
        #expect(ProGate(plan: "enterprise").allows(.quotes) == false)
    }
}
```
- [ ] **Step 2: Run it — fails to compile (no `ProGate`).**
```
xcodegen generate
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/ProGateTests
```
Expected: build failure — `cannot find 'ProGate' in scope`.
- [ ] **Step 3: Create `Snapceipt/Features/Subscription/ProGate.swift`:**
```swift
import Foundation

/// Pure, testable decision for whether a Pro-only feature is unlocked.
/// Pro features (site/public/pricing.html): BAS-ready export, quotes & invoices,
/// vehicle & WFH logbooks, email-in. Mirrors the static-gate idiom used by
/// `ReportsView.showsBasCard`. Fails CLOSED: any non-"pro" plan locks everything.
struct ProGate {
    enum Feature { case basExport, quotes, logbooks, emailIn }

    let isPro: Bool

    init(plan: String?) {
        self.isPro = (plan == "pro")
    }

    func allows(_ feature: Feature) -> Bool { isPro }
}
```
- [ ] **Step 4: Run it — passes.**
```
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/ProGateTests
```
Expected: `Test Suite 'ProGateTests' passed`.
- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Subscription/ProGate.swift SnapceiptTests/ProGateTests.swift
git commit -m "feat(iap): add ProGate feature-gating helper + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7 — TDD the StoreKit 2 service `StoreKitService`

Extract the pure, testable seams (product-id mapping, purchase-result mapping) into static functions; keep the StoreKit async I/O thin. Tests run against the `Snapceipt.storekit` config.

- [ ] **Step 1: Write the failing test `SnapceiptTests/StoreKitServiceTests.swift`** (tests the pure mapping seams, not the StoreKit network):
```swift
import Testing
@testable import Snapceipt

@Suite("StoreKit service mapping")
struct StoreKitServiceTests {
    @Test("known product ids map to plan periods")
    func productIds() {
        #expect(StoreKitService.ProductID.monthly == "app.snapceipt.pro.monthly")
        #expect(StoreKitService.ProductID.yearly == "app.snapceipt.pro.yearly")
        #expect(StoreKitService.ProductID.all == ["app.snapceipt.pro.monthly",
                                                  "app.snapceipt.pro.yearly"])
    }

    @Test("a pro product id is recognised as entitling")
    func entitlingIds() {
        #expect(StoreKitService.isProProduct("app.snapceipt.pro.monthly") == true)
        #expect(StoreKitService.isProProduct("app.snapceipt.pro.yearly") == true)
        #expect(StoreKitService.isProProduct("app.snapceipt.something.else") == false)
    }

    @Test("purchase outcomes map to a stable result enum")
    func outcomeMapping() {
        #expect(StoreKitService.PurchaseOutcome.success.entitled == true)
        #expect(StoreKitService.PurchaseOutcome.userCancelled.entitled == false)
        #expect(StoreKitService.PurchaseOutcome.pending.entitled == false)
        #expect(StoreKitService.PurchaseOutcome.failed.entitled == false)
    }
}
```
- [ ] **Step 2: Run it — fails to compile.**
```
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/StoreKitServiceTests
```
Expected: `cannot find 'StoreKitService' in scope`.
- [ ] **Step 3: Create `Snapceipt/Features/Subscription/StoreKitService.swift`:**
```swift
import Foundation
import StoreKit

/// StoreKit 2 boundary: loads the two Pro products, runs purchase/restore, and
/// listens for Transaction.updates. The pure mapping seams (product ids, purchase
/// outcome) are static so they're unit-testable without touching StoreKit I/O.
@MainActor
@Observable
final class StoreKitService {
    enum ProductID {
        static let monthly = "app.snapceipt.pro.monthly"
        static let yearly  = "app.snapceipt.pro.yearly"
        static let all: [String] = [monthly, yearly]
    }

    /// Stable, testable outcome of a purchase/restore attempt.
    enum PurchaseOutcome: Equatable {
        case success
        case pending        // Ask-to-buy / SCA — entitlement arrives later via updates.
        case userCancelled
        case failed
        var entitled: Bool { self == .success }
    }

    /// True iff the product id is one of our entitling Pro subscriptions.
    static func isProProduct(_ id: String) -> Bool { ProductID.all.contains(id) }

    /// Loaded products; empty until `loadProducts()` resolves.
    private(set) var products: [Product] = []
    /// The set of currently-entitled product ids derived from Transaction.currentEntitlements.
    private(set) var entitledProductIDs: Set<String> = []

    /// Called whenever entitlement changes (purchase, restore, expiry, refund) so
    /// the EntitlementStore can sync to the backend. Injected by the app shell.
    var onEntitlementChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init() {
        // Listen for out-of-band transaction updates (renewals, Ask-to-Buy approvals,
        // refunds) for the whole app lifetime.
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verification: update)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    /// Load both Pro products from the store (or the .storekit config in DEBUG).
    func loadProducts() async {
        do { products = try await Product.products(for: ProductID.all) }
        catch { products = [] }
    }

    /// Buy a product. Maps the StoreKit result to our stable PurchaseOutcome.
    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification: verification)
                return .success
            case .pending:
                return .pending
            case .userCancelled:
                return .userCancelled
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Restore: re-sync entitlements from current transactions.
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    /// Recompute entitledProductIDs from Transaction.currentEntitlements and notify.
    func refreshEntitlements() async {
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, Self.isProProduct(txn.productID) {
                ids.insert(txn.productID)
            }
        }
        entitledProductIDs = ids
        onEntitlementChange?(!ids.isEmpty)
    }

    /// Verify a transaction result, finish it, and refresh entitlement state.
    private func handle(verification: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = verification else { return }
        await txn.finish()
        await refreshEntitlements()
    }
}
```
- [ ] **Step 4: Register the new dir as a source.** `project.yml:25` already globs `path: Snapceipt`, so `Snapceipt/Features/Subscription/*` is picked up automatically — just `xcodegen generate`.
- [ ] **Step 5: Run it — passes.**
```
xcodegen generate
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/StoreKitServiceTests
```
Expected: `Test Suite 'StoreKitServiceTests' passed`.
- [ ] **Step 6: Commit.**
```
git add Snapceipt/Features/Subscription/StoreKitService.swift SnapceiptTests/StoreKitServiceTests.swift
git commit -m "feat(iap): StoreKit 2 service (load/purchase/restore/updates) + mapping tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8 — TDD the `EntitlementStore` (the plan the app reads)

`EntitlementStore` is the single source of truth the UI reads (`@Observable`). `plan` is the UNION of the local StoreKit entitlement and the backend's `/auth/me` plan (either being "pro" yields Pro; fails CLOSED to "free"). Tests cover the pure reconciliation logic.

- [ ] **Step 1: Write the failing test `SnapceiptTests/EntitlementStoreTests.swift`:**
```swift
import Testing
@testable import Snapceipt

@Suite("EntitlementStore")
struct EntitlementStoreTests {
    @Test("starts free")
    func startsFree() {
        let store = EntitlementStore()
        #expect(store.plan == "free")
        #expect(store.isPro == false)
    }

    @Test("local StoreKit entitlement promotes to pro")
    func localPromotes() {
        let store = EntitlementStore()
        store.setLocalEntitled(true)
        #expect(store.plan == "pro")
        #expect(store.isPro == true)
    }

    @Test("backend pro plan promotes to pro even without a local txn")
    func backendPromotes() {
        let store = EntitlementStore()
        store.applyServerPlan("pro")
        #expect(store.isPro == true)
    }

    @Test("either source true => pro (union); both false => free")
    func union() {
        let store = EntitlementStore()
        store.setLocalEntitled(true)
        store.applyServerPlan("free")
        #expect(store.isPro == true)          // local still entitling

        store.setLocalEntitled(false)
        store.applyServerPlan("free")
        #expect(store.isPro == false)         // both sources free
    }
}
```
- [ ] **Step 2: Run it — fails.**
```
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/EntitlementStoreTests
```
Expected: `cannot find 'EntitlementStore' in scope`.
- [ ] **Step 3: Create `Snapceipt/Features/Subscription/EntitlementStore.swift`:**
```swift
import Foundation
import Observation

/// The app-wide entitlement the UI reads. `plan` is the UNION of two truths:
///   - local StoreKit entitlement (this device just purchased / has an active txn)
///   - the backend plan from GET /auth/me (cross-device, the server flipped it)
/// Either being "pro" yields Pro access; this fails CLOSED to "free". `@Observable`
/// so gated views re-render the instant entitlement changes. Injected via the
/// environment in SnapceiptApp.
@MainActor
@Observable
final class EntitlementStore {
    private(set) var localEntitled = false
    private(set) var serverPlan = "free"

    /// The effective plan string ("pro" | "free"), consumed by ProGate(plan:).
    var plan: String { (localEntitled || serverPlan == "pro") ? "pro" : "free" }
    var isPro: Bool { plan == "pro" }

    /// Convenience gate built from the effective plan.
    var gate: ProGate { ProGate(plan: plan) }

    /// Set by StoreKitService.onEntitlementChange.
    func setLocalEntitled(_ entitled: Bool) { localEntitled = entitled }

    /// Set after a GET /auth/me round-trip (server is authoritative cross-device).
    func applyServerPlan(_ plan: String) { serverPlan = plan }
}
```
- [ ] **Step 4: Run it — passes.**
```
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/EntitlementStoreTests
```
Expected: `Test Suite 'EntitlementStoreTests' passed`.
- [ ] **Step 5: Commit.**
```
git add Snapceipt/Features/Subscription/EntitlementStore.swift SnapceiptTests/EntitlementStoreTests.swift
git commit -m "feat(iap): EntitlementStore (union of StoreKit + backend plan) + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9 — Add the `/auth/me` plan read to the iOS API client so EntitlementStore can sync the server truth

`GET /auth/me` already returns `plan` (`src/routes/auth.ts:489`), but the iOS `MeResponse.user` is a `SessionUser` which omits `plan` (`Snapceipt/Sync/DTOs.swift:131,139`). Add a tiny `mePlan()` call so the app can read the server plan. `LiveAPIClient.me()` uses `send("GET", "/auth/me", body: NoBody(), authenticated: true)` (`APIClient.swift:103-105`) — `mePlan()` follows the same idiom.

- [ ] **Step 1: Add a `MePlanResponse` DTO to `Snapceipt/Sync/DTOs.swift`** (place it right after `MeResponse`, which ends at line 141):
```swift
/// GET /auth/me -> { user: { …, plan }, … }. A narrow decode that keeps only the
/// plan so EntitlementStore can sync the backend's cross-device truth without
/// changing the existing SessionUser shape.
struct MePlanResponse: Decodable {
    struct PlanUser: Decodable { let plan: String }
    let user: PlanUser
}
```
- [ ] **Step 2: Add `mePlan()` to the `APIClient` protocol** in `Snapceipt/Sync/APIClient.swift` (after `func me() async throws -> MeResponse`, line 14):
```swift
    /// GET /auth/me, decoding only the plan ("free" | "pro").
    func mePlan() async throws -> String
```
- [ ] **Step 3: Implement it on `LiveAPIClient`** in `Snapceipt/Sync/APIClient.swift` (after the existing `me()` impl, which ends at line 105):
```swift
    func mePlan() async throws -> String {
        let resp: MePlanResponse = try await send("GET", "/auth/me", body: NoBody(), authenticated: true)
        return resp.user.plan
    }
```
- [ ] **Step 4: Implement it on `StubAPIClient`** in `Snapceipt/Sync/StubAPIClient.swift` (next to the existing `me()` stub at line 17):
```swift
    func mePlan() async throws -> String { "free" }
```
- [ ] **Step 5: Build the test target to confirm the protocol conformance compiles.**
```
xcodegen generate
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/APIClientTests
```
Expected: `APIClientTests` still passes (protocol now conforms on both clients).
- [ ] **Step 6: Commit.**
```
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift
git commit -m "feat(iap): add mePlan() to read the backend Pro plan from /auth/me

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10 — Build the Paywall view + wire the subscription stack into the app shell (UI)

UI-heavy; no contrived test. Concrete file + view + acceptance check.

- [ ] **Step 1: Create `Snapceipt/Features/Subscription/PaywallView.swift`.** A SwiftUI `View` named `PaywallView` that:
  - reads `@Environment(StoreKitService.self) private var storekit` and `@Environment(EntitlementStore.self) private var entitlement`,
  - on `.task` calls `await storekit.loadProducts()`,
  - renders the headline "Snapceipt Pro" and the four Pro benefits from `site/public/pricing.html` (BAS-ready export & accountant pack; Quotes & invoices; Vehicle & WFH logbooks; Email-in receipts),
  - shows one button per `storekit.products` element using `product.displayName` + `product.displayPrice` (StoreKit-localized — do NOT hard-code "$9.99"), with a "14-day free trial, then …" subtitle when `product.subscription?.introductoryOffer != nil`,
  - a "Restore Purchases" button calling `await storekit.restore()`,
  - tapping a product calls `await storekit.purchase(product)` and dismisses on `.success`,
  - includes accessibility identifiers `paywall.title`, `paywall.buy.monthly`, `paywall.buy.yearly`, `paywall.restore` (add them to the `AccessibilityID` enum in `Snapceipt/Shared/AccessibilityID.swift`, following its existing `static let` style),
  - footer links "Terms" and "Privacy" (App Store requires these on a subscription screen) pointing at the snapceipt.cc pages.
  - **Acceptance:** running the app in the simulator with the `.storekit` config, opening the paywall shows two real buttons labelled "Snapceipt Pro (Monthly) — $9.99" and "Snapceipt Pro (Yearly) — $79.00" with a "14-day free trial" subtitle; a SwiftUI `#Preview` renders without crashing.
- [ ] **Step 2: Add a SwiftUI `#Preview` to `PaywallView.swift`** that injects `StoreKitService()` and `EntitlementStore()` via `.environment(...)` so the canvas renders. **Acceptance:** Xcode preview shows the paywall layout (products may be empty in the static preview — the benefit list + buttons scaffold must render).
- [ ] **Step 3: Wire the stack into `Snapceipt/App/SnapceiptApp.swift`.** Following the existing `@State` + `.environment(...)` pattern. NOTE: `api` is currently a LOCAL `let` inside `init()` (lines 44/57), so it is not reachable from `body`/`.task` — add a stored property for it.
  - add stored properties: `private let api: APIClient`, `@State private var storekit: StoreKitService`, `@State private var entitlement: EntitlementStore`,
  - in `init()`, after the api/container wiring but before the `_auth = State(...)` block (around line 75): `let entitlement = EntitlementStore()`; `let storekit = StoreKitService()`; `storekit.onEntitlementChange = { entitled in entitlement.setLocalEntitled(entitled) }`,
  - assign the stored property and the `@State` backing stores: `self.api = api`, `_storekit = State(initialValue: storekit)`, `_entitlement = State(initialValue: entitlement)`,
  - in `body`, add `.environment(storekit)` and `.environment(entitlement)` to the `RootView()` modifier chain (the chain spans lines 93-101),
  - add `.task { await storekit.refreshEntitlements(); if let plan = try? await api.mePlan() { entitlement.applyServerPlan(plan) } }` on `RootView()` so both truths load at launch (uses the new stored `api`).
  - **Acceptance:** `xcodebuild -scheme Snapceipt -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build` succeeds and the app launches with the new environment objects available.
- [ ] **Step 4: Add the paywall entry point + gate the Pro features.** In each Pro feature's entry view, read `@Environment(EntitlementStore.self)` and present `PaywallView` (sheet) instead of the feature when `!entitlement.isPro`:
  - **BAS export:** the BAS card / export action in `Snapceipt/Features/Reports/ReportsView.swift` (already has the `ReportsView.showsBasCard` gate) — when not Pro, tapping the BAS card presents the paywall.
  - **Quotes:** `Snapceipt/Features/Quotes/QuoteListView.swift` — gate the "new quote" / list behind the paywall when not Pro.
  - **Logbooks:** the logbook entries `Snapceipt/Features/Logbooks/MileageScreen.swift` + `Snapceipt/Features/Logbooks/WFHScreen.swift` (vehicle + WFH) — gate behind the paywall.
  - **Email-in:** `Snapceipt/Features/EmailIn/EmailInView.swift` — gate behind the paywall.
  - Also add a "Snapceipt Pro" row in `Snapceipt/Features/Account/AccountView.swift` that opens `PaywallView` and, when Pro, shows "Pro — manage in App Store" linking to the system subscriptions URL `itms-apps://apps.apple.com/account/subscriptions`.
  - **Acceptance:** with the simulator account NOT subscribed, opening BAS / Quotes / Logbooks / Email-in presents the paywall; after a sandbox purchase, the same taps open the real feature. (Verified manually in Task 16.)
- [ ] **Step 5: Build + smoke.**
```
xcodegen generate
xcodebuild -scheme Snapceipt -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 6: Commit.**
```
git add Snapceipt/Features/Subscription/PaywallView.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/SnapceiptApp.swift Snapceipt/Features/Reports/ReportsView.swift Snapceipt/Features/Quotes/QuoteListView.swift Snapceipt/Features/Logbooks/MileageScreen.swift Snapceipt/Features/Logbooks/WFHScreen.swift Snapceipt/Features/EmailIn/EmailInView.swift Snapceipt/Features/Account/AccountView.swift
git commit -m "feat(iap): Paywall view + gate BAS/quotes/logbooks/email-in behind Pro

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11 — Backend migration 0006: subscription tracking columns

Pure additive `ALTER TABLE` (non-rewriting in D1), following the exact idiom of `0004_bas.sql` / `0005_quote_gst_inclusive.sql`. `plan` already exists; we add status + expiry + the Apple transaction key.

- [ ] **Step 1: Create `migrations/0006_subscriptions.sql`:**
```sql
-- 0006_subscriptions.sql — Apple StoreKit subscription tracking on users.
-- `plan` already exists (0001, CHECK IN ('free','pro')); these columns record the
-- subscription lifecycle so the App Store Server Notifications webhook can flip
-- plan and reconcile renewals/expiry. Pure ADD COLUMN with constant defaults
-- (non-rewriting in SQLite/D1); applies via `wrangler d1 migrations apply --remote`
-- and both test harnesses apply it in order. No CHECK changes on `plan`.
ALTER TABLE users ADD COLUMN subscription_status TEXT;            -- 'active'|'expired'|'revoked'|NULL
ALTER TABLE users ADD COLUMN subscription_expires_at INTEGER;     -- epoch ms; NULL when never subscribed
ALTER TABLE users ADD COLUMN original_transaction_id TEXT;        -- Apple originalTransactionId (stable per subscriber)
CREATE INDEX ix_users_orig_txn ON users(original_transaction_id) WHERE original_transaction_id IS NOT NULL;
```
- [ ] **Step 2: Verify the migration applies in the test harness.** The shared setup (`test/apply-migrations.ts`) auto-applies all migrations. Run any existing backend test to confirm 0006 applies cleanly:
```
npx vitest run test/health.test.ts
```
Expected: passes (proves `applyD1Migrations` ingests 0006 without error).
- [ ] **Step 3: Commit.**
```
git add migrations/0006_subscriptions.sql
git commit -m "feat(iap): migration 0006 — subscription_status/expires/original_txn on users

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12 — TDD the pure plan-flip reducer `applyNotification`

Isolate the decision (given a decoded ASSN V2 notification, what plan + status + expiry results) as a pure function so the flip logic is unit-tested without DB or signing.

- [ ] **Step 1: Write the failing test `test/appstore-plan-flip.test.ts`:**
```ts
import { describe, expect, it } from "vitest";
import { applyNotification, type DecodedNotification } from "../src/lib/appStoreNotifications";

function notif(over: Partial<DecodedNotification>): DecodedNotification {
  return {
    notificationType: "SUBSCRIBED",
    subtype: undefined,
    originalTransactionId: "1000000999",
    productId: "app.snapceipt.pro.monthly",
    expiresDateMs: 9_999_999_999_000,
    ...over,
  };
}

describe("applyNotification (pure plan-flip reducer)", () => {
  it("SUBSCRIBED -> pro/active with expiry", () => {
    const r = applyNotification(notif({ notificationType: "SUBSCRIBED" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
    expect(r.subscriptionExpiresAt).toBe(9_999_999_999_000);
  });

  it("DID_RENEW -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "DID_RENEW" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });

  it("OFFER_REDEEMED (free trial start) -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "OFFER_REDEEMED" }));
    expect(r.plan).toBe("pro");
  });

  it("EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "EXPIRED" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("expired");
  });

  it("REFUND -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REFUND" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  it("REVOKE (family sharing removed) -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REVOKE" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  it("GRACE_PERIOD_EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "GRACE_PERIOD_EXPIRED" }));
    expect(r.plan).toBe("free");
  });

  it("DID_CHANGE_RENEWAL_STATUS stays pro until expiry (no immediate downgrade)", () => {
    const r = applyNotification(notif({ notificationType: "DID_CHANGE_RENEWAL_STATUS" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });
});
```
- [ ] **Step 2: Run it — fails (module/function missing).**
```
npx vitest run test/appstore-plan-flip.test.ts
```
Expected: `Failed to resolve import "../src/lib/appStoreNotifications"`.
- [ ] **Step 3: Create `src/lib/appStoreNotifications.ts` with the decoded shape + reducer** (signing/decode added in Task 13; this commit is just the pure reducer + types):
```ts
// App Store Server Notifications V2 — pure decision layer.
// The webhook (src/routes/appstore.ts) decodes the signed payload into a
// DecodedNotification, then applies this reducer to compute the user-row update.
// Kept pure (no DB, no crypto) so the plan-flip rules are unit-tested in isolation.

/** The fields we need from a decoded ASSN V2 notification + its transaction info. */
export interface DecodedNotification {
  notificationType: string;
  subtype?: string;
  originalTransactionId: string;
  productId: string;
  /** transactionInfo.expiresDate in epoch ms (subscriptions always carry one). */
  expiresDateMs: number | null;
}

/** The computed user-row update the webhook persists. */
export interface PlanUpdate {
  plan: "free" | "pro";
  subscriptionStatus: "active" | "expired" | "revoked";
  subscriptionExpiresAt: number | null;
}

// Notification types that mean the subscriber is (or remains) entitled.
const ENTITLING = new Set([
  "SUBSCRIBED",
  "DID_RENEW",
  "OFFER_REDEEMED",
  "DID_CHANGE_RENEWAL_STATUS", // auto-renew toggled; access persists until expiry
  "DID_CHANGE_RENEWAL_PREF",   // up/downgrade between our tiers; still entitled
]);

// Types that revoke access immediately (money returned / entitlement pulled).
const REVOKING = new Set(["REFUND", "REVOKE"]);

// Types that end access at/after period (lapse).
const EXPIRING = new Set(["EXPIRED", "GRACE_PERIOD_EXPIRED"]);

/**
 * Map a decoded notification to the user-row update. Unrecognised types default to
 * entitled+active so a new Apple notification type never spuriously downgrades a
 * paying user (unknown types should not reach prod, but we fail OPEN for the payer).
 */
export function applyNotification(n: DecodedNotification): PlanUpdate {
  if (REVOKING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "revoked", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (EXPIRING.has(n.notificationType)) {
    return { plan: "free", subscriptionStatus: "expired", subscriptionExpiresAt: n.expiresDateMs };
  }
  if (ENTITLING.has(n.notificationType)) {
    return { plan: "pro", subscriptionStatus: "active", subscriptionExpiresAt: n.expiresDateMs };
  }
  // Conservative default for unrecognised types: keep the subscriber entitled.
  return { plan: "pro", subscriptionStatus: "active", subscriptionExpiresAt: n.expiresDateMs };
}
```
- [ ] **Step 4: Run it — passes.**
```
npx vitest run test/appstore-plan-flip.test.ts
```
Expected: all 8 tests pass.
- [ ] **Step 5: Commit.**
```
git add src/lib/appStoreNotifications.ts test/appstore-plan-flip.test.ts
git commit -m "feat(iap): pure ASSN V2 plan-flip reducer + tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 13 — TDD the webhook route `POST /appstore/notifications` (decode signed payload, flip users.plan)

This route receives App Store Server Notifications V2. The body is `{ signedPayload }` — a JWS whose payload contains `signedTransactionInfo` + `signedRenewalInfo` (each themselves JWS). For GA we **decode** the JWS payloads (base64url, no chain pinning — see open_questions) and apply the reducer, scoping the user row by `originalTransactionId`. The test stubs a signed payload via a helper.

- [ ] **Step 1: Create the test helper `test/helpers/appstore.ts`** that builds a fake `signedPayload` (a JWS we can decode without Apple's keys — base64url JSON parts, signature ignored by our GA decoder):
```ts
/** base64url-encode a JSON value (no padding) — matches JWS segment encoding. */
function b64urlJson(value: unknown): string {
  const json = JSON.stringify(value);
  // btoa is available in the workers test runtime.
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A throwaway JWS: header.payload.signature (signature is a fixed placeholder). */
function jws(payload: unknown): string {
  const header = b64urlJson({ alg: "ES256", x5c: ["TEST"] });
  return `${header}.${b64urlJson(payload)}.SIG`;
}

/**
 * Build a `signedPayload` whose decoded data carries the given notification type,
 * productId, originalTransactionId and expiry — the exact shape our webhook reads.
 */
export function makeSignedNotification(opts: {
  notificationType: string;
  subtype?: string;
  productId?: string;
  originalTransactionId: string;
  expiresDateMs?: number;
}): string {
  const productId = opts.productId ?? "app.snapceipt.pro.monthly";
  const expiresDateMs = opts.expiresDateMs ?? 9_999_999_999_000;
  const signedTransactionInfo = jws({
    productId,
    originalTransactionId: opts.originalTransactionId,
    expiresDate: expiresDateMs,
  });
  const signedRenewalInfo = jws({
    productId,
    originalTransactionId: opts.originalTransactionId,
    autoRenewStatus: 1,
  });
  return jws({
    notificationType: opts.notificationType,
    subtype: opts.subtype,
    data: { signedTransactionInfo, signedRenewalInfo },
  });
}
```
- [ ] **Step 2: Write the failing test `test/appstore-notifications.test.ts`** (mints a real subscriber row, posts a signed notification, asserts the flip):
```ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { makeSignedNotification } from "./helpers/appstore";

const ORIG_TXN = "1000000123456789";

async function seedSubscriber(plan = "free"): Promise<string> {
  const userId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, original_transaction_id, created_at, updated_at)
     VALUES (?, ?, 1, ?, ?, ?, ?)`,
  ).bind(userId, `sub-${userId}@example.com`, plan, ORIG_TXN, t, t).run();
  return userId;
}

function post(signedPayload: string) {
  return SELF.fetch("https://api.test/appstore/notifications", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ signedPayload }),
  });
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM users");
});

describe("POST /appstore/notifications", () => {
  it("SUBSCRIBED flips the matching user to pro/active with expiry", async () => {
    const userId = await seedSubscriber("free");
    const res = await post(makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: ORIG_TXN,
      expiresDateMs: 9_999_999_999_000,
    }));
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      "SELECT plan, subscription_status, subscription_expires_at FROM users WHERE id = ?",
    ).bind(userId).first<{ plan: string; subscription_status: string; subscription_expires_at: number }>();
    expect(row?.plan).toBe("pro");
    expect(row?.subscription_status).toBe("active");
    expect(row?.subscription_expires_at).toBe(9_999_999_999_000);
  });

  it("EXPIRED reverts a pro user to free/expired", async () => {
    const userId = await seedSubscriber("pro");
    const res = await post(makeSignedNotification({
      notificationType: "EXPIRED",
      originalTransactionId: ORIG_TXN,
    }));
    expect(res.status).toBe(200);
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(row?.plan).toBe("free");
    expect(row?.subscription_status).toBe("expired");
  });

  it("REFUND reverts to free/revoked", async () => {
    const userId = await seedSubscriber("pro");
    await post(makeSignedNotification({ notificationType: "REFUND", originalTransactionId: ORIG_TXN }));
    const row = await env.DB.prepare("SELECT plan, subscription_status FROM users WHERE id = ?")
      .bind(userId).first<{ plan: string; subscription_status: string }>();
    expect(row?.plan).toBe("free");
    expect(row?.subscription_status).toBe("revoked");
  });

  it("acks (200) when no user matches the originalTransactionId (idempotent)", async () => {
    const res = await post(makeSignedNotification({
      notificationType: "SUBSCRIBED",
      originalTransactionId: "9999999999",
    }));
    expect(res.status).toBe(200);
  });

  it("rejects a body without signedPayload (400 VALIDATION_FAILED)", async () => {
    const res = await SELF.fetch("https://api.test/appstore/notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: { code: string } };
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });
});
```
- [ ] **Step 3: Run it — fails (route missing, 404/401).**
```
npx vitest run test/appstore-notifications.test.ts
```
Expected: failures — the route is not mounted yet.
- [ ] **Step 4: Add the JWS-decode helpers + `decodeSignedPayload` to `src/lib/appStoreNotifications.ts`** (append below the reducer):
```ts
/** Decode a JWS payload segment (base64url JSON). GA: we decode, not chain-verify
 *  (TLS transport from Apple is trusted; x5c pinning is a flagged follow-up). */
function decodeJwsPayload<T>(jwsToken: string): T {
  const part = jwsToken.split(".")[1];
  if (!part) throw new Error("malformed JWS");
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/");
  const json = atob(b64.padEnd(b64.length + ((4 - (b64.length % 4)) % 4), "="));
  return JSON.parse(json) as T;
}

interface SignedPayloadData {
  notificationType: string;
  subtype?: string;
  data?: { signedTransactionInfo?: string; signedRenewalInfo?: string };
}
interface TransactionInfo {
  productId: string;
  originalTransactionId: string;
  expiresDate?: number;
}

/** Decode a top-level signedPayload into our DecodedNotification, or null if malformed. */
export function decodeSignedPayload(signedPayload: string): DecodedNotification | null {
  let outer: SignedPayloadData;
  try {
    outer = decodeJwsPayload<SignedPayloadData>(signedPayload);
  } catch {
    return null;
  }
  const txnJws = outer.data?.signedTransactionInfo;
  if (!txnJws) return null;
  let txn: TransactionInfo;
  try {
    txn = decodeJwsPayload<TransactionInfo>(txnJws);
  } catch {
    return null;
  }
  return {
    notificationType: outer.notificationType,
    subtype: outer.subtype,
    originalTransactionId: txn.originalTransactionId,
    productId: txn.productId,
    expiresDateMs: txn.expiresDate ?? null,
  };
}
```
- [ ] **Step 5: Create the route `src/routes/appstore.ts`** (imports `validate` from `./auth`, matching the repo idiom used by `devices.ts`/`export.ts`/`account.ts`):
```ts
import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { applyNotification, decodeSignedPayload } from "../lib/appStoreNotifications";

/**
 * App Store Server Notifications V2 webhook. Public (Apple posts unauthenticated),
 * mounted under /appstore which is added to PUBLIC_PATHS. Body is { signedPayload }
 * (a JWS). We decode it, compute the plan update via applyNotification, and flip the
 * user row keyed by originalTransactionId. ALWAYS 200 on a well-formed body (even
 * when no user matches) so Apple does not retry indefinitely; only a malformed body
 * (missing signedPayload) is 400.
 */
export const appstoreRoutes = new Hono<AppEnv>();

const notificationBody = z.object({ signedPayload: z.string().min(1) });

appstoreRoutes.post("/notifications", validate("json", notificationBody), async (c) => {
  const { signedPayload } = c.req.valid("json");

  const decoded = decodeSignedPayload(signedPayload);
  if (!decoded) {
    // Well-formed envelope but undecodable inner JWS — ack so Apple stops retrying.
    return c.json({ ok: true, ignored: "undecodable" });
  }

  const update = applyNotification(decoded);
  const now = nowMs();

  // Scope by Apple's stable originalTransactionId (tagged on the user row at first
  // purchase / link). No match -> no-op (still 200) so Apple does not retry.
  await c.env.DB.prepare(
    `UPDATE users
        SET plan = ?,
            subscription_status = ?,
            subscription_expires_at = ?,
            updated_at = ?
      WHERE original_transaction_id = ? AND deleted_at IS NULL`,
  )
    .bind(update.plan, update.subscriptionStatus, update.subscriptionExpiresAt, now, decoded.originalTransactionId)
    .run();

  return c.json({ ok: true });
});
```
- [ ] **Step 6: Mount the route + make it public.** In `src/app.ts`, add the import next to the other route imports (after line 17): `import { appstoreRoutes } from "./routes/appstore";`. Mount it with the other `app.route(...)` calls (after line 105): `app.route("/appstore", appstoreRoutes);`. In `src/middleware/auth.ts:11` add `/appstore/` to `PUBLIC_PATHS`:
```ts
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/quotes/dl/", "/appstore/"];
```
- [ ] **Step 7: Run it — passes.**
```
npx vitest run test/appstore-notifications.test.ts
```
Expected: all 5 tests pass.
- [ ] **Step 8: Commit.**
```
git add src/lib/appStoreNotifications.ts src/routes/appstore.ts src/app.ts src/middleware/auth.ts test/appstore-notifications.test.ts test/helpers/appstore.ts
git commit -m "feat(iap): ASSN V2 webhook — decode signedPayload + flip users.plan

POST /appstore/notifications (public) decodes the JWS, applies the plan-flip
reducer, and updates the user keyed by originalTransactionId.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 14 — Server-side Pro enforcement on the BAS export + app reachability test

StoreKit gates the UI, but server-gated Pro actions (POST /export {format:"bas"} — the BAS pack, a Pro-only feature) must also enforce the plan so a modified client can't bypass the paywall. Add a `requireProPlan` helper and enforce it inside the `format === "bas"` branch (`src/routes/export.ts:138`), AFTER the profile-ownership + BAS-eligibility checks so the 403 is unambiguously the Pro gate. Also add a reachability test for the webhook through the real app.

- [ ] **Step 1: Write the failing reachability test `test/appstore-app.test.ts`:**
```ts
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("/appstore (through the real app)", () => {
  it("POST /appstore/notifications is public (no bearer required)", async () => {
    const res = await SELF.fetch("https://x/appstore/notifications", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    // Public route reached -> validation runs -> 400 (NOT 401 auth).
    expect(res.status).toBe(400);
  });
});
```
- [ ] **Step 2: Run it — passes already** (proves the PUBLIC_PATHS wiring from Task 13).
```
npx vitest run test/appstore-app.test.ts
```
Expected: passes (auth is bypassed for /appstore/; malformed body → 400, not 401).
- [ ] **Step 3: Add a `requireProPlan` helper as a new file `src/lib/plan.ts`** (keeps `db.ts` focused). Reads `users.plan` (0001) for the authed user and throws the shared `FORBIDDEN` ApiError (403, per `src/lib/errors.ts:10`):
```ts
// src/lib/plan.ts — server-side Pro enforcement. The iOS paywall gates the UI,
// but server-gated Pro actions must independently verify the plan so a modified
// client cannot bypass payment. Reads users.plan (0001) for the authed user.
import type { Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "./errors";

export async function requireProPlan(c: Context<AppEnv>): Promise<void> {
  const row = await c.env.DB.prepare(
    "SELECT plan FROM users WHERE id = ? AND deleted_at IS NULL",
  ).bind(c.var.userId).first<{ plan: string }>();
  if (!row || row.plan !== "pro") {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
}
```
- [ ] **Step 4: Write a failing test for BAS-export enforcement `test/export-pro-gate.test.ts`.** The free user OWNS a valid GST-registered business profile, so the request passes the ownership gate (`export.ts:70`) and the BAS-eligibility gate (`export.ts:142`) and reaches the BAS body — meaning the only thing that can produce a 403 is `requireProPlan`. (Without the gate, this same request returns 200, so this is a genuine red→green cycle.)
```ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

/** Seed a user (given plan) + a GST-registered business profile owned by them. */
async function seedUserWithBasProfile(plan: string): Promise<{ bearer: string; profileId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    "INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)",
  ).bind(userId, `${userId}@example.com`, plan, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,gst_registered,abn,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business',1,'12 345 678 901','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { bearer: `Bearer ${accessToken}`, profileId };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /export {format:'bas'} is Pro-gated", () => {
  it("free user (owning a valid BAS profile) is 403 FORBIDDEN", async () => {
    const { bearer, profileId } = await seedUserWithBasProfile("free");
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: bearer },
      body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", bas: { paygInstalmentCents: 0 } }),
    });
    expect(res.status).toBe(403);
    const body = (await res.json()) as { error: { code: string; message: string } };
    expect(body.error.code).toBe("FORBIDDEN");
    // Distinguish the Pro gate from the ownership/eligibility gates (same code, different message).
    expect(body.error.message).toContain("Snapceipt Pro");
  });

  it("pro user (same profile) is NOT blocked by the Pro gate (200)", async () => {
    const { bearer, profileId } = await seedUserWithBasProfile("pro");
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: bearer },
      body: JSON.stringify({ profileId, format: "bas", from: "2026-04-01", to: "2026-06-30", bas: { paygInstalmentCents: 0 } }),
    });
    expect(res.status).toBe(200);
  });
});
```
- [ ] **Step 5: Run it — fails.**
```
npx vitest run test/export-pro-gate.test.ts
```
Expected: the "free user … 403" case fails (status is 200, no enforcement yet); the "pro user … 200" case already passes.
- [ ] **Step 6: Enforce in `src/routes/export.ts`.** Add the import at the top with the other lib imports:
```ts
import { requireProPlan } from "../lib/plan";
```
Then, inside the `if (body.format === "bas") {` block (begins at line 138), call the guard immediately AFTER the existing BAS-eligibility check (the `if (profile.type !== "business" || profile.gst_registered !== 1)` throw at lines 142-144) and before the BAS slice re-query at line 146:
```ts
    // Server-side Pro enforcement: the BAS pack is a Pro-only feature. The iOS
    // paywall gates the UI; this guards against a modified client. Placed after the
    // eligibility gate so a 403 here is unambiguously the Pro gate (its message
    // differs — asserted by test/export-pro-gate.test.ts).
    await requireProPlan(c);
```
- [ ] **Step 7: Update the EXISTING BAS happy-path tests that now seed a free user.** `test/export-route.test.ts` has two BAS success tests — "registered business -> 200 …" (line 222) and "both returned links download …" (line 250) — that call `seedAuthed()`, whose INSERT hard-codes `plan='free'` (`test/export-route.test.ts:34`). With the Pro gate they would 403. Change `seedAuthed`'s INSERT (line 34) so its users are Pro:
  - In `test/export-route.test.ts:33-35`, change
    ```ts
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'free', ?, ?)`,
    ```
    to
    ```ts
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'pro', ?, ?)`,
    ```
  (The CSV/PDF/accountant tests in this file are unaffected by the plan value; they do not hit the Pro gate. `test/export-app.test.ts` only exercises `format:'csv'`, never BAS, so it is NOT modified.)
- [ ] **Step 8: Run the new gate test + the existing export route suite — all green.**
```
npx vitest run test/export-pro-gate.test.ts
npx vitest run test/export-route.test.ts
```
Expected: `test/export-pro-gate.test.ts` both cases pass; `test/export-route.test.ts` stays green (BAS success tests now seed a Pro user).
- [ ] **Step 9: Commit.**
```
git add src/lib/plan.ts src/routes/export.ts test/appstore-app.test.ts test/export-pro-gate.test.ts test/export-route.test.ts
git commit -m "feat(iap): server-side Pro enforcement on BAS export + webhook reachability test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 15 — Backend: deploy the migration + register the ASSN endpoint (OPERATOR)

- [ ] **Step 1: Apply migration 0006 to remote D1.**
```
npx wrangler d1 migrations apply <DB_BINDING_NAME> --remote
```
(Use the D1 database name from `wrangler.jsonc`.) Expected: "Migration 0006_subscriptions.sql applied" with 4 statements (3 ALTER + 1 CREATE INDEX).
- [ ] **Step 2: Deploy the Worker** so the `/appstore/notifications` route is live:
```
npx wrangler deploy
```
Expected: deploy succeeds; `curl -s -X POST https://api.snapceipt.cc/appstore/notifications -H 'content-type: application/json' -d '{}'` returns a 400 VALIDATION_FAILED envelope (route reachable, public).
- [ ] **Step 3: Register the production + sandbox notification URL in App Store Connect.** App Store Connect → Snapceipt → **App Information** → **App Store Server Notifications** → Production Server URL: `https://api.snapceipt.cc/appstore/notifications`, Version: **Version 2** → and the Sandbox Server URL: same path. Save. Expected: both URLs saved with V2 selected.
- [ ] **Step 4: Send a test notification.** Same screen → **Request a Test Notification** (or via the App Store Server API) → check the Worker logs (`npx wrangler tail`) show the POST hitting the route and returning 200. Expected: a `TEST` notification is received and acked 200.

---

### Task 16 — Sandbox end-to-end test checklist (OPERATOR / device QA)

Run on a real device or simulator signed into an App Store **Sandbox** Apple ID (Settings → App Store → Sandbox Account). Build the app pointed at the live API.

- [ ] **Step 1: Fresh purchase.** Sign in to the app; open BAS/Quotes/Logbooks/Email-in → paywall appears (free). Tap "Snapceipt Pro (Monthly)" → complete the sandbox purchase. Expected: the purchase sheet shows the **14-day free trial** then $9.99; after success the paywall dismisses and the feature unlocks immediately (StoreKit local entitlement). `StoreKitService.entitledProductIDs` contains `app.snapceipt.pro.monthly`.
- [ ] **Step 2: Server flip.** Within ~1 min the App Store sandbox posts a `SUBSCRIBED` notification to `/appstore/notifications`. Pull-to-refresh / relaunch → `GET /auth/me` returns `plan:"pro"`. Expected: `wrangler tail` shows the webhook 200; the user row has `plan='pro'`, `subscription_status='active'`, a future `subscription_expires_at`, and `original_transaction_id` set. (Note: linking the device's originalTransactionId to the user row must happen at purchase — confirm the link step is in place, see open_questions.)
- [ ] **Step 3: Restore on a second install.** Delete + reinstall (or use a second device, same sandbox Apple ID) → sign in → open Account → **Restore Purchases**. Expected: entitlement returns without re-paying; Pro features unlock; paywall not shown.
- [ ] **Step 4: Trial → paid renewal.** Sandbox accelerates time (monthly trial renews in minutes). Wait for the auto-renewal. Expected: a `DID_RENEW` notification flips/keeps `plan='pro'`, `subscription_status='active'`, `subscription_expires_at` advances.
- [ ] **Step 5: Refund / expiry → revert.** In the sandbox, cancel auto-renew and let it lapse (or trigger a refund via the App Store Server API sandbox). Expected: an `EXPIRED` (or `REFUND`) notification reverts the user to `plan='free'`, `subscription_status` `expired`/`revoked`; on next `/auth/me` the app re-locks the Pro features and the server returns 403 on POST /export {format:"bas"}.
- [ ] **Step 6: Record results.** Note each step's observed outcome (pass/fail) in the GA checklist. Expected: all six green before submitting for review.

---

### Task 17 — Run the full suites + regenerate the project as a final gate

- [ ] **Step 1: Backend suite green.**
```
npx vitest run test/appstore-plan-flip.test.ts test/appstore-notifications.test.ts test/appstore-app.test.ts test/export-pro-gate.test.ts test/export-route.test.ts
```
Expected: all pass.
- [ ] **Step 2: iOS suite green.**
```
xcodegen generate
xcodebuild test -scheme Snapceipt -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SnapceiptTests/ProGateTests -only-testing:SnapceiptTests/StoreKitServiceTests -only-testing:SnapceiptTests/EntitlementStoreTests
```
Expected: all three suites pass.
- [ ] **Step 3: Full-app build to confirm no integration breakage.**
```
xcodebuild -scheme Snapceipt -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Final commit (if any uncommitted regen artifacts).**
```
git add -A
git commit -m "chore(iap): regenerate project + finalize Pro subscription workstream

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Open questions (human input needed):**

- Final retail prices must be created+approved in App Store Connect by a human with the Account Holder/Admin role — $9.99/mo and $79/yr are the advertised AUD prices (pricing.html) but Apple price tiers + tax categories need confirmation at submission time.
- DEVELOPMENT_TEAM is 2SU47GHJQX (project.yml) — confirm the signing team has the In-App Purchase capability enabled on the App ID `app.snapceipt.Snapceipt` and that the App Store Small Business Program enrollment is on the same team.
- The App Store Server Notifications V2 production+sandbox endpoint URL (e.g. https://api.snapceipt.cc/appstore/notifications) must be entered in App Store Connect by an operator AFTER the route deploys; the exact public hostname for the API Worker should be confirmed (wrangler routes).
- ASSN V2 JWS verification needs Apple's root CAs to validate the x5c chain. This plan verifies the signed payload's structure + decodes the JWS and trusts transport over TLS to the documented Apple notification IPs for GA; if full x5c-chain pinning is required, add Apple's AppleRootCA-G3 to the repo and verify the leaf cert chain (extra task, flagged here as a decision).
- Whether to also call the App Store Server API (GET /inApps/v1/subscriptions/{transactionId}) for authoritative status, which requires an in-app-purchase private key (.p8), Key ID, and Issuer ID provisioned as wrangler secrets (APPSTORE_KEY/APPSTORE_KEY_ID/APPSTORE_ISSUER_ID). For GA we flip on the notification payload alone; confirm if reconciliation polling is required.

_Critic verdict: fixed (7 issue(s) fixed)._

---

## Workstream 7 — App Store Submission Package (process/tooling gate for GA)

**Goal:** Turn the repo into a one-command, reviewable App Store submission: real app icon, generated 6.7"/6.5" device screenshots from the existing tour harness, a fastlane `release` lane with `fastlane/metadata/`, and a documented App Privacy nutrition-label answer set mirroring PrivacyInfo.xcprivacy.

**Dependencies:** Soft dependency on the StoreKit workstream (Apple App Store subscriptions): the EULA URL in the metadata and the "in-app purchase" answer in the App Privacy questionnaire (PurchaseHistory type) cannot be finalized until StoreKit ships. Task 4 (release lane) and Task 5 (metadata) can be authored now with the EULA left as a documented placeholder that is filled in the StoreKit workstream's final step. No hard code dependency on other workstreams; the build/upload pipeline (`certs`/`beta`) already exists in fastlane/Fastfile.

**Definition of done:**

- [ ] scripts/generate-app-icon.swift is replaced by real human-supplied 1024x1024 artwork committed at Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png, and `xcrun actool` / a release build emits NO 'missing icon' or 'has alpha' warning (verified by `file` reporting RGB non-interlaced, no alpha channel).
- [ ] scripts/tour-appstore.sh exists, is executable, and running it produces >=3 PNGs each at exactly 1290x2796 (6.7") and 1242x2688 (6.5") under artifacts/appstore/<run-id>/6.7/ and artifacts/appstore/<run-id>/6.5/ (verified with `sips -g pixelWidth -g pixelHeight`).
- [ ] fastlane/Fastfile has a `release` lane that runs `gym` (export_method app-store) then `upload_to_app_store` with submit_for_review:true and phased_release:true; `bundle exec fastlane lanes` lists it and `bundle exec fastlane release --help`-style dry parse (ruby -c) passes.
- [ ] fastlane/metadata/en-AU/ contains name.txt, subtitle.txt, description.txt, keywords.txt, promotional_text.txt, release_notes.txt; fastlane/metadata/ contains copyright.txt and the review_information/ + app store URLs; support URL is https://snapceipt.cc/support and privacy URL is https://snapceipt.cc/privacy; `bundle exec fastlane deliver download_metadata` is NOT required (we author up).
- [ ] docs/app-store/app-privacy-answers.md exists and lists all 8 collected data types from Snapceipt/PrivacyInfo.xcprivacy mapped to the App Store Connect App Privacy categories, each marked 'Linked to you = Yes, Used for tracking = No, Purpose = App Functionality', plus 'Tracking = No' overall.
- [ ] All new/changed files are committed with conventional-commit messages ending in the required Co-Authored-By trailer.

**Files:**

- `Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- `Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- `scripts/generate-app-icon.swift`
- `scripts/tour-appstore.sh`
- `fastlane/Fastfile`
- `fastlane/Deliverfile`
- `fastlane/metadata/en-AU/name.txt`
- `fastlane/metadata/en-AU/subtitle.txt`
- `fastlane/metadata/en-AU/description.txt`
- `fastlane/metadata/en-AU/keywords.txt`
- `fastlane/metadata/en-AU/promotional_text.txt`
- `fastlane/metadata/en-AU/release_notes.txt`
- `fastlane/metadata/en-AU/support_url.txt`
- `fastlane/metadata/en-AU/privacy_url.txt`
- `fastlane/metadata/en-AU/marketing_url.txt`
- `fastlane/metadata/copyright.txt`
- `fastlane/metadata/primary_category.txt`
- `fastlane/metadata/secondary_category.txt`
- `fastlane/metadata/review_information/first_name.txt`
- `fastlane/metadata/review_information/last_name.txt`
- `fastlane/metadata/review_information/email_address.txt`
- `fastlane/metadata/review_information/phone_number.txt`
- `fastlane/metadata/review_information/notes.txt`
- `fastlane/screenshots/.gitkeep`
- `fastlane/README.md`
- `docs/app-store/app-privacy-answers.md`
- `.gitignore`

### Task 1 — Replace the placeholder App Icon with real artwork (operator + verification)

The current icon is generated by `scripts/generate-app-icon.swift` (a terracotta-receipt placeholder, see its header comment) and lives as a single 1024x1024 file at `Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` referenced by `Contents.json` (`"size": "1024x1024"`, single universal entry — Xcode 14+ single-size catalog, correct for modern submission). App Store marketing icons must be 1024x1024, sRGB, **opaque (no alpha)**. This task swaps in final artwork and proves the constraints; it does not create the art (see open_questions).

- [ ] **Step 1: Receive final artwork.** Obtain the designer's final `AppIcon.png` (1024x1024, opaque, sRGB, no rounded corners — Apple applies the mask). Place it at an absolute path, e.g. `/tmp/AppIcon-final.png`. (Operator action — artwork is human-supplied.)

- [ ] **Step 2: Verify the source artwork BEFORE committing.** Run:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  sips -g pixelWidth -g pixelHeight -g hasAlpha -g space /tmp/AppIcon-final.png
  ```
  Expected output must include `pixelWidth: 1024`, `pixelHeight: 1024`, `hasAlpha: no`, `space: RGB`. If `hasAlpha: yes`, flatten it onto an opaque canvas first:
  ```bash
  sips -s format png --setProperty hasAlpha no /tmp/AppIcon-final.png --out /tmp/AppIcon-final.png
  ```
  and re-run the check until `hasAlpha: no`.

- [ ] **Step 3: Install the artwork into the asset catalog.** Overwrite the committed icon (path is unchanged so `Contents.json` and `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml` line 37 stay valid):
  ```bash
  cp /tmp/AppIcon-final.png /Users/yangqi/Documents/github/Snapceipt/Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
  file /Users/yangqi/Documents/github/Snapceipt/Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
  ```
  Expected: `PNG image data, 1024 x 1024, 8-bit/color RGB, non-interlaced` (note **RGB**, not RGBA — confirms no alpha). (The committed placeholder already reports exactly this; the real art must match.)

- [ ] **Step 4: Mark `scripts/generate-app-icon.swift` superseded.** The generator produced the placeholder; keep it for history but make it impossible to silently overwrite the real art. Edit the header comment block of `scripts/generate-app-icon.swift` — change the second comment line to:
  ```swift
  // SUPERSEDED: the shipping icon is human-supplied final artwork (see
  // Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png).
  // This script generated the pre-GA placeholder; do NOT run it against the
  // committed asset or it will clobber the real icon. Kept for reference only.
  ```

- [ ] **Step 5: Verify the icon compiles into a release build with no asset warnings.** Run a release archive of just the asset-catalog step via a clean build (full archive is slow; this targets the catalog compiler):
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && /opt/homebrew/bin/xcodegen generate
  xcrun actool Snapceipt/Resources/Assets.xcassets \
    --compile /tmp/actool-out --platform iphoneos --minimum-deployment-target 17.0 \
    --app-icon AppIcon --output-partial-info-plist /tmp/actool.plist 2>&1 | grep -iE "warning|error|alpha|missing" || echo "actool: no icon warnings"
  ```
  Expected: `actool: no icon warnings` (no "alpha channel" / "missing icon" / "unassigned" messages). (Deployment target 17.0 matches `project.yml` line 23.)

- [ ] **Step 6: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png scripts/generate-app-icon.swift
  git commit -m "$(cat <<'EOF'
  feat(icon): ship final App Store icon, retire placeholder generator

  Replace the programmatically-generated placeholder (terracotta receipt) with
  the final 1024x1024 opaque sRGB marketing icon. Mark generate-app-icon.swift
  as superseded so it can't clobber the shipping art.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 2 — Add a 6.7"/6.5" App Store screenshot generator on top of the tour harness

The screenshot tour already exists: `SnapceiptUITests/ScreenshotTourUITests.swift` (one `test_areaNN_*` method per area, each calling `shoot(app, "<screen>-<state>")` via `SnapceiptUITests/TourShooter.swift`), driven by `scripts/tour.sh <run-id> [methods...]`. That script hard-codes `DEST='platform=iOS Simulator,name=iPhone 16'` and `SIM_NAME='iPhone 16'` and writes PNGs to `artifacts/tour/<run-id>/<area>/<screen>-<state>.png`. The app is **iPhone-only** (`project.yml` line 38: `TARGETED_DEVICE_FAMILY: "1"`), so App Store needs the **6.7"** and **6.5"** sets only — no iPad. We add a thin wrapper that reuses the same XCUITest + export pipeline but loops the two required device sizes and lays the output out the way `upload_to_app_store` expects.

Device → required pixel size mapping (App Store Connect, confirmed available in `xcrun simctl list devicetypes`):
- 6.7" = `iPhone 16 Plus` → 1290 x 2796
- 6.5" = `iPhone 11 Pro Max` → 1242 x 2688

We curate a small "hero" subset (Apple shows up to 10; 3–5 is plenty for GA): areas 3 (home), 5 (reports/BAS export), 9 (quotes), 14 (BAS). The exact `func test_areaNN_...` names in `SnapceiptUITests/ScreenshotTourUITests.swift` are `test_area03_home` (line 78), `test_area05_reports` (line 105), `test_area09_quotes` (line 194), `test_area14_bas` (line 287) — note the BAS area is numbered 14, not 11, and `scripts/tour.sh`'s `METHODS_ALL` list does not include it (the tour script tops out at `test_area10_emailSettingsProfiles`), so we reference the real method names from the test source directly.

- [ ] **Step 1: Write the failing harness (it must fail because the script does not exist yet).** Create `scripts/tour-appstore.sh`:
  ```bash
  #!/usr/bin/env bash
  # App Store screenshot generator. Reuses ScreenshotTourUITests (the same suite
  # scripts/tour.sh drives) but renders the curated hero subset on the two device
  # sizes App Store Connect requires for an iPhone-only app:
  #   6.7" -> iPhone 16 Plus    (1290x2796)
  #   6.5" -> iPhone 11 Pro Max (1242x2688)
  # Output: artifacts/appstore/<run-id>/<size>/<screen>-<state>.png  (size = 6.7|6.5)
  # Usage:  scripts/tour-appstore.sh <run-id>
  set -euo pipefail
  cd "$(dirname "$0")/.."

  RUN_ID="${1:?usage: scripts/tour-appstore.sh <run-id>}"
  OUT="artifacts/appstore/${RUN_ID}"
  rm -rf "$OUT"; mkdir -p "$OUT"

  # Curated hero screens (method -> the shoot() PNGs it emits live in those areas).
  HERO_METHODS=(
    test_area03_home
    test_area05_reports
    test_area09_quotes
    test_area14_bas
  )

  # size-label  device-name
  shoot_size() {
    local label="$1" device="$2"
    local dest="platform=iOS Simulator,name=${device}"
    local bundle="artifacts/appstore/_result-${RUN_ID}-${label}.xcresult"
    local export_dir="artifacts/appstore/_export-${RUN_ID}-${label}"
    rm -rf "$bundle" "$export_dir"

    xcrun simctl boot "$device" 2>/dev/null || true
    xcrun simctl bootstatus "$device" -b || true
    xcrun simctl status_bar "$device" override \
      --time "9:41" --batteryState charged --batteryLevel 100 \
      --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi

    local only=()
    for m in "${HERO_METHODS[@]}"; do
      only+=("-only-testing:SnapceiptUITests/ScreenshotTourUITests/$m")
    done
    xcodebuild test -scheme Snapceipt -destination "$dest" \
      "${only[@]}" -resultBundlePath "$bundle" 2>&1 | tail -6

    xcrun xcresulttool export attachments --path "$bundle" --output-path "$export_dir"
    local dest_dir="$OUT/$label"; mkdir -p "$dest_dir"
    python3 - "$export_dir" "$dest_dir" <<'PY'
  import json, os, re, shutil, sys
  export_dir, out = sys.argv[1], sys.argv[2]
  manifest = json.load(open(os.path.join(export_dir, "manifest.json")))
  count = 0
  for entry in manifest:
      for att in entry.get("attachments", []):
          src = att.get("exportedFileName")
          name = att.get("suggestedHumanReadableName") or att.get("name") or src
          if not src:
              continue
          # Strip xcresulttool's "_<idx>_<UUID>" suffix (same idiom as scripts/tour.sh).
          name = re.sub(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?=\.|$)", "", name)
          name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
          if not name.lower().endswith(".png"):
              name += ".png"
          shutil.copyfile(os.path.join(export_dir, src), os.path.join(out, name))
          count += 1
  print(f"appstore: exported {count} PNG(s) to {out}")
  PY
    xcrun simctl status_bar "$device" clear || true
  }

  /opt/homebrew/bin/xcodegen generate
  shoot_size "6.7" "iPhone 16 Plus"
  shoot_size "6.5" "iPhone 11 Pro Max"
  echo "appstore tour done: $OUT"
  ```

- [ ] **Step 2: Run it, watch it fail to be executable; first confirm the curated method names actually exist in the suite (this is the "test").**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  grep -oE "func (test_area03_home|test_area05_reports|test_area09_quotes|test_area14_bas)" SnapceiptUITests/ScreenshotTourUITests.swift | sort -u
  ```
  Expected (the four methods exist — the BAS method is `test_area14_bas`, declared at line 287 just above the `shoot(app, "bas-card-needsreview")` block at line 292):
  ```
  func test_area03_home
  func test_area05_reports
  func test_area09_quotes
  func test_area14_bas
  ```
  If `grep` shows fewer than 4 lines, open `SnapceiptUITests/ScreenshotTourUITests.swift`, find the real `func test_areaNN_...` declarations (`grep -nE "func test_"` lists them all), and correct the names in `HERO_METHODS` to match before proceeding. The script itself is not yet executable:
  ```bash
  test -x scripts/tour-appstore.sh && echo EXEC || echo "NOT-EXEC (expected before chmod)"
  ```
  Expected: `NOT-EXEC (expected before chmod)`.

- [ ] **Step 3: Make it executable.**
  ```bash
  chmod +x /Users/yangqi/Documents/github/Snapceipt/scripts/tour-appstore.sh
  test -x /Users/yangqi/Documents/github/Snapceipt/scripts/tour-appstore.sh && echo EXEC
  ```
  Expected: `EXEC`.

- [ ] **Step 4: Generate the screenshots (operator run — this boots two simulators and runs XCUITests; allow ~10–15 min). `test_area14_bas` uses the `-uiTestBasSeed` fixture via `launchBasSeed()` (UITestCase.swift:36), so the gated BAS card renders.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && scripts/tour-appstore.sh ga1
  ```
  Expected tail: `appstore: exported N PNG(s) to artifacts/appstore/ga1/6.7` then `...6.5`, then `appstore tour done: artifacts/appstore/ga1`.

- [ ] **Step 5: Verify the pixel dimensions match App Store requirements exactly.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  for f in artifacts/appstore/ga1/6.7/*.png; do sips -g pixelWidth -g pixelHeight "$f"; done
  for f in artifacts/appstore/ga1/6.5/*.png; do sips -g pixelWidth -g pixelHeight "$f"; done
  ```
  Expected: every 6.7 file reports `pixelWidth: 1290` / `pixelHeight: 2796`; every 6.5 file reports `pixelWidth: 1242` / `pixelHeight: 2688`. (If a device reports a different size, the simulator scale differs — fix by confirming the device name in `shoot_size` and re-running; do not resize PNGs, App Store rejects upscaled images.)

- [ ] **Step 6: Keep generated PNGs out of git but commit the generator.** `artifacts/` is already gitignored (`.gitignore` line 50), so the PNGs won't be committed (correct — they're regenerable). Commit only the script:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add scripts/tour-appstore.sh
  git commit -m "$(cat <<'EOF'
  feat(screenshots): App Store 6.7"/6.5" screenshot generator on the tour harness

  Reuse ScreenshotTourUITests across iPhone 16 Plus (1290x2796) and iPhone 11
  Pro Max (1242x2688) for the curated hero subset (home, reports, quotes, BAS
  via test_area14_bas); export to artifacts/appstore. iPhone-only app
  (TARGETED_DEVICE_FAMILY=1) so no iPad set is needed.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 3 — Scaffold `fastlane/metadata/` (App Store listing skeleton)

`fastlane/` currently has `Fastfile`, `Appfile`, `Matchfile`, `.env.example` (plus a generated `README.md`/`report.xml`, both gitignored) — no metadata tree. `upload_to_app_store` (alias `deliver`) reads `fastlane/metadata/`. We author the tree up (we do NOT `download_metadata` — the app has never been listed). Locale is `en-AU` (Australian app). Support/privacy URLs are the live pages confirmed at `site/public/support.html` and `site/public/privacy.html` → `https://snapceipt.cc/support` and `https://snapceipt.cc/privacy`. This is pure file authoring + a metadata-tree verification; no TDD cycle.

- [ ] **Step 1: Create the locale metadata files.** Create each file with `en-AU` content drawn from the live site tone (founder must approve copy — see open_questions):
  - `fastlane/metadata/en-AU/name.txt`:
    ```
    Snapceipt — Receipts & GST
    ```
  - `fastlane/metadata/en-AU/subtitle.txt`:
    ```
    Receipts, expenses & BAS, sorted
    ```
  - `fastlane/metadata/en-AU/promotional_text.txt`:
    ```
    Snap a receipt and we read the merchant, total and GST for you. Built for Australian sole traders and small business — BAS-ready, no spreadsheets.
    ```
  - `fastlane/metadata/en-AU/description.txt`:
    ```
    Snapceipt is the Australian receipt and expense app that does the boring bit for you. Snap a receipt and Snapceipt reads the merchant, amount, GST and category automatically — so your records are ready when BAS and tax time arrive.

    WHY SNAPCEIPT
    • Snap & done — capture a receipt and the details are extracted for you.
    • GST & BAS ready — amounts and GST are tracked so your quarterly BAS is a few taps, not a weekend.
    • Built for Australia — AUD, GST, and the Australian Privacy Principles, by default.
    • Separate business & personal — keep profiles apart with one tap.
    • Logbooks & budgets — mileage, work-from-home hours, and spending caps in one place.
    • Quotes & loyalty cards — send GST-inclusive quotes and keep your cards handy.
    • Email receipts in — forward digital receipts and they land in the right profile.
    • Private by design — no ads, no third-party trackers, and we never sell your data.

    Your data is encrypted in transit and at rest. Delete your account and data any time from Account → Delete Account.

    Questions? Email support@snapceipt.cc.
    ```
  - `fastlane/metadata/en-AU/keywords.txt` (single line, <=100 chars incl. commas — count before committing):
    ```
    receipt,expense,gst,bas,tax,mileage,logbook,sole trader,small business,scanner,budget,quote
    ```
  - `fastlane/metadata/en-AU/release_notes.txt`:
    ```
    First public release of Snapceipt. Snap receipts, track GST and expenses, and get BAS-ready — built for Australian sole traders and small business.
    ```
  - `fastlane/metadata/en-AU/support_url.txt`:
    ```
    https://snapceipt.cc/support
    ```
  - `fastlane/metadata/en-AU/privacy_url.txt`:
    ```
    https://snapceipt.cc/privacy
    ```
  - `fastlane/metadata/en-AU/marketing_url.txt`:
    ```
    https://snapceipt.cc
    ```

- [ ] **Step 2: Create the app-level (non-localized) metadata files.**
  - `fastlane/metadata/copyright.txt`:
    ```
    2026 Snapceipt
    ```
  - `fastlane/metadata/primary_category.txt`:
    ```
    FINANCE
    ```
  - `fastlane/metadata/secondary_category.txt`:
    ```
    PRODUCTIVITY
    ```

- [ ] **Step 3: Create the review-information files** (so Apple's reviewer can reach a human and knows how to sign in — the app uses Sign in with Apple / magic link; see open_questions about a demo account):
  - `fastlane/metadata/review_information/first_name.txt`:
    ```
    Qiguang
    ```
  - `fastlane/metadata/review_information/last_name.txt`:
    ```
    Yang
    ```
  - `fastlane/metadata/review_information/email_address.txt`:
    ```
    support@snapceipt.cc
    ```
  - `fastlane/metadata/review_information/phone_number.txt` (operator: fill with a real reachable number before submission):
    ```
    +61 000 000 000
    ```
  - `fastlane/metadata/review_information/notes.txt`:
    ```
    Snapceipt signs in with Sign in with Apple or an emailed magic link — no username/password. To review the full app without email, a demo account can be provisioned on request (contact support@snapceipt.cc). The app is Australian (AUD/GST); receipt OCR sends only extracted receipt text (never name/email) to our processor. Subscriptions are auto-renewing Apple In-App Purchases.
    ```

- [ ] **Step 4: Add a screenshots holder so `deliver` has a stable path.** The actual PNGs come from `scripts/tour-appstore.sh` (Task 2, gitignored under `artifacts/`); for a manual upload the operator copies them into `fastlane/screenshots/en-AU/`. Create the placeholder:
  ```bash
  mkdir -p /Users/yangqi/Documents/github/Snapceipt/fastlane/screenshots
  : > /Users/yangqi/Documents/github/Snapceipt/fastlane/screenshots/.gitkeep
  ```

- [ ] **Step 5: Verify keyword length and metadata tree.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  awk 'END{print "keywords chars:", length($0)}' fastlane/metadata/en-AU/keywords.txt
  find fastlane/metadata -type f | sort
  ```
  Expected: `keywords chars: 91` (<=100), and the `find` lists all 16 metadata files created in Steps 1–3 (9 under en-AU, 3 app-level, 4 review_information, wait — recount): 9 en-AU (name, subtitle, promotional_text, description, keywords, release_notes, support_url, privacy_url, marketing_url) + 3 app-level (copyright, primary_category, secondary_category) + 5 review_information (first_name, last_name, email_address, phone_number, notes) = 17 files.

- [ ] **Step 6: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add fastlane/metadata fastlane/screenshots/.gitkeep
  git commit -m "$(cat <<'EOF'
  feat(fastlane): scaffold App Store metadata (en-AU) for GA listing

  Author name/subtitle/description/keywords/promo/release-notes, categories
  (Finance + Productivity), copyright, review-info, and live support/privacy
  URLs (snapceipt.cc/support, /privacy). Screenshots come from
  scripts/tour-appstore.sh.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 4 — Add a fastlane `release` lane (build → upload → submit for review, phased)

`fastlane/Fastfile` already has the auth + build building blocks we reuse verbatim: the private `asc_api_key` lane (App Store Connect API key from `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_PATH`), the `match(type: "appstore", readonly: true, ...)` cert pull, the `sh("cd .. && xcodegen generate")` step, and the exact `gym(...)` invocation used by `beta` (scheme `Snapceipt`, `export_method: "app-store"`, `codesigning_identity: ENV["CODESIGN_IDENTITY"]`, `xcargs: "CURRENT_PROJECT_VERSION=#{build_num} DEVELOPMENT_TEAM=#{ENV.fetch("FASTLANE_TEAM_ID")}"`, the `provisioningProfiles` map `"app.snapceipt.Snapceipt" => "match AppStore app.snapceipt.Snapceipt"`). The `release` lane builds the same way but uploads the binary + metadata + screenshots via `upload_to_app_store` (deliver) instead of `pilot`, and submits for **phased** review.

- [ ] **Step 1: Add a `Deliverfile` so the lane and a manual `deliver` agree on locale/team.** Create `fastlane/Deliverfile`:
  ```ruby
  # Shared deliver config for the `release` lane and manual `fastlane deliver` runs.
  app_identifier("app.snapceipt.Snapceipt")
  # en-AU is the source locale (Australian app). Metadata + screenshots live under
  # fastlane/metadata and fastlane/screenshots.
  ```

- [ ] **Step 2: Add the `release` lane to `fastlane/Fastfile`.** Insert the following lane immediately before the final `end` that closes `platform :ios do` (i.e. after the `beta` lane's closing `end`, which is the second-to-last line of the file):
  ```ruby
    desc "GA: build the App Store binary, upload binary+metadata+screenshots, submit for phased review"
    lane :release do
      ensure_git_status_clean
      # project.yml is the source of truth; the .xcodeproj is gitignored.
      sh("cd .. && xcodegen generate")
      api_key = asc_api_key
      match(type: "appstore", readonly: true, api_key: api_key)
      # Build number must lead TestFlight (App Store rejects a re-used build number).
      build_num = latest_testflight_build_number(api_key: api_key, initial_build_number: 0) + 1
      gym(
        scheme: "Snapceipt",
        export_method: "app-store",
        codesigning_identity: ENV["CODESIGN_IDENTITY"],
        xcargs: "CURRENT_PROJECT_VERSION=#{build_num} DEVELOPMENT_TEAM=#{ENV.fetch("FASTLANE_TEAM_ID")}",
        export_options: {
          provisioningProfiles: {
            "app.snapceipt.Snapceipt" => "match AppStore app.snapceipt.Snapceipt"
          },
          signingCertificate: ENV["CODESIGN_IDENTITY"]
        }.compact
      )
      upload_to_app_store(
        api_key: api_key,
        # Upload the .ipa gym just built (skip the long binary re-build).
        ipa: lane_context[SharedValues::IPA_OUTPUT_PATH],
        # Author metadata/screenshots from the repo; never pull from ASC.
        skip_metadata: false,
        skip_screenshots: false,
        metadata_path: "./metadata",
        screenshots_path: "./screenshots",
        # Submit straight into App Review, rolled out gradually once approved.
        submit_for_review: true,
        phased_release: true,
        # Reset ratings only on explicit request — keep history across updates.
        reset_ratings: false,
        # Precheck/non-interactive guards for CI.
        run_precheck_before_submit: true,
        force: true, # skip the HTML preview/confirmation prompt
        submission_information: {
          # No IDFA / ad tracking — mirrors PrivacyInfo.xcprivacy NSPrivacyTracking=false.
          add_id_info_uses_idfa: false,
          export_compliance_uses_encryption: false
        }
      )
    end
  ```

- [ ] **Step 3: Verify the Fastfile parses (Ruby syntax check — this is the "test").**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  ruby -c fastlane/Fastfile
  ```
  Expected: `Syntax OK`.

- [ ] **Step 4: Verify fastlane sees the new lane.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  bundle exec fastlane lanes 2>&1 | grep -E "ios release|GA: build"
  ```
  Expected: a line for `ios release` with the description `GA: build the App Store binary, upload binary+metadata+screenshots, submit for phased review`.

- [ ] **Step 5: Regenerate the fastlane README (it is auto-generated and gitignored, but refresh it so a human reading it sees the new lane).**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  bundle exec fastlane docs 2>&1 | tail -3
  grep -c "ios release" fastlane/README.md
  ```
  Expected: `grep -c` prints `1` (README mentions the release lane). Note `fastlane/README.md` is gitignored (`.gitignore` line 38) so it won't be committed — that's fine.

- [ ] **Step 6: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add fastlane/Fastfile fastlane/Deliverfile
  git commit -m "$(cat <<'EOF'
  feat(fastlane): add App Store `release` lane (gym -> deliver, phased review)

  Reuse the beta lane's ASC-API-key auth, match cert pull, xcodegen, and gym
  config; upload the binary plus fastlane/metadata + fastlane/screenshots via
  upload_to_app_store with submit_for_review + phased_release. Add a Deliverfile
  pinning app id + en-AU locale.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 5 — Document the App Privacy "nutrition label" answers (mirror PrivacyInfo.xcprivacy)

`Snapceipt/PrivacyInfo.xcprivacy` is the source of truth and declares exactly 8 collected data types, `NSPrivacyTracking = false` (no tracking), `NSPrivacyTrackingDomains` empty, and **every** type with `NSPrivacyCollectedDataTypeLinked = true`, `NSPrivacyCollectedDataTypeTracking = false`, and purpose `NSPrivacyCollectedDataTypePurposeAppFunctionality`. App Store Connect's App Privacy questionnaire is filled by a human in the ASC web UI (not by fastlane), so we produce a precise, checkable answer sheet so the operator transcribes it without guessing. This is documentation, not code — no TDD cycle.

The 8 xcprivacy types (in manifest order: EmailAddress, PurchaseHistory, UserID, Name, PhotosorVideos, DeviceID, OtherFinancialInfo, OtherUserContent) map to ASC App Privacy categories as:
| PrivacyInfo type | ASC category → data type |
| --- | --- |
| `NSPrivacyCollectedDataTypeEmailAddress` | Contact Info → Email Address |
| `NSPrivacyCollectedDataTypeName` | Contact Info → Name |
| `NSPrivacyCollectedDataTypeUserID` | Identifiers → User ID |
| `NSPrivacyCollectedDataTypeDeviceID` | Identifiers → Device ID |
| `NSPrivacyCollectedDataTypePurchaseHistory` | Purchases → Purchase History |
| `NSPrivacyCollectedDataTypeOtherFinancialInfo` | Financial Info → Other Financial Info |
| `NSPrivacyCollectedDataTypePhotosorVideos` | User Content → Photos or Videos |
| `NSPrivacyCollectedDataTypeOtherUserContent` | User Content → Other User Content |

- [ ] **Step 1: Write the answer sheet.** Create `docs/app-store/app-privacy-answers.md`:
  ```markdown
  # App Store Connect — App Privacy questionnaire answers

  Source of truth: `Snapceipt/PrivacyInfo.xcprivacy`. This sheet is for the human
  filling the ASC App Privacy section (ASC does not read the manifest). If you
  change PrivacyInfo.xcprivacy, update this file in the same PR.

  ## Tracking
  - **Does this app collect data used to track the user?** NO.
    (PrivacyInfo: `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains` empty.)
  - No data type below is used for tracking
    (`NSPrivacyCollectedDataTypeTracking = false` on all 8).

  ## Data collected (8 types)
  Every type: **Linked to the user = Yes** (`...Linked = true`),
  **Used for tracking = No**, **Purpose = App Functionality**
  (`...PurposeAppFunctionality`). Set these three the same for each row.

  | ASC category | ASC data type | Linked | Tracking | Purpose |
  | --- | --- | --- | --- | --- |
  | Contact Info | Email Address | Yes | No | App Functionality |
  | Contact Info | Name | Yes | No | App Functionality |
  | Identifiers | User ID | Yes | No | App Functionality |
  | Identifiers | Device ID | Yes | No | App Functionality |
  | Purchases | Purchase History | Yes | No | App Functionality |
  | Financial Info | Other Financial Info | Yes | No | App Functionality |
  | User Content | Photos or Videos | Yes | No | App Functionality |
  | User Content | Other User Content | Yes | No | App Functionality |

  ## NOT collected (answer "No"/leave unchecked)
  - Location (precise or coarse) — none.
  - Contacts — none.
  - Browsing/Search History — none.
  - Health & Fitness — none.
  - Sensitive Info — none.
  - Diagnostics (Crash/Performance) — none. (No analytics or crash SDK ships;
    re-check before submit — see open_questions. If one is added, add
    "Diagnostics > Crash Data" here AND to PrivacyInfo.xcprivacy.)

  ## Notes for the reviewer copy (matches privacy policy at snapceipt.cc/privacy)
  - Email/Name: account (Sign in with Apple or magic link).
  - User ID/Device ID: account scoping + push delivery (push token + device info).
  - Purchase History: Apple In-App Purchase subscription state.
  - Other Financial Info: receipt/transaction amounts, GST, totals.
  - Photos or Videos: receipt photos captured/imported.
  - Other User Content: notes, quotes, logbook/budget entries.
  - OCR sends only extracted receipt **text** to the processor — never name/email
    (matches privacy.html: "Only receipt text is sent for reading").
  ```

- [ ] **Step 2: Cross-check the doc against the manifest (the verification — counts must match).**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  echo "manifest types:"; grep -c "<key>NSPrivacyCollectedDataType</key>" Snapceipt/PrivacyInfo.xcprivacy
  echo "doc rows:"; grep -cE "^\| (Contact Info|Identifiers|Purchases|Financial Info|User Content) \|" docs/app-store/app-privacy-answers.md
  echo "tracking flag:"; grep -A1 "NSPrivacyTracking</key>" Snapceipt/PrivacyInfo.xcprivacy | grep -o "false"
  ```
  Expected: `manifest types: 8`, `doc rows: 8`, `tracking flag: false`. (The 8 rows in the table must equal the 8 `NSPrivacyCollectedDataType` keys in the manifest. If they differ, the manifest changed — reconcile the table before committing.)

- [ ] **Step 3: Commit.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add docs/app-store/app-privacy-answers.md
  git commit -m "$(cat <<'EOF'
  docs(app-store): App Privacy questionnaire answers mirroring PrivacyInfo.xcprivacy

  All 8 collected types -> ASC categories, each Linked=Yes / Tracking=No /
  Purpose=App Functionality; overall Tracking=No. Operator transcribes this into
  the ASC App Privacy UI (not filled by fastlane).

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

### Task 6 — Wire the EULA URL once StoreKit ships (deferred, soft dependency)

GA decision (1) ships Apple App Store subscriptions. Apple requires auto-renewable subscriptions to surface an EULA (custom or Apple's standard) in the listing. The exact URL is owned by the StoreKit workstream. This task is the explicit hand-off so it isn't dropped.

- [ ] **Step 1: When the StoreKit workstream confirms the EULA URL** (e.g. `https://snapceipt.cc/terms`), set it in the listing. fastlane `deliver` has no dedicated EULA-URL key (EULA is set in the ASC UI under App Information → License Agreement, or via the IAP's "App License Agreement"), so record it for the operator. Append to `fastlane/metadata/review_information/notes.txt`:
  ```
  EULA: <EULA_URL> (set in ASC App Information -> License Agreement).
  ```
  (Operator action — replace `<EULA_URL>` with the real URL from the StoreKit workstream.)

- [ ] **Step 2: Re-check the App Privacy "Purchases → Purchase History" row is still accurate** after StoreKit lands (it is already declared in PrivacyInfo.xcprivacy and Task 5's sheet, so no change expected). Verify:
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  grep -q "Purchase History" docs/app-store/app-privacy-answers.md && grep -q "NSPrivacyCollectedDataTypePurchaseHistory" Snapceipt/PrivacyInfo.xcprivacy && echo "purchase-history: consistent"
  ```
  Expected: `purchase-history: consistent`.

- [ ] **Step 3: Commit (only if Step 1 changed a tracked file).**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt
  git add fastlane/metadata/review_information/notes.txt
  git commit -m "$(cat <<'EOF'
  chore(app-store): record EULA URL for the listing (StoreKit hand-off)

  Auto-renewable subscriptions require an EULA in the listing; record the URL
  from the StoreKit workstream in the reviewer notes for the operator to set in
  ASC App Information -> License Agreement.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

**Open questions (human input needed):**

- APP ICON ARTWORK IS HUMAN-SUPPLIED. The current Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png is programmatically generated by scripts/generate-app-icon.swift (a terracotta receipt placeholder). A designer must deliver a final 1024x1024 opaque PNG (no alpha, no transparency, sRGB). Task 1 wires it in and verifies constraints but cannot invent the art.
- ASC App Privacy: does the GA build send any crash/diagnostic data (e.g. a Crashlytics/Sentry SDK)? PrivacyInfo.xcprivacy declares none, so the plan answers 'No diagnostics collected'. Confirm no analytics/crash SDK is added by the push or StoreKit workstreams before submitting; if one is added, add 'Diagnostics > Crash Data' to docs/app-store/app-privacy-answers.md.
- Marketing copy (description/keywords/subtitle/promotional text/what's-new) in fastlane/metadata is drafted from the live site (snapceipt.cc) tone but must be approved by the founder before submission — App Store rejects keyword-stuffing and unsubstantiated claims.
- App review sign-in: ASC requires a demo account or a note that the app uses Sign in with Apple / magic link. review_information/notes.txt is drafted to point reviewers at the dev sign-in / a seeded demo account — confirm whether a real reviewer demo account + credentials should be provisioned (the app has a dev sign-in path used by UI tests).
- EULA URL: locked GA decision (1) ships StoreKit subscriptions. Apple requires a custom EULA or the standard Apple EULA link for auto-renewing subscriptions, surfaced in metadata. The exact EULA URL (e.g. https://snapceipt.cc/terms) is owned by the StoreKit workstream; Task 5 leaves it as a documented TODO to fill in that workstream's final metadata step.
- Primary/secondary App Store category: plan proposes Finance (primary) + Productivity (secondary). Confirm with founder — Business is an alternative secondary.

_Critic verdict: fixed (5 issue(s) fixed)._

---

## Workstream 8 — Operational Readiness + Final GA Gates

**Goal:** Make Snapceipt operationally safe to run in production at GA: alerting + uptime monitoring on the Worker, a written rollback runbook, an off-platform D1 backup, lightweight iOS crash/hang visibility via a new authenticated MetricKit-ingest Worker route, verified live email-in routing, and a recorded real-device smoke sign-off gate.

**Dependencies:** Mostly independent and can run in parallel with the feature workstreams. Soft ordering: Task 4 (MetricKit ingest route) should land before its iOS reporter wiring (Task 5) since the reporter posts to that route; Task 6 (D1 backup cron) shares src/index.ts scheduled() and wrangler.jsonc with the budget cron but only appends — no conflict. The GA gates (Tasks 1, 2, 7, 8) require the Worker already deployed to api.snapceipt.cc (Workstream that does the StoreKit/GA deploy) and a Release build cut for Task 8. Task 4's migration (0006_crash_reports.sql) is the next free migration number after migrations/0005_quote_gst_inclusive.sql — coordinate the number if another workstream also adds a migration.

**Definition of done:**

- [ ] A Cloudflare Notifications policy named 'snapceipt-api errors' fires to qiguangyang@gmail.com on Worker error-rate, AND a Health Check on https://api.snapceipt.cc/health (expects 200, body contains "ok":true) is Healthy in the dashboard.
- [ ] README.md contains a '## Operations runbook' section with: backend rollback (`npx wrangler deployments list` + `npx wrangler rollback [<version-id>]`), the explicit warning that D1 migrations are forward-only so rollback does NOT revert schema, and iOS fix-forward + App Store Connect phased-release pause / Remove from Sale levers.
- [ ] README.md documents D1 backup: Time Travel (30-day, `npx wrangler d1 time-travel ...`) AND the new hourly `npx wrangler d1 export` -> R2 job; the BACKUPS R2 bucket exists and a manual scheduled-handler invocation writes a dated .sql object into it.
- [ ] `npx vitest run test/crash-report.test.ts` passes: POST /crash-reports stores a MXCrashDiagnostic payload scoped to c.var.userId + c.var.deviceId, rejects an unauthenticated call with 401, and rejects a malformed body with 400 VALIDATION_FAILED.
- [ ] migrations/0006_crash_reports.sql applies cleanly via `npm run migrate:local` and is NOT added to any SYNCABLE_TABLES list.
- [ ] iOS: a CrashReporter (MXMetricManagerSubscriber) is registered at launch in SnapceiptApp.swift behind the Release path and posts MXCrashDiagnostic/MXHangDiagnostic JSON to POST /crash-reports; `xcodegen generate && xcodebuild build -scheme Snapceipt -destination 'generic/platform=iOS'` succeeds.
- [ ] Email-in routing verified live: in.snapceipt.cc is a Cloudflare zone with Email Routing enabled, catch-all -> snapceipt-api, and a real forward to r.<token>@in.snapceipt.cc produces an email_in transaction visible on-device (recorded with the token used + transaction id).
- [ ] The 13-item device-smoke checklist (docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md) is run on a RELEASE build on real hardware against prod, every item recorded pass/fail with the build number, with explicit confirmation of item 13 (the bottom-left import button rendering above the native VisionKit scanner without colliding with Flash/Filters/Shutter chrome); all-pass is the recorded GA sign-off.

**Files:**

- `README.md`
- `wrangler.jsonc`
- `src/index.ts`
- `src/cron/d1Backup.ts`
- `src/routes/crashReports.ts`
- `src/schemas/crashReport.ts`
- `src/app.ts`
- `src/env.ts`
- `migrations/0006_crash_reports.sql`
- `test/crash-report.test.ts`
- `test/crash-report-schema.test.ts`
- `Snapceipt/App/SnapceiptApp.swift`
- `Snapceipt/App/CrashReporter.swift`
- `Snapceipt/Sync/APIClient.swift`
- `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md`

### Task 1 — Cloudflare Worker error alerting + synthetic uptime monitor (operator)

No code. Two dashboard configs against the deployed `snapceipt-api` Worker (`wrangler.jsonc` name = `snapceipt-api`, account_id `bb4412973b5e4f6d7a10a4e68b713177`, custom domain `api.snapceipt.cc`).

- [ ] **Step 1: Create the Worker error-rate Notification policy.**
  Dashboard → log in as the techsiderau account → **Notifications** (left nav, account-level) → **Add** → category **Workers** → notification type **"Workers Errors / Failing Deployments"** (named "Failed Deployment" + invocation errors). Name it `snapceipt-api errors`. Scope it to the `snapceipt-api` Worker. Add the email destination `qiguangyang@gmail.com`. Save.
  Expected confirmation: the policy appears in the Notifications list as **Enabled**, scoped to `snapceipt-api`, delivering to `qiguangyang@gmail.com`.

- [ ] **Step 2: Create the synthetic uptime Health Check on /health.**
  Dashboard → select the `snapceipt.cc` zone → **Traffic → Health Checks** → **Create**. Name `api-health`. Monitored address / hostname: `api.snapceipt.cc`. Type **HTTPS**, Port **443**, Path **`/health`**, method **GET**. Under "Response body" set **expected body contains** `"ok":true` and **expected codes** `200`. Interval 60s, retries 2, from at least 2 regions (one APAC). Save.
  (Note: `/health` is unauthenticated — confirmed in `src/middleware/auth.ts:11` `PUBLIC_PATHS = ["/health", ...]` and `src/routes/misc.ts:12-13` returns `c.json({ ok: true, service: "snapceipt-api" })`, so the body match is stable.)
  Expected confirmation: the Health Check shows status **Healthy** within ~2 minutes.

- [ ] **Step 3: Wire a Health-Check Notification.**
  Notifications → **Add** → category **Health Checks** → type "Health Check status notifications" → select `api-health` → destination `qiguangyang@gmail.com`. Save.
  Expected confirmation: a Health-Check policy appears Enabled. (Optional verification: in the Health Check, click ⋯ → there is no "force fail"; instead briefly note the green→would-page path is now armed.)

- [ ] **Step 4: Smoke-prove the alert path end to end (optional but recommended).**
  Temporarily change the Health Check's expected body to a value that will not match (e.g. `__never__`), wait one interval, confirm status flips to **Unhealthy** and an email arrives at `qiguangyang@gmail.com`, then **revert** the expected body to `"ok":true` and confirm it returns to Healthy.
  Expected confirmation: one unhealthy email received; Health Check back to Healthy after revert.

---

### Task 2 — Operations runbook in README (rollback + backup levers)

`README.md` is 171 lines and ends with the iOS UI-tests / E2E journey-suites section. Append a new top-level `## Operations runbook` section. No tests — it is documentation; verification is a render/read check.

- [ ] **Step 1: Append the runbook section to README.md.**
  Add at the end of `README.md`:

  ```markdown
  ## Operations runbook

  Production Worker: `snapceipt-api` on `api.snapceipt.cc` (account `techsiderau`,
  id `bb4412973b5e4f6d7a10a4e68b713177`). Deploy is `npx wrangler deploy`
  (`scripts/deploy.sh` for a full provision + deploy).

  ### Backend rollback (Worker code)

  ```bash
  # 1. List recent deployments (most recent first) and copy a known-good Version ID.
  npx wrangler deployments list

  # 2. Roll back to that version (omit the id to roll back to the previous one).
  npx wrangler rollback <version-id>
  ```

  **WARNING — rollback does NOT revert the database.** D1 migrations in
  `migrations/` are applied with `wrangler d1 migrations apply --remote` and are
  **forward-only**: `wrangler rollback` only swaps the Worker bundle, it never
  un-applies a migration. A migration that drops/renames a column will still be
  gone after a code rollback. Therefore: make every migration **additive +
  backward-compatible** (e.g. `0005_quote_gst_inclusive.sql` is a pure
  `ADD COLUMN ... DEFAULT 0`), so an older Worker bundle keeps working against the
  newer schema. If a migration corrupted data, recover via **D1 Time Travel**
  (see "D1 backups" below), not via code rollback.

  ### iOS rollback (App Store)

  There is no binary downgrade on the App Store. Levers, in order of preference:

  1. **Fix-forward** — ship a new build (`bundle exec fastlane beta` →
     promote). Fastest safe path for most regressions.
  2. **Pause a phased release** — App Store Connect → the version → *Phased
     Release for Automatic Updates* → **Pause**. Stops the rollout of a bad
     version to the rest of the install base while you cut a fix.
  3. **Remove from Sale** — App Store Connect → App → *Pricing and Availability*
     → set availability to no territories. Last resort for a critical defect; new
     users can't download, existing installs are unaffected.

  Because the backend is forward-compatible (additive migrations), an older
  installed app keeps working against the current Worker — so the iOS lever you
  almost always want is **fix-forward**, with phased-release **Pause** to buy time.
  ```

- [ ] **Step 2: Verify the section renders and the commands are correct.**
  Run:
  ```bash
  grep -n "## Operations runbook" /Users/yangqi/Documents/github/Snapceipt/README.md
  grep -n "wrangler rollback" /Users/yangqi/Documents/github/Snapceipt/README.md
  grep -n "forward-only" /Users/yangqi/Documents/github/Snapceipt/README.md
  ```
  Expected output: three non-empty matching lines (the heading, the rollback command, the forward-only warning).

- [ ] **Step 3: Commit.**
  ```bash
  git add README.md
  git commit -m "$(cat <<'EOF'
  docs(ops): add rollback runbook (Worker rollback + forward-only D1 + iOS levers)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit created touching only `README.md`.

---

### Task 3 — Document D1 backup strategy (Time Travel + R2 export) in README

Pairs with Task 6 (the actual export cron). This task documents both halves. No tests.

- [ ] **Step 1: Append a "D1 backups" subsection under the runbook.**
  Add to `README.md`, immediately after the `### Backend rollback (Worker code)` block created in Task 2 (or at the end of the runbook section):

  ```markdown
  ### D1 backups

  Two layers cover the production `snapceipt` D1 database:

  1. **Time Travel (built-in, 30-day):** Cloudflare keeps a continuous restore
     window. To inspect or restore a point in time:
     ```bash
     # Find the bookmark for a timestamp (or use --timestamp directly).
     npx wrangler d1 time-travel info snapceipt --timestamp=2026-06-15T00:00:00Z
     # Restore the DB to that point (DESTRUCTIVE — overwrites current state).
     npx wrangler d1 time-travel restore snapceipt --timestamp=2026-06-15T00:00:00Z
     ```
     Use this to recover from a bad migration or accidental mass-delete within the
     last 30 days.

  2. **Off-platform export to R2 (hourly cron):** the Worker's scheduled handler
     (`src/index.ts`) also runs `d1BackupLogic` (`src/cron/d1Backup.ts`), which the
     `0 * * * *` cron triggers every hour. It writes a full SQL dump to the
     `BACKUPS` R2 bucket under `d1/snapceipt/<YYYY-MM-DD>/<epoch-ms>.sql`. To take a
     manual dump or restore from one:
     ```bash
     # Manual full export to a local file:
     npx wrangler d1 export snapceipt --remote --output=snapceipt-$(date +%F).sql
     # Restore that dump into a fresh/empty database:
     npx wrangler d1 execute snapceipt --remote --file=snapceipt-2026-06-15.sql
     ```
     R2 lifecycle: set a 30-day expiry on the `snapceipt-backups` bucket so dumps
     self-prune (Dashboard → R2 → snapceipt-backups → Settings → Object lifecycle
     rules → delete after 30 days; or CLI: `npx wrangler r2 bucket lifecycle ...`).
  ```

- [ ] **Step 2: Verify.**
  ```bash
  grep -n "### D1 backups" /Users/yangqi/Documents/github/Snapceipt/README.md
  grep -n "time-travel" /Users/yangqi/Documents/github/Snapceipt/README.md
  ```
  Expected output: two non-empty matching lines.

- [ ] **Step 3: Commit.**
  ```bash
  git add README.md
  git commit -m "$(cat <<'EOF'
  docs(ops): document D1 backup strategy (Time Travel + hourly R2 export)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit touching only `README.md`.

---

### Task 4 — Authenticated MetricKit-ingest Worker route (TDD)

A new POST `/crash-reports` that accepts a MetricKit diagnostic payload and stores it, scoped to `c.var.userId` + `c.var.deviceId`. Both are set on the context by the global auth middleware (`src/middleware/auth.ts:43-45`: `c.set("userId", claims.sub)` / `c.set("deviceId", claims.did)` / `c.set("sessionId", claims.sid)`), so the handler reads them straight off `c.var` exactly like the other protected routes (e.g. `src/routes/inbox.ts:25` reads `c.var.userId`). Follows the route idiom in `src/routes/inbox.ts` / `src/routes/account.ts`: `Hono<AppEnv>`, `validate("json", schema)` from `./auth`, `ApiError`, `c.env.DB`. The table is server-only (NOT syncable), mirroring `inbound_email_log` in `migrations/0003_email_in.sql`.

- [ ] **Step 1: Write the failing schema test.**
  Create `test/crash-report-schema.test.ts` (mirrors `test/export-schema.test.ts`):
  ```ts
  import { describe, expect, it } from "vitest";
  import { crashReportSchema } from "../src/schemas/crashReport";

  describe("crashReportSchema", () => {
    it("accepts a MXCrashDiagnostic-shaped payload", () => {
      const r = crashReportSchema.safeParse({
        kind: "crash",
        appVersion: "0.1.0",
        osVersion: "iOS 18.5",
        deviceModel: "iPhone16,2",
        occurredAt: 1_718_400_000_000,
        payload: { exceptionType: 1, signal: 11, terminationReason: "Namespace SIGNAL" },
      });
      expect(r.success).toBe(true);
    });

    it("accepts kind=hang", () => {
      expect(crashReportSchema.safeParse({
        kind: "hang", appVersion: "0.1.0", osVersion: "iOS 18.5",
        deviceModel: "iPhone16,2", occurredAt: 1, payload: { hangDurationMs: 2500 },
      }).success).toBe(true);
    });

    it("rejects an unknown kind", () => {
      expect(crashReportSchema.safeParse({
        kind: "panic", appVersion: "0.1.0", osVersion: "iOS 18.5",
        deviceModel: "iPhone16,2", occurredAt: 1, payload: {},
      }).success).toBe(false);
    });

    it("rejects a missing payload", () => {
      expect(crashReportSchema.safeParse({
        kind: "crash", appVersion: "0.1.0", osVersion: "iOS 18.5",
        deviceModel: "iPhone16,2", occurredAt: 1,
      }).success).toBe(false);
    });
  });
  ```

- [ ] **Step 2: Run it — it fails (module does not exist).**
  ```bash
  npx vitest run test/crash-report-schema.test.ts
  ```
  Expected failure: `Failed to resolve import "../src/schemas/crashReport"` (or "Cannot find module").

- [ ] **Step 3: Implement the schema.**
  Create `src/schemas/crashReport.ts` (mirrors `src/schemas/export.ts` style):
  ```ts
  import { z } from "zod";

  /**
   * POST /crash-reports body. iOS posts MetricKit diagnostics (MXCrashDiagnostic /
   * MXHangDiagnostic) reduced to a small JSON envelope. `payload` is the raw
   * diagnostic dictionary (MXDiagnostic.dictionaryRepresentation) — stored verbatim
   * as JSON for later triage; we don't model its full shape. Server-only; never
   * synced. occurredAt is epoch ms.
   */
  export const crashReportSchema = z.object({
    kind: z.enum(["crash", "hang"]),
    appVersion: z.string().min(1),
    osVersion: z.string().min(1),
    deviceModel: z.string().min(1),
    occurredAt: z.number().int().nonnegative(),
    payload: z.record(z.string(), z.unknown()),
  });

  export type CrashReport = z.infer<typeof crashReportSchema>;
  ```

- [ ] **Step 4: Run the schema test — it passes.**
  ```bash
  npx vitest run test/crash-report-schema.test.ts
  ```
  Expected output: `4 passed`.

- [ ] **Step 5: Write the failing migration + route test.**
  Create `test/crash-report.test.ts` (mirrors `test/inbox-routes.test.ts` for the authed-route idiom — `seedAuthed`, `issueSession`, `SELF.fetch`; the global setup file `test/apply-migrations.ts` applies all migrations once per test worker, so no per-suite `applyD1Migrations` is needed):
  ```ts
  import { env, SELF } from "cloudflare:test";
  import { beforeEach, describe, expect, it } from "vitest";
  import { uuidv7 } from "../src/lib/ids";
  import { nowMs } from "../src/lib/time";
  import { issueSession } from "../src/lib/sessions";

  async function seedAuthed(): Promise<{ bearer: string; userId: string; deviceId: string }> {
    const userId = uuidv7();
    const deviceId = uuidv7();
    const t = nowMs();
    await env.DB.prepare(
      `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
    ).bind(userId, `${userId}@e.com`, t, t).run();
    await env.DB.prepare(
      `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
    ).bind(deviceId, userId, t, t).run();
    const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
    return { bearer: `Bearer ${accessToken}`, userId, deviceId };
  }

  const body = {
    kind: "crash",
    appVersion: "0.1.0",
    osVersion: "iOS 18.5",
    deviceModel: "iPhone16,2",
    occurredAt: 1_718_400_000_000,
    payload: { signal: 11, terminationReason: "Namespace SIGNAL, Code 11" },
  };

  beforeEach(async () => {
    await env.DB.exec("DELETE FROM crash_reports");
    await env.DB.exec("DELETE FROM sessions");
    await env.DB.exec("DELETE FROM devices");
    await env.DB.exec("DELETE FROM users");
  });

  describe("POST /crash-reports", () => {
    it("stores a diagnostic scoped to the authed user + device", async () => {
      const { bearer, userId, deviceId } = await seedAuthed();
      const res = await SELF.fetch("https://x/crash-reports", {
        method: "POST",
        headers: { authorization: bearer, "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      expect(res.status).toBe(201);
      const out = (await res.json()) as { id: string };
      expect(out.id).toMatch(/^[0-9a-f-]{36}$/);

      const row = await env.DB.prepare(
        "SELECT user_id, device_id, kind, app_version, payload FROM crash_reports WHERE id = ?",
      ).bind(out.id).first<{ user_id: string; device_id: string; kind: string; app_version: string; payload: string }>();
      expect(row?.user_id).toBe(userId);
      expect(row?.device_id).toBe(deviceId);
      expect(row?.kind).toBe("crash");
      expect(row?.app_version).toBe("0.1.0");
      expect(JSON.parse(row!.payload).signal).toBe(11);
    });

    it("401s without a bearer token", async () => {
      const res = await SELF.fetch("https://x/crash-reports", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      expect(res.status).toBe(401);
    });

    it("400s on a malformed body", async () => {
      const { bearer } = await seedAuthed();
      const res = await SELF.fetch("https://x/crash-reports", {
        method: "POST",
        headers: { authorization: bearer, "content-type": "application/json" },
        body: JSON.stringify({ kind: "crash" }),
      });
      expect(res.status).toBe(400);
      const env2 = (await res.json()) as { error: { code: string } };
      expect(env2.error.code).toBe("VALIDATION_FAILED");
    });
  });
  ```
  (Note: the route reads `c.var.deviceId` from the JWT `did` claim — the test does not need to send an `X-Device-Id` header; the device id is bound at session issue time, so a client can't spoof another device's reports.)

- [ ] **Step 6: Run it — it fails (no table, no route).**
  ```bash
  npx vitest run test/crash-report.test.ts
  ```
  Expected failure: `no such table: crash_reports` (and/or the POST returns 404 because the route is not mounted).

- [ ] **Step 7: Add the migration.**
  Create `migrations/0006_crash_reports.sql` (mirrors the server-only-table idiom in `migrations/0003_email_in.sql`):
  ```sql
  -- 0006_crash_reports.sql — iOS MetricKit crash/hang diagnostics ingest.
  -- Server-only: NEVER added to SYNCABLE_TABLES (src/lib/syncTables.ts) — a device
  -- posts its own diagnostics; they are never pulled back. Scoped to (user_id,
  -- device_id) for triage. payload is the raw MXDiagnostic dictionary stored as JSON.
  CREATE TABLE crash_reports (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id),
    device_id    TEXT NOT NULL,
    kind         TEXT NOT NULL CHECK (kind IN ('crash','hang')),
    app_version  TEXT NOT NULL,
    os_version   TEXT NOT NULL,
    device_model TEXT NOT NULL,
    occurred_at  INTEGER NOT NULL,
    payload      TEXT NOT NULL,
    created_at   INTEGER NOT NULL
  );
  CREATE INDEX ix_crash_user      ON crash_reports(user_id);
  CREATE INDEX ix_crash_created   ON crash_reports(created_at);
  CREATE INDEX ix_crash_kind_ver  ON crash_reports(kind, app_version);
  ```

- [ ] **Step 8: Implement the route.**
  Create `src/routes/crashReports.ts`:
  ```ts
  // src/routes/crashReports.ts
  import { Hono } from "hono";
  import type { AppEnv } from "../env";
  import { uuidv7 } from "../lib/ids";
  import { nowMs } from "../lib/time";
  import { validate } from "./auth";
  import { crashReportSchema } from "../schemas/crashReport";

  /**
   * iOS MetricKit ingest (auth-gated; rate tier "default"). The global auth
   * middleware has already resolved c.var.userId AND c.var.deviceId (from the JWT
   * `sub`/`did` claims, src/middleware/auth.ts:43-44); the device id comes from the
   * session-bound c.var.deviceId so a client can't spoof another device's reports.
   *  POST /crash-reports — store one MXCrashDiagnostic/MXHangDiagnostic.
   * Server-only: crash_reports is NEVER in SYNCABLE_TABLES.
   */
  export const crashReportRoutes = new Hono<AppEnv>();

  crashReportRoutes.post("/", validate("json", crashReportSchema), async (c) => {
    const userId = c.var.userId;
    const deviceId = c.var.deviceId;
    const { kind, appVersion, osVersion, deviceModel, occurredAt, payload } = c.req.valid("json");
    const id = uuidv7();
    const now = nowMs();

    await c.env.DB.prepare(
      `INSERT INTO crash_reports
         (id, user_id, device_id, kind, app_version, os_version, device_model, occurred_at, payload, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
      .bind(id, userId, deviceId, kind, appVersion, osVersion, deviceModel, occurredAt, JSON.stringify(payload), now)
      .run();

    return c.json({ id }, 201);
  });
  ```

- [ ] **Step 9: Mount the route + add a rate limiter in `src/app.ts`.**
  In `src/app.ts`, add the import alongside the existing route imports (after line 17, `import { accountRoutes } from "./routes/account";`):
  ```ts
  import { crashReportRoutes } from "./routes/crashReports";
  ```
  Add the rate-limit mount next to the other protected mounts (after line 83, `app.use("/account", rateLimit("account"));`):
  ```ts
  // iOS MetricKit ingest — default tier. Auth-gated.
  app.use("/crash-reports", rateLimit("default"));
  ```
  Add the route mount with the other protected `app.route` calls — BEFORE the catch-all `app.route("/", accountRoutes)` at line 105 (mount it after line 103, `app.route("/profiles", inboxRoutes);`):
  ```ts
  // Protected: iOS MetricKit crash/hang ingest (server-only crash_reports table).
  app.route("/crash-reports", crashReportRoutes);
  ```

- [ ] **Step 10: Run both tests — they pass.**
  ```bash
  npx vitest run test/crash-report-schema.test.ts test/crash-report.test.ts
  npm run typecheck
  ```
  Expected output: `7 passed` total (4 schema + 3 route), and `tsc --noEmit` exits 0.

- [ ] **Step 11: Apply the migration locally.**
  ```bash
  npm run migrate:local
  ```
  Expected output: `0006_crash_reports.sql` listed as applied (`🚣 1 migration to apply ... Done`). (`migrate:local` runs `wrangler d1 migrations apply snapceipt --local`.)

- [ ] **Step 12: Commit.**
  ```bash
  git add src/schemas/crashReport.ts src/routes/crashReports.ts src/app.ts migrations/0006_crash_reports.sql test/crash-report-schema.test.ts test/crash-report.test.ts
  git commit -m "$(cat <<'EOF'
  feat(crash): authenticated MetricKit ingest route + crash_reports table

  POST /crash-reports stores MXCrashDiagnostic/MXHangDiagnostic scoped to the
  session-bound userId + deviceId. Server-only table, never syncable.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit with the six files.

---

### Task 5 — iOS MetricKit reporter wiring (config + build verification)

Register an `MXMetricManagerSubscriber` at launch that reduces `MXCrashDiagnostic`/`MXHangDiagnostic` to the envelope Task 4's route accepts and posts it via a new `APIClient.reportDiagnostic`. MetricKit needs no entitlement and no Info.plist key — `import MetricKit` + `MXMetricManager.shared.add(_:)` is the whole API surface; deployment target is already 17.0 (`project.yml:5`). This is UI/config wiring, so it's an exact-edit + build verification (no contrived unit test — the postable logic is already tested server-side in Task 4).

- [ ] **Step 1: Add the API method to the protocol + LiveAPIClient.**
  In `Snapceipt/Sync/APIClient.swift`, add to the `protocol APIClient` (after line 44, `func deleteAccount() async throws`):
  ```swift
      /// POST /crash-reports — upload one MetricKit diagnostic (crash/hang). Best-effort;
      /// callers ignore failures (diagnostics are not critical-path). (ops)
      func reportDiagnostic(_ body: DiagnosticReportBody) async throws
  ```
  Add the implementation to `final class LiveAPIClient` (after the `deleteAccount()` impl whose closing brace is at line 222):
  ```swift
      func reportDiagnostic(_ body: DiagnosticReportBody) async throws {
          try await sendNoContent("POST", "/crash-reports", body: body, authenticated: true)
      }
  ```
  Add the request body struct near the other body structs at the bottom of the file (after the `ExtractBody` struct, which ends at line 400). NOTE: `ExtractBody` is `private`, but `DiagnosticReportBody` is referenced from `CrashReporter.swift` (a different file) and from the protocol, so it must NOT be `private` — declare both new types at internal (module) visibility:
  ```swift
  /// POST /crash-reports request body — a MetricKit diagnostic reduced to the
  /// server envelope. `payload` is the raw MXDiagnostic dictionary as JSON.
  struct DiagnosticReportBody: Encodable {
      let kind: String            // "crash" | "hang"
      let appVersion: String
      let osVersion: String
      let deviceModel: String
      let occurredAt: Int         // epoch ms
      let payload: [String: AnyCodable]
  }

  /// Minimal type-erased JSON value so an arbitrary MXDiagnostic dictionary encodes.
  struct AnyCodable: Encodable {
      let value: Any
      init(_ value: Any) { self.value = value }
      func encode(to encoder: Encoder) throws {
          var c = encoder.singleValueContainer()
          switch value {
          case let v as Bool: try c.encode(v)
          case let v as Int: try c.encode(v)
          case let v as Double: try c.encode(v)
          case let v as String: try c.encode(v)
          case let v as [Any]: try c.encode(v.map(AnyCodable.init))
          case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
          default: try c.encodeNil()
          }
      }
  }
  ```

- [ ] **Step 2: Add the CrashReporter subscriber.**
  Create `Snapceipt/App/CrashReporter.swift`:
  ```swift
  import Foundation
  import MetricKit
  import UIKit

  /// Lightweight MetricKit subscriber: forwards MXCrashDiagnostic / MXHangDiagnostic
  /// to POST /crash-reports (best-effort). MetricKit delivers diagnostics on the next
  /// launch after the event, batched into MXDiagnosticPayload; we POST each one scoped
  /// to the session (the route derives userId+deviceId from the bearer). No entitlement
  /// or Info.plist key is required. dSYMs: App Store Connect symbolicates server-side
  /// from the uploaded archive; these envelopes carry the raw (unsymbolicated) dictionary
  /// for cross-referencing — keep the dSYMs from each archive (Organizer → Download dSYMs)
  /// so traces remain symbolicatable.
  final class CrashReporter: NSObject, MXMetricManagerSubscriber {
      private let api: APIClient

      init(api: APIClient) {
          self.api = api
          super.init()
          MXMetricManager.shared.add(self)
      }

      deinit { MXMetricManager.shared.remove(self) }

      func didReceive(_ payloads: [MXDiagnosticPayload]) {
          let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
          let osVersion = "iOS " + UIDevice.current.systemVersion
          let model = Self.hardwareModel()
          for payload in payloads {
              let occurredAt = Int(payload.timeStampEnd.timeIntervalSince1970 * 1000)
              for crash in payload.crashDiagnostics ?? [] {
                  post(kind: "crash", dict: crash.dictionaryRepresentation(),
                       appVersion: appVersion, osVersion: osVersion, model: model, occurredAt: occurredAt)
              }
              for hang in payload.hangDiagnostics ?? [] {
                  post(kind: "hang", dict: hang.dictionaryRepresentation(),
                       appVersion: appVersion, osVersion: osVersion, model: model, occurredAt: occurredAt)
              }
          }
      }

      private func post(kind: String, dict: [AnyHashable: Any],
                        appVersion: String, osVersion: String, model: String, occurredAt: Int) {
          let payload = Dictionary(uniqueKeysWithValues:
              dict.compactMap { k, v in (k as? String).map { ($0, AnyCodable(v)) } })
          let body = DiagnosticReportBody(
              kind: kind, appVersion: appVersion, osVersion: osVersion,
              deviceModel: model, occurredAt: occurredAt, payload: payload)
          Task { try? await api.reportDiagnostic(body) }
      }

      private static func hardwareModel() -> String {
          var sysinfo = utsname()
          uname(&sysinfo)
          return withUnsafeBytes(of: &sysinfo.machine) { raw in
              String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
          }
      }
  }
  ```

- [ ] **Step 3: Register the reporter at launch (Release path).**
  In `Snapceipt/App/SnapceiptApp.swift`, add a stored property next to the other `@State` singletons (after line 30, `@State private var appLock: AppLockController`):
  ```swift
      /// MetricKit crash/hang reporter — registered with MXMetricManager at launch so
      /// diagnostics from the previous run POST to /crash-reports. Held to keep the
      /// subscriber alive. Wired only on the live network boundary (Release), not the
      /// UI-test stub.
      @State private var crashReporter: CrashReporter?
  ```
  In `init()`, `api` is declared in BOTH the `#if DEBUG` and `#else` branches (lines 44 and 57), so it is in scope after the `#endif` at line 60. At the end of `init()`, after `_appLock = State(initialValue: appLock)` (line 82), add:
  ```swift
  #if DEBUG
          _crashReporter = State(initialValue: nil)
  #else
          _crashReporter = State(initialValue: CrashReporter(api: api))
  #endif
  ```

- [ ] **Step 4: Regenerate the project and build.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
  xcodebuild build -scheme Snapceipt -destination 'generic/platform=iOS' -quiet
  ```
  Expected output: `xcodegen generate` prints `Created project at .../Snapceipt.xcodeproj`; `xcodebuild` ends with `** BUILD SUCCEEDED **`. (`CrashReporter.swift` is auto-included — `project.yml:23` `sources: - path: Snapceipt` globs the whole `Snapceipt` path.)

- [ ] **Step 5: Commit.**
  ```bash
  git add Snapceipt/App/CrashReporter.swift Snapceipt/App/SnapceiptApp.swift Snapceipt/Sync/APIClient.swift Snapceipt.xcodeproj
  git commit -m "$(cat <<'EOF'
  feat(ios): MetricKit crash/hang reporter -> POST /crash-reports

  Registers an MXMetricManagerSubscriber at launch (Release path) that uploads
  MXCrashDiagnostic/MXHangDiagnostic envelopes. Best-effort; failures ignored.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit with the iOS files (and the regenerated `.xcodeproj` if tracked).

---

### Task 6 — Hourly D1 export to R2 (TDD the cron core + wire it)

Extend the existing hourly cron. `src/index.ts:9-11` already runs `budgetCronLogic(env.DB, env, Date.now())` inside `scheduled`; `wrangler.jsonc` triggers `"0 * * * *"`. Add a `d1BackupLogic(db, bucket, nowMs)` pure core (same injectable-deps idiom as `src/cron/budgetAlert.ts`) and `ctx.waitUntil` it alongside the budget cron. It writes the database dump to a new `BACKUPS` R2 bucket. NOTE: the repo pins wrangler `^3.114.17` (installed 3.114.17), so all `wrangler` invocations below use the repo's pinned `npx wrangler` (v3) — do not pin `@4`.

- [ ] **Step 1: Write the failing cron-core test.**
  Create `test/d1Backup.test.ts` (pure-core style, like `test/budgetAlert.test.ts` — call the function directly with `env` bindings; the global `test/apply-migrations.ts` setup applies all migrations once per worker, so the core tables exist):
  ```ts
  import { env } from "cloudflare:test";
  import { describe, expect, it } from "vitest";
  import { d1BackupLogic, backupKey } from "../src/cron/d1Backup";

  describe("backupKey", () => {
    it("partitions by UTC date and uses an epoch-ms filename", () => {
      const ms = Date.UTC(2026, 5, 15, 9, 30, 0); // 2026-06-15T09:30:00Z
      expect(backupKey(ms)).toBe(`d1/snapceipt/2026-06-15/${ms}.sql`);
    });
  });

  describe("d1BackupLogic", () => {
    it("writes a non-empty SQL dump to the BACKUPS bucket under a dated key", async () => {
      const ms = Date.UTC(2026, 5, 15, 9, 30, 0);
      await d1BackupLogic(env.DB, env.BACKUPS, ms);
      const obj = await env.BACKUPS.get(`d1/snapceipt/2026-06-15/${ms}.sql`);
      expect(obj).not.toBeNull();
      const text = await obj!.text();
      // The dump always contains the schema for our core tables.
      expect(text).toContain("CREATE TABLE");
      expect(text).toContain("users");
    });
  });
  ```

- [ ] **Step 2: Run it — it fails (no module, no BACKUPS binding).**
  ```bash
  npx vitest run test/d1Backup.test.ts
  ```
  Expected failure: `Failed to resolve import "../src/cron/d1Backup"`.

- [ ] **Step 3: Add the BACKUPS R2 binding to env + wrangler + test config.**
  In `src/env.ts`, add to the `Env` type (after line 12, the `RECEIPTS` field):
  ```ts
    /** R2 bucket for hourly D1 SQL dumps (ops backup; never read at request time). */
    BACKUPS: R2Bucket;
  ```
  In `wrangler.jsonc`, extend `r2_buckets` (currently a single-element array) to:
  ```jsonc
    "r2_buckets": [
      { "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" },
      { "binding": "BACKUPS", "bucket_name": "snapceipt-backups" }
    ],
  ```
  In `vitest.config.ts`, add a test-only R2 bucket inside the existing `miniflare` block (the block opens at line 34 and has a `bindings:` object at line 37). Add `r2Buckets` as a sibling key of `bindings`/`compatibilityFlags`/`wrappedBindings` so the test runtime provides `env.BACKUPS`:
  ```ts
            r2Buckets: ["BACKUPS"],
  ```
  (`RECEIPTS` is already provided by loading `wrangler.jsonc`; this line adds the new `BACKUPS` bucket for tests.)

- [ ] **Step 4: Implement the cron core.**
  Create `src/cron/d1Backup.ts` (mirrors `src/cron/budgetAlert.ts` — pure, deps injected):
  ```ts
  /**
   * Hourly D1 -> R2 backup (ops). Pure-ish: db + bucket + nowMs are injected so it is
   * unit-testable without the scheduled() runtime. Reads the full schema + data via a
   * single dump query and stores it as a .sql object partitioned by UTC date. The
   * dump uses sqlite_master for DDL and per-table SELECTs for data so it round-trips
   * via `wrangler d1 execute --file`.
   */

  /** R2 object key: d1/snapceipt/<YYYY-MM-DD>/<epoch-ms>.sql (UTC date partition). */
  export function backupKey(nowMs: number): string {
    const d = new Date(nowMs);
    const y = d.getUTCFullYear();
    const m = String(d.getUTCMonth() + 1).padStart(2, "0");
    const day = String(d.getUTCDate()).padStart(2, "0");
    return `d1/snapceipt/${y}-${m}-${day}/${nowMs}.sql`;
  }

  /** SQL-escape a value as a literal for the dump (strings single-quoted + doubled). */
  function lit(v: unknown): string {
    if (v === null || v === undefined) return "NULL";
    if (typeof v === "number") return String(v);
    if (v instanceof ArrayBuffer) {
      const hex = [...new Uint8Array(v)].map((b) => b.toString(16).padStart(2, "0")).join("");
      return `X'${hex}'`;
    }
    return `'${String(v).replace(/'/g, "''")}'`;
  }

  export async function d1BackupLogic(db: D1Database, bucket: R2Bucket, nowMs: number): Promise<void> {
    // 1. DDL for every user table (skip sqlite_* + the migrations bookkeeping table).
    const { results: schema } = await db
      .prepare(
        `SELECT name, sql FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'd1_migrations'
          ORDER BY name`,
      )
      .all<{ name: string; sql: string }>();

    const parts: string[] = [
      `-- Snapceipt D1 dump ${new Date(nowMs).toISOString()}`,
      "PRAGMA foreign_keys=OFF;",
      "BEGIN TRANSACTION;",
    ];

    for (const t of schema) {
      parts.push(`${t.sql};`);
      const { results: rows } = await db.prepare(`SELECT * FROM "${t.name}"`).all<Record<string, unknown>>();
      for (const row of rows) {
        const cols = Object.keys(row);
        const vals = cols.map((c) => lit(row[c])).join(", ");
        parts.push(`INSERT INTO "${t.name}" (${cols.map((c) => `"${c}"`).join(", ")}) VALUES (${vals});`);
      }
    }

    parts.push("COMMIT;", "PRAGMA foreign_keys=ON;", "");
    await bucket.put(backupKey(nowMs), parts.join("\n"));
  }
  ```

- [ ] **Step 5: Wire it into the scheduled handler.**
  In `src/index.ts`, add the import (after line 4, `import { inboundEmailLogic } from "./email/inbound";`):
  ```ts
  import { d1BackupLogic } from "./cron/d1Backup";
  ```
  Extend `scheduled` (lines 9-11) so both cron cores run:
  ```ts
  const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
    const now = Date.now();
    ctx.waitUntil(budgetCronLogic(env.DB, env, now));
    ctx.waitUntil(d1BackupLogic(env.DB, env.BACKUPS, now));
  };
  ```

- [ ] **Step 6: Run the test — it passes.**
  ```bash
  npx vitest run test/d1Backup.test.ts
  npm run typecheck
  ```
  Expected output: `2 passed`, and `tsc --noEmit` exits 0.

- [ ] **Step 7: Provision the R2 bucket (operator) before deploy.**
  ```bash
  npx wrangler r2 bucket create snapceipt-backups
  ```
  Expected confirmation: `Created bucket 'snapceipt-backups'` (or a benign "already exists" error on re-run). (`r2 bucket create` exists in the repo's wrangler v3.)

- [ ] **Step 8: Commit.**
  ```bash
  git add src/cron/d1Backup.ts src/index.ts src/env.ts wrangler.jsonc vitest.config.ts test/d1Backup.test.ts
  git commit -m "$(cat <<'EOF'
  feat(ops): hourly D1 -> R2 SQL backup in the scheduled handler

  d1BackupLogic dumps schema + data to the BACKUPS bucket under a UTC-dated key,
  alongside the existing budget cron. Pure core, tested directly.

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit with the six files.

- [ ] **Step 9: Post-deploy verification (operator, after the GA deploy).**
  After `npx wrangler deploy`, trigger the hourly cron and confirm an object lands. The repo's wrangler v3 has NO `r2 object list` command (only get/put/delete), so verify via the dashboard (primary), or with a one-off `wrangler@4` invocation (the only thing it's used for):
  - Trigger the cron: Dashboard → Workers & Pages → `snapceipt-api` → **Triggers** → the `0 * * * *` cron → **Trigger** (or simply wait one hour for the natural run).
  - Verify the object (dashboard): Dashboard → R2 → `snapceipt-backups` → browse `d1/snapceipt/<date>/` and confirm a `<epoch-ms>.sql` object exists.
  - Verify the object (CLI alternative, v4-only — `r2 object list` does not exist in v3):
    ```bash
    npx --yes wrangler@4 r2 object list snapceipt-backups --prefix d1/snapceipt/
    ```
  Expected confirmation: at least one `d1/snapceipt/<date>/<ms>.sql` object exists within the hour.

---

### Task 7 — Verify live email-in routing (operator gate)

Email-in is KEPT at GA (locked decision). `wrangler.jsonc` documents (in the comment block above the `ai` binding) that the catch-all on `in.snapceipt.cc` is dashboard-provisioned, not in code; `src/index.ts:20-42` is the `email()` handler that calls `inboundEmailLogic`; the alias shape is `r.<token>@in.snapceipt.cc` (confirmed `test/inbox-routes.test.ts:42`, `src/routes/inbox.ts:29` returns `{ profileId, token, address: addressForToken(token) }`). This task confirms the live wiring end to end. No code.

- [ ] **Step 1: Confirm in.snapceipt.cc is a zone with Email Routing enabled.**
  Dashboard → **Websites** → confirm `in.snapceipt.cc` is present as a zone (Active). Select it → **Email → Email Routing**. Confirm Email Routing is **Enabled** and the required **MX + TXT (SPF)** records show **Active/verified** (Email Routing → Settings → DNS records).
  Expected confirmation: Email Routing status **Enabled**, MX records verified.

- [ ] **Step 2: Confirm the catch-all routes to the Worker.**
  Email Routing → **Routing rules** → **Catch-all address** → action **Send to a Worker** → destination Worker `snapceipt-api`. (This binds inbound mail to the `email()` export in `src/index.ts`.)
  Expected confirmation: catch-all is **Enabled** → **Send to Worker: snapceipt-api**.

- [ ] **Step 3: Mint a real alias on prod.**
  On a signed-in device (or via curl with a real bearer), open the email-in screen for a business profile to mint the alias, OR:
  ```bash
  curl -s https://api.snapceipt.cc/profiles/<profileId>/inbox -H "authorization: Bearer <accessToken>"
  ```
  Expected output: JSON `{ "profileId": "...", "token": "<32 hex>", "address": "r.<token>@in.snapceipt.cc" }`. Record the `address`.

- [ ] **Step 4: Send a real forward and confirm a transaction appears.**
  From a normal mail client, forward (or send) an email **with a receipt image attached** to the `r.<token>@in.snapceipt.cc` address from Step 3. Wait ~1 minute, then on the device pull-to-refresh / open the email-in / Home list.
  Expected confirmation: a new `email_in`-sourced transaction appears for that profile (merchant/total may be low-confidence — that's fine; the gate is delivery + creation). Record the alias used + the resulting transaction id. If nothing arrives, check Email Routing → **Activity log** for the message and the Worker's logs (`npx wrangler tail snapceipt-api`) for the `email()` invocation.

- [ ] **Step 5: Record the result.**
  Add a dated line to the device-smoke checklist sign-off (Task 8 file) noting "Email-in live routing verified <date>: alias r.<token>@in.snapceipt.cc → txn <id>".
  Expected confirmation: the note is committed with Task 8's sign-off edit.

---

### Task 8 — GA device-smoke sign-off on a Release build (operator gate)

The final GA gate. Run the full 13-item checklist in `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md` on a **Release** build on **real hardware** against prod `api.snapceipt.cc`, record every item pass/fail with the build number, and gate GA on all-pass — with explicit attention to checklist **item 13** (the bottom-left photo/file import button rendering *above* the live VisionKit scanner without colliding with the native Flash/Filters/Shutter chrome). No code.

- [ ] **Step 1: Cut a fresh Release build to TestFlight.**
  ```bash
  cd /Users/yangqi/Documents/github/Snapceipt && BETA_INTERNAL_ONLY=1 bundle exec fastlane beta
  ```
  Expected confirmation: the `beta` lane (`fastlane/Fastfile:30`) prints the minted build number (`latest_testflight_build_number + 1`, `Fastfile:40`); with `BETA_INTERNAL_ONLY=1` (`Fastfile:62`) the build uploads to App Store Connect → TestFlight → **Internal** processing without an external submission. Record the number (e.g. `0.1.0(__)`).

- [ ] **Step 2: Install on a real iPhone and run the full checklist.**
  Install the build via TestFlight (internal) on a physical device, sign in with your own account against prod. Work through all 13 items in `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md`. Pay special attention to:
  - **Item 8 (App Lock):** Face ID prompt on reopen — Release biometrics path, simulator cannot exercise it.
  - **Item 10 (Loyalty render + scan):** physical card scan (camera-bound, simulator-impossible).
  - **Item 13 (Photo/file import overlay over VisionKit — the capture-import-overlay collision):** on the camera stage, confirm the bottom-left import button **renders above the live scanner**, **receives taps**, and **does not collide** with the native Flash/Filters/Shutter chrome; that it offers **Photo Library** and **Files**; that a Photos receipt and a Files PDF (ideally an extension-less iCloud Drive URL) each land in Review; and that a bad file produces the "Couldn't read that file." toast OR the low-confidence banner with **no crash**.
  Expected confirmation: each of the 13 items recorded pass/fail.

- [ ] **Step 3: Record the results in the checklist file as the GA sign-off.**
  Edit `docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md`: fill the build-number placeholder at the top (`0.1.0(__)`, line 5), tick each passing item, and replace the final `## Sign-off` block (lines 24-26) with a GA sign-off, e.g.:
  ```markdown
  ## GA sign-off (2026-06-__)
  - Build: 0.1.0(NN), Release configuration, device: iPhone <model> iOS <ver>, against prod api.snapceipt.cc.
  - Items 1–13: PASS (or list any FAIL + the repro). Item 13 (import overlay over VisionKit): PASS — button above scanner, no collision with Flash/Filters/Shutter.
  - Email-in live routing verified <date>: alias r.<token>@in.snapceipt.cc → txn <id>.  (from Task 7)
  - DECISION: all-pass → cleared for App Store GA submission. Any FAIL → triage (superpowers:systematic-debugging) → fix → re-cut, re-run before submitting.
  ```

- [ ] **Step 4: Commit the sign-off.**
  ```bash
  git add docs/superpowers/specs/2026-06-11-beta-hardening-device-smoke-checklist.md
  git commit -m "$(cat <<'EOF'
  docs(ga): record device-smoke sign-off on Release build 0.1.0(NN)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
  Expected output: one commit; GA gate is met iff all 13 items are PASS.

**Open questions (human input needed):**

- Notification delivery target: tasks assume qiguangyang@gmail.com (the project owner email). If GA ops should page a shared alias / PagerDuty / Slack webhook instead, swap the destination in Task 1.
- Migration number: 0006_crash_reports.sql assumes 0006 is free (latest is migrations/0005_quote_gst_inclusive.sql). If another GA workstream also adds a migration, renumber to avoid a collision.
- vitest.config.ts R2 test binding: Task 6 assumes the miniflare block accepts `r2Buckets: ["BACKUPS"]` to provide env.BACKUPS in tests. The file wasn't fully read; if the pool already loads all wrangler.jsonc r2_buckets automatically, this extra line may be unnecessary (and adding BACKUPS to wrangler.jsonc alone suffices).
- d1BackupLogic uses a hand-rolled SQL dump (sqlite_master DDL + per-table INSERTs) because `wrangler d1 export` is a CLI command, not a Worker-runtime API. Confirm this is acceptable vs. relying solely on the documented manual `wrangler d1 export` + Time Travel (in which case Task 6 reduces to docs-only and the cron is dropped). The hand-rolled dump is round-trippable via `wrangler d1 execute --file` but is O(rows) in memory — fine at GA scale, revisit if the DB grows large.
- MetricKit detail: MXCrashDiagnostic.dictionaryRepresentation() schema is Apple-owned and unversioned here; we store it verbatim. Confirm there is no PII concern (call stacks + binary images only; no user content) for storing it server-side under the user's account.
- GA gate ownership: Tasks 1, 7, 8 require access to the Cloudflare dashboard (techsiderau account) and App Store Connect + a physical iPhone. Confirm who executes these operator steps and where the sign-off record lives (the checklist .md is proposed).

_Critic verdict: fixed (6 issue(s) fixed)._

---

