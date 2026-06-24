# Email-in receipts → Pro-only via Gemini — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make email-in a Pro-only feature whose extraction runs server-side via Google Gemini vision (image → structured receipt in one call); bounce free users and Pro-gate the alias endpoints + the iOS Email-in screen.

**Architecture:** Replace the (deployed, broken) DeepSeek-vision email-in path with `runGeminiVisionExtraction` (Generative Language API, verified live). `inboundEmailLogic` Pro-gates via a new `isProUser(db,userId)` (extracted from `requireProPlan`), runs Gemini for Pro, and returns `pro_only` for free (→ `setReject` bounce). The inbox-alias routes call `requireProPlan(c)`. The in-app camera scan is untouched.

**Tech Stack:** Cloudflare Workers (Hono, TypeScript), vitest (+ `@cloudflare/vitest-pool-workers`); iOS SwiftUI + SwiftData, Swift Testing, XcodeGen.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-24-email-in-pro-gemini-design.md`. Base branch: `feat/email-in-pro-gemini` (already has the spec commit).
- Gemini endpoint: `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`; auth header `x-goog-api-key: <GEMINI_API_KEY>`; default model `gemini-3.1-flash-lite` (overridable via `GEMINI_MODEL`). Verified request shape: `{ contents:[{ parts:[ {text}, {inline_data:{mime_type, data}} ] }], generationConfig:{ responseMimeType:"application/json", temperature:0, maxOutputTokens:1500 } }`; response text at `candidates[0].content.parts[0].text`.
- Money/numbers stay `number` in the server contract (existing `ExtractedReceipt`). Reuse the existing `SYSTEM_PROMPT`, `tryParseReceipt`, `finalize`, `arrayBufferToBase64` (private in `deepseek.ts`) — do NOT duplicate them.
- Pro = `users.plan === "pro"` AND subscription not revoked AND (no expiry OR expiry in the future) — exactly as `requireProPlan` already computes.
- **Deviation from spec (intentional):** the Gemini extractor lives in `src/lib/deepseek.ts` (alongside `runDeepseekExtraction`), not a new `src/lib/gemini.ts`, to reuse the private `finalize`/`tryParseReceipt`/`SYSTEM_PROMPT`/`arrayBufferToBase64` (deep local deps) without widening the public API.
- Backend test cmd: `npx vitest run <file>` (focused) / `npx vitest run` (full). iOS: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/<Suite>`.
- The in-app camera scan flow (`CaptureViewModel.extract()`, `OnDeviceAI`, `FoundationModelExtractor`, the DeepSeek **text** `/extract` path) is OUT OF SCOPE — do not modify.

---

## File structure

- `src/lib/plan.ts` — add `isProUser(db, userId)`; `requireProPlan` delegates to it. (Task 1)
- `src/env.ts` — add `GEMINI_API_KEY: string` + optional `GEMINI_MODEL?: string`. (Task 2)
- `src/lib/deepseek.ts` — add `runGeminiVisionExtraction(...)`; remove `runDeepseekVisionExtraction`/`callVisionDeepseek`. (Task 2 adds, Task 3 removes the DeepSeek one)
- `src/email/inbound.ts` — Pro-gate + Gemini swap + stub gate on `GEMINI_API_KEY` + drop `workersAiOcr`. (Task 3)
- `src/index.ts` — `email()` maps `pro_only` → `setReject`. (Task 3)
- `src/lib/ocr.ts` — remove now-unused `workersAiOcr`/`OCR_MODEL`/`OCR_PROMPT` (keep `STUB_OCR_TEXT`). (Task 3)
- `src/routes/inbox.ts` — `requireProPlan(c)` on both routes. (Task 4)
- `Snapceipt/Features/EmailIn/EmailInView.swift` (+ `EmailInViewModel.swift`) — clean free-user upgrade state. (Task 5)

---

### Task 1: `isProUser` helper (plan.ts)

**Files:**
- Modify: `src/lib/plan.ts`
- Test: `test/plan.test.ts` (create if absent; else add to the existing plan test)

**Interfaces:**
- Produces: `export async function isProUser(db: D1Database, userId: string): Promise<boolean>` — the userId/db-based Pro check (same logic `requireProPlan` uses). `requireProPlan(c)` now calls `isProUser(c.env.DB, c.var.userId)` and throws `FORBIDDEN` when false.

- [ ] **Step 1: Write the failing test** — `test/plan.test.ts`

```ts
import { describe, it, expect } from "vitest";
import { isProUser } from "../src/lib/plan";

// Minimal D1 stub: returns the queued row for .first().
function dbReturning(row: unknown) {
  return { prepare: () => ({ bind: () => ({ first: async () => row }) }) } as unknown as D1Database;
}

describe("isProUser", () => {
  it("true for an active pro subscription (no expiry)", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "active", subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(true);
  });
  it("false for a free plan", async () => {
    const db = dbReturning({ plan: "free", subscription_status: null, subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false for a revoked pro subscription", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "revoked", subscription_expires_at: null });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false for an expired pro subscription", async () => {
    const db = dbReturning({ plan: "pro", subscription_status: "active", subscription_expires_at: 1 });
    expect(await isProUser(db, "u1")).toBe(false);
  });
  it("false when the user row is missing", async () => {
    const db = dbReturning(null);
    expect(await isProUser(db, "u1")).toBe(false);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL** (`isProUser` not exported)

Run: `npx vitest run test/plan.test.ts`
Expected: FAIL — "isProUser is not a function" / import error.

- [ ] **Step 3: Implement** — refactor `src/lib/plan.ts` so the query/entitlement logic lives in `isProUser`, and `requireProPlan` delegates:

```ts
export async function isProUser(db: D1Database, userId: string): Promise<boolean> {
  const row = await db.prepare(
    "SELECT plan, subscription_status, subscription_expires_at FROM users WHERE id = ? AND deleted_at IS NULL",
  )
    .bind(userId)
    .first<{ plan: string; subscription_status: string | null; subscription_expires_at: number | null }>();
  const now = nowMs();
  return !!row
    && row.plan === "pro"
    && row.subscription_status !== "revoked"
    && (row.subscription_expires_at == null || row.subscription_expires_at > now);
}

export async function requireProPlan(c: Context<AppEnv>): Promise<void> {
  if (!(await isProUser(c.env.DB, c.var.userId))) {
    throw new ApiError("FORBIDDEN", "Snapceipt Pro is required for this feature");
  }
}
```

- [ ] **Step 4: Run tests — expect PASS** (and existing route tests that hit `requireProPlan` still pass)

Run: `npx vitest run test/plan.test.ts` then `npx vitest run` (full, to confirm `requireProPlan` refactor didn't regress callers)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/plan.ts test/plan.test.ts
git commit -m "feat(plan): add isProUser(db,userId); requireProPlan delegates to it"
```

---

### Task 2: `runGeminiVisionExtraction` + env (deepseek.ts, env.ts)

**Files:**
- Modify: `src/env.ts` (add `GEMINI_API_KEY: string;` near `DEEPSEEK_API_KEY`, and `GEMINI_MODEL?: string;` near the optional vars)
- Modify: `src/lib/deepseek.ts` (add `runGeminiVisionExtraction`; keep `arrayBufferToBase64`/`SYSTEM_PROMPT`/`tryParseReceipt`/`finalize`/`ExtractionInput`/`DeepseekResult`)
- Test: `test/deepseek.test.ts` (add a `runGeminiVisionExtraction` describe block)

**Interfaces:**
- Consumes: `arrayBufferToBase64`, `SYSTEM_PROMPT`, `tryParseReceipt`, `finalize`, `ExtractionInput`, `DeepseekResult` (private to `deepseek.ts`).
- Produces: `export async function runGeminiVisionExtraction(env: Env, imageBytes: ArrayBuffer, contentType: string, defaultDate: string): Promise<DeepseekResult>` — image → Gemini → parsed+finalized receipt; THROWS on fetch/timeout/non-OK/unparseable.

- [ ] **Step 1: Write the failing test** — add to `test/deepseek.test.ts`:

```ts
import { runGeminiVisionExtraction } from "../src/lib/deepseek";

describe("runGeminiVisionExtraction", () => {
  const img = new TextEncoder().encode("fake-image-bytes").buffer;
  const geminiBody = (obj: unknown) => ({
    ok: true, status: 200,
    json: async () => ({ candidates: [{ content: { parts: [{ text: JSON.stringify(obj) }] } }] }),
  });

  it("sends an inline_data image part and parses the response", async () => {
    const calls: any[] = [];
    const orig = globalThis.fetch;
    globalThis.fetch = (async (url: string, init: any) => {
      calls.push({ url, init });
      return geminiBody({ merchant: "Woolworths", date: "2026-05-30", currencyCode: "AUD",
        total: 176.98, gst: 1.64, category: "groceries", deductible: 0,
        lineItems: [{ name: "Banana", price: 9.28 }], confidence: 0.95 });
    }) as any;
    try {
      const env = { GEMINI_API_KEY: "k", DEEPSEEK_API_KEY: "" } as any;
      const out = await runGeminiVisionExtraction(env, img, "image/png", "2026-06-24");
      expect(out.receipt.merchant).toBe("Woolworths");
      expect(out.receipt.total).toBe(176.98);
      expect(out.meta.usedLlm).toBe(true);
      const body = JSON.parse(calls[0].init.body);
      const parts = body.contents[0].parts;
      expect(parts.some((p: any) => p.inline_data?.mime_type === "image/png" && p.inline_data?.data)).toBe(true);
      expect(String(calls[0].url)).toContain("gemini-3.1-flash-lite:generateContent");
      expect(calls[0].init.headers["x-goog-api-key"]).toBe("k");
    } finally { globalThis.fetch = orig; }
  });

  it("throws on a non-OK response", async () => {
    const orig = globalThis.fetch;
    globalThis.fetch = (async () => ({ ok: false, status: 400, text: async () => "bad" })) as any;
    try {
      const env = { GEMINI_API_KEY: "k" } as any;
      await expect(runGeminiVisionExtraction(env, img, "image/png", "2026-06-24")).rejects.toThrow();
    } finally { globalThis.fetch = orig; }
  });

  it("backfills a missing date to defaultDate", async () => {
    const orig = globalThis.fetch;
    globalThis.fetch = (async () => geminiBody({ merchant: "X", date: null, currencyCode: "AUD",
      total: 10, gst: null, category: "office", deductible: 100, lineItems: [], confidence: 0.5 })) as any;
    try {
      const env = { GEMINI_API_KEY: "k" } as any;
      const out = await runGeminiVisionExtraction(env, img, "image/jpeg", "2026-06-24");
      expect(out.receipt.date).toBe("2026-06-24");
    } finally { globalThis.fetch = orig; }
  });
});
```

- [ ] **Step 2: Run it — expect FAIL** (`runGeminiVisionExtraction` not exported)

Run: `npx vitest run test/deepseek.test.ts`
Expected: FAIL — import/undefined.

- [ ] **Step 3: Implement** — in `src/env.ts` add `GEMINI_API_KEY: string;` (and `GEMINI_MODEL?: string;`). In `src/lib/deepseek.ts` add a Gemini URL builder + the function (mirrors the removed DeepSeek-vision one but Gemini shape):

```ts
const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

/** Gemini vision extraction: image → gemini-3.1-flash-lite → structured receipt in one call.
 * Same 15s abort budget as the DeepSeek caller. No OCR text → finalize()'s text guards no-op;
 * finalize still clamps total/gst and backfills the date. Throws on fetch/timeout/non-OK/unparseable
 * so the caller marks the txn failed (never a silent zeros receipt). */
export async function runGeminiVisionExtraction(
  env: Env, imageBytes: ArrayBuffer, contentType: string, defaultDate: string,
): Promise<DeepseekResult> {
  const model = env.GEMINI_MODEL ?? "gemini-3.1-flash-lite";
  const b64 = arrayBufferToBase64(imageBytes);
  const input: ExtractionInput = { ocrText: "", source: "email_in", defaultDate };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${GEMINI_BASE}/${model}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": env.GEMINI_API_KEY, "content-type": "application/json" },
      body: JSON.stringify({
        contents: [{ parts: [
          { text: `${SYSTEM_PROMPT}\nExtract the receipt in this image as that json object.` },
          { inline_data: { mime_type: contentType, data: b64 } },
        ] }],
        generationConfig: { responseMimeType: "application/json", temperature: 0, maxOutputTokens: 1500 },
      }),
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`Gemini HTTP ${res.status}`);
    const json = (await res.json()) as { candidates?: { content?: { parts?: { text?: string }[] } }[] };
    const content = json.candidates?.[0]?.content?.parts?.[0]?.text ?? null;
    const parsed = content ? tryParseReceipt(content) : null;
    if (!parsed) throw new Error("Gemini returned no parseable JSON");
    return { receipt: finalize(input, parsed), meta: { model, attempts: 1, stub: false, usedLlm: true } };
  } finally { clearTimeout(timer); }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `npx vitest run test/deepseek.test.ts`
Expected: PASS (3 new tests).

- [ ] **Step 5: Commit**

```bash
git add src/env.ts src/lib/deepseek.ts test/deepseek.test.ts
git commit -m "feat(extract): runGeminiVisionExtraction (image->gemini-3.1-flash-lite) + GEMINI env"
```

---

### Task 3: Pro-gate + Gemini in inbound; bounce free; remove DeepSeek-vision/Workers-AI OCR

**Files:**
- Modify: `src/email/inbound.ts`
- Modify: `src/index.ts` (`email()` handler)
- Modify: `src/lib/deepseek.ts` (DELETE `runDeepseekVisionExtraction` + `callVisionDeepseek`)
- Modify: `src/lib/ocr.ts` (DELETE `workersAiOcr` + `OCR_MODEL` + `OCR_PROMPT`; keep `STUB_OCR_TEXT`)
- Test: `test/inbound.test.ts`

**Interfaces:**
- Consumes: `isProUser` (Task 1), `runGeminiVisionExtraction` (Task 2).
- Produces: `InboundResult` rejected reason union now includes `"pro_only"`.

- [ ] **Step 1: Write the failing tests** — add to `test/inbound.test.ts`:

```ts
// (1) Free owner → bounced pro_only, nothing stored/extracted.
it("bounces a free user's inbound email (pro_only)", async () => {
  // Arrange env+DB so resolveInboxToken returns an owner whose user is FREE,
  // GEMINI_API_KEY set (so the real path would run if not gated).
  const res = await inboundEmailLogic(envFreeOwner, msgWithImage, NOW);
  expect(res).toEqual({ status: "rejected", reason: "pro_only" });
  // No image put, no inbound_email_log row, no Gemini call.
});

// (2) Pro owner → Gemini (mocked) → created.
it("extracts a pro user's inbound email via Gemini", async () => {
  globalThis.fetch = mockGemini({ merchant: "Coles", date: "2026-06-20", currencyCode: "AUD",
    total: 34.87, gst: 0.36, category: "groceries", deductible: 0,
    lineItems: [{ name: "Milk", price: 3.5 }], confidence: 0.9 });
  const res = await inboundEmailLogic(envProOwnerWithKey, msgWithImage, NOW);
  expect(res.status).toBe("created");
  expect((res as any).extraction).toBe("done");
});
```

(Use the existing test's fixture helpers for env/DB/message; mirror how the current inbound tests build `env`/owner rows. Add a `mockGemini` helper returning `{ok:true,status:200,json:async()=>({candidates:[{content:{parts:[{text:JSON.stringify(obj)}]}}]})}`. Set the owner's `users.plan` to `"free"` vs `"pro"` (+ active subscription) in the seeded DB.)

- [ ] **Step 2: Run — expect FAIL** (no `pro_only`; free path still extracts)

Run: `npx vitest run test/inbound.test.ts`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `src/email/inbound.ts`:
- Import `isProUser` from `../lib/plan` and `runGeminiVisionExtraction` from `../lib/deepseek`; drop the `workersAiOcr`/`runDeepseekVisionExtraction` imports.
- Add `"pro_only"` to the rejected reason union.
- In `inboundEmailLogic`, immediately after resolving `owner`:

```ts
  if (!(await isProUser(env.DB, owner.userId))) {
    return { status: "rejected", reason: "pro_only" };
  }
```
  (Place it BEFORE dedup/image/R2 work so free mail is bounced with zero side effects.)
- Change `runExtraction` to use Gemini for the real path; keep the stub gate but key it on `GEMINI_API_KEY`:

```ts
async function runExtraction(env: Env, imageBytes: ArrayBuffer, contentType: string, defaultDate: string) {
  const stubGate = env.E2E_EXTRACT_MODE === "1" || !env.GEMINI_API_KEY;
  if (stubGate) {
    const h = heuristicExtract(STUB_OCR_TEXT, defaultDate);
    return { receipt: { merchant: h.merchant, date: h.date, currencyCode: "AUD", total: h.total,
      gst: h.total === 0 ? null : h.gst, category: h.category, deductible: h.deductible,
      lineItems: h.lineItems, confidence: 0.9, needsReview: false },
      model: env.GEMINI_MODEL ?? "gemini-3.1-flash-lite", usedLlm: false };
  }
  const r = await runGeminiVisionExtraction(env, imageBytes, contentType, defaultDate);
  return { receipt: r.receipt, model: r.meta.model, usedLlm: r.meta.usedLlm };
}
```
- Keep the sanity gate, cap gate, `chargeSlot`/`incrementUsage`, dedup, rate-limit, `logInbound` as-is.

In `src/index.ts` `email()` — extend the reject-reason mapping:
```ts
const reason =
  result.reason === "no_image" ? "No receipt image attached"
  : result.reason === "rate_limited" ? "Too many messages to this address; please try again later"
  : result.reason === "pro_only" ? "Email-in is a Snapceipt Pro feature — upgrade in the app to use it."
  : "Unknown inbox address";
```

In `src/lib/deepseek.ts` — delete `runDeepseekVisionExtraction` + `callVisionDeepseek` (Gemini replaces them). In `src/lib/ocr.ts` — delete `workersAiOcr`, `OCR_MODEL`, `OCR_PROMPT`; keep `STUB_OCR_TEXT`.

- [ ] **Step 4: Run tests — expect PASS** (focused, then full)

Run: `npx vitest run test/inbound.test.ts` then `npx vitest run`
Expected: PASS — no `workersAiOcr`/`runDeepseekVisionExtraction` references remain; full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/email/inbound.ts src/index.ts src/lib/deepseek.ts src/lib/ocr.ts test/inbound.test.ts
git commit -m "feat(email-in): Pro-only via Gemini; bounce free (pro_only); drop DeepSeek-vision + Workers-AI OCR"
```

---

### Task 4: Pro-gate the inbox-alias routes

**Files:**
- Modify: `src/routes/inbox.ts`
- Test: `test/inboxToken.test.ts` (route-level) or the existing inbox route test

**Interfaces:**
- Consumes: `requireProPlan(c)` (existing).

- [ ] **Step 1: Write the failing test** — a free user gets 403 from `GET /profiles/:id/inbox`; a Pro user gets the alias. (Use the existing route-test harness — seed `users.plan` free vs pro+active; `assertOwnedProfile` must still pass, i.e. the profile belongs to the user.)

```ts
it("GET /profiles/:id/inbox is 403 for a free user", async () => {
  const res = await appFetch(freeUserReq(`/profiles/${pid}/inbox`));
  expect(res.status).toBe(403);
});
it("GET /profiles/:id/inbox returns an alias for a pro user", async () => {
  const res = await appFetch(proUserReq(`/profiles/${pid}/inbox`));
  expect(res.status).toBe(200);
  expect((await res.json()).address).toMatch(/@in\.snapceipt\.cc$/);
});
```

- [ ] **Step 2: Run — expect FAIL** (free currently gets 200)

Run: `npx vitest run test/inboxToken.test.ts`
Expected: FAIL — free returns 200.

- [ ] **Step 3: Implement** — in `src/routes/inbox.ts`, import `requireProPlan` and call it after `assertOwnedProfile` in BOTH handlers:

```ts
import { requireProPlan } from "../lib/plan";
// ...inside GET and POST, after assertOwnedProfile(...):
await requireProPlan(c);
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `npx vitest run test/inboxToken.test.ts` then `npx vitest run`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/routes/inbox.ts test/inboxToken.test.ts
git commit -m "feat(inbox): Pro-gate the per-profile alias mint/rotate routes"
```

---

### Task 5: iOS Email-in clean free-user upgrade state

**Files:**
- Modify: `Snapceipt/Features/EmailIn/EmailInView.swift`
- Modify: `Snapceipt/Features/EmailIn/EmailInViewModel.swift` (only if needed to avoid a doomed `loadAddress` for free users)
- Test: `SnapceiptTests/EmailInViewModelTests.swift` (create/extend)

**Interfaces:**
- Consumes: `EntitlementStore.isPro` (already injected into `EmailInView`).

Current behaviour: `EmailInView.task` calls `vm.loadAddress()` then sets `showPaywall = true` when `!entitlement.isPro` — but it still renders the address card (which now 402s for free users → `errorMessage`). Goal: a free user sees a clean "Pro feature — upgrade" surface (not a broken address card), and we don't fire a `loadAddress` call we know will 402.

- [ ] **Step 1: Write the failing test** — `SnapceiptTests/EmailInViewModelTests.swift`: a `loadAddress()` guard so it no-ops / doesn't set `errorMessage` when not entitled. Simplest testable seam: add `func loadAddressIfPro(isPro: Bool)` to the view model that returns early when `!isPro`.

```swift
@Test("loadAddressIfPro no-ops for a free user (no network, no error)")
@MainActor func freeUserSkipsAddressLoad() async {
    let vm = makeVM(api: SpyAPI())          // SpyAPI.profileInbox would throw if called
    await vm.loadAddressIfPro(isPro: false)
    #expect(vm.address == nil)
    #expect(vm.errorMessage == nil)         // no doomed 402 surfaced
}
```

- [ ] **Step 2: Run — expect FAIL** (`loadAddressIfPro` doesn't exist)

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/EmailInViewModelTests`
Expected: FAIL — compile/undefined.

- [ ] **Step 3: Implement**
- `EmailInViewModel`: `func loadAddressIfPro(isPro: Bool) async { guard isPro else { return }; await loadAddress() }`.
- `EmailInView.task`: replace `await vm.loadAddress(); if !entitlement.isPro { showPaywall = true }` with:
```swift
if entitlement.isPro { await vm.loadAddress() } else { showPaywall = true }
```
- `EmailInView.body`: when `!entitlement.isPro`, render an upgrade card (title "Email-in is a Pro feature", subtitle, an "Upgrade to Pro" button that sets `showPaywall = true`) INSTEAD of `addressCard` + the inbox list. Keep `.sheet(isPresented: $showPaywall) { PaywallView() }`.

- [ ] **Step 4: Run tests — expect PASS** (focused, then the capture/email suites)

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/EmailInViewModelTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/EmailIn/EmailInView.swift Snapceipt/Features/EmailIn/EmailInViewModel.swift SnapceiptTests/EmailInViewModelTests.swift
git commit -m "feat(email-in/ios): clean Pro-gate upgrade state; skip doomed address load for free users"
```

---

## Post-implementation (controller, not a task)

1. Whole-branch review (most-capable model) over `feat/email-in-pro-gemini`.
2. Set the prod secret (the key already verified in `.dev.vars`): pipe it without printing —
   `grep '^GEMINI_API_KEY' .dev.vars | tail -1 | cut -d= -f2- | tr -d '"' | npx wrangler@4 secret put GEMINI_API_KEY`.
3. Merge → deploy prod (`npm run deploy`) — this also replaces the currently-broken DeepSeek-vision build. Verify `/health` 200.
4. (Optional) iOS TestFlight when the user is ready — currently held.

## Self-review (done)

- **Spec coverage:** Pro-only (T3/T4/T5) ✓; Gemini extraction (T2) ✓; bounce free (T3 + index.ts) ✓; alias + screen Pro-gated (T4/T5) ✓; remove DeepSeek-vision/OCR (T3) ✓; GEMINI secret/env (T2 + post-impl) ✓; in-app scan untouched (constraint) ✓.
- **Placeholders:** none — each step carries concrete code/commands.
- **Type consistency:** `isProUser(db,userId)` (T1) consumed in T3; `runGeminiVisionExtraction(env,imageBytes,contentType,defaultDate): DeepseekResult` (T2) consumed in T3; `pro_only` reason (T3) mapped in index.ts (T3); `loadAddressIfPro(isPro:)` (T5).
