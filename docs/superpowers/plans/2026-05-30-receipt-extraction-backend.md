# Receipt Extraction Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax.

**Goal:** Implement Plan A (the backend half) of the Snapceipt receipt-capture feature: `POST /extract` (DeepSeek JSON-mode extraction with a deterministic stub seam, a validate/retry ladder, AU-GST inference, and server-computed confidence) plus `POST /images` + `GET /images/*` (raw-JPEG upload to R2 with an FK-safe `receipt_images` link, and an ownership-scoped wildcard read). Every automated test runs hermetically with no DeepSeek key (the stub seam + a mocked `fetch` carry it).

**Architecture:** Smart backend, thin client. All extraction logic lives server-side in the Hono Worker. `POST /extract` is auth-gated and rate-limited under a NEW `extract` tier; it returns the §9 contract response. `src/lib/extractionHeuristic.ts` is the SINGLE deterministic extractor reused by both the dev/E2E stub and the always-invalid fallback. `src/lib/deepseek.ts` is the real client (verbatim system prompt, ≤3-attempt validate/retry ladder, confidence math, 20s timeout) with `fetch` mocked in unit tests. `POST /images` writes raw JPEG bytes to the existing `RECEIPTS` R2 bucket and inserts a `receipt_images` row, setting `transaction_id` only when the parent txn exists for the user (FK-safe). `GET /images/*` is a wildcard route streaming the R2 object after an `u/{userId}/` prefix ownership check.

**Tech Stack:** TypeScript, Hono ^4, zod ^3 + @hono/zod-validator ^0.4.3, Cloudflare Workers (D1 `DB`, KV `KV`, R2 `RECEIPTS`, AI), Vitest ~2.1 + @cloudflare/vitest-pool-workers ^0.5.41 (in-workerd `SELF.fetch` + real bindings), Wrangler ^3 `unstable_dev` for e2e.

**Spec:** `docs/superpowers/specs/2026-05-30-receipt-capture-extraction-design.md` (§1–§4, §9 AUTHORITATIVE, §11 tests, §12 file list, §13 risks). Mirrors the foundation plan style: `docs/superpowers/plans/2026-05-30-backend-foundation.md`.

---

## Canonical Contracts

These pin the authoritative shapes/field-names (spec §9). **Where a task's code or prose disagrees with this section, this section wins.** They are copied here so an implementer never drifts.

**Routes (root-mounted, no `/v1`):**
- `POST /extract` — auth required (NOT in `PUBLIC_PATHS`); rate tier **`extract`** (NEW: `limit: 30, windowMs: 3_600_000, dimension: "user"`). Route in `src/routes/extract.ts`; mounted + rate-limited in `src/app.ts`; tier added to `src/middleware/rateLimit.ts`. The limiter is mounted on BOTH `app.use("/extract", rateLimit("extract"))` AND `app.use("/extract/*", rateLimit("extract"))` — the route serves `POST /extract` at the exact path, and a wildcard-only mount does not reliably match the bare path in Hono v4, so the exact mount guarantees the 429 path engages.
- `POST /images` — auth required; rate tier **`default`**. Limiter mounted on BOTH `app.use("/images", rateLimit("default"))` (exact-path POST) AND `app.use("/images/*", rateLimit("default"))` (wildcard GET reads).
- `GET /images/*` — auth required; **wildcard** route; `key = c.req.path` after the literal `/images/` prefix; ownership = `key` must start with `u/{currentUserId}/`.
- **All `/images` + `/extract` route mounts and limiters live in `src/app.ts` and are added ONCE, in Task 8** (Task 7 implements `src/routes/images.ts` but does NOT touch `app.ts`; its tests run on a standalone Hono app). This keeps all `app.ts` edits in a single task to avoid a cross-task edit collision.

**`POST /extract` request** (`application/json`; `defaultCurrency`/`locale`/`capturedAt`/`requestId` optional with server defaults):
```jsonc
{
  "ocrText": "…",                  // required, non-empty string
  "source": "scan",                // "scan" | "email_in"  (required)
  "defaultCurrency": "AUD",        // optional, default "AUD"
  "locale": "en-AU",               // optional, default "en-AU"
  "capturedAt": "2026-05-28",      // optional, YYYY-MM-DD
  "requestId": "…"                 // optional; echo-only (no server dedupe)
}
```

**`POST /extract` response** `200` (all amounts are **DOLLARS** on the wire; `needsReview` may be true on a 200):
```jsonc
{
  "requestId": "…",                // echoes request.requestId or a server-generated uuidv7
  "receipt": {
    "merchant": "The Grounds",
    "date": "2026-05-28",          // YYYY-MM-DD; falls back to capturedAt/today if unparseable
    "currencyCode": "AUD",
    "total": 42.50,                // number (dollars), >= 0 always
    "gst": 3.86,                   // number (dollars); non-null whenever total > 0; null only when total == 0
    "category": "meals",           // EXACTLY one of the 9 keys (below)
    "deductible": 50,              // 0..100 | null
    "lineItems": [ { "name": "Flat White x2", "price": 9.00 }, { "name": "Big Brekkie", "price": 24.00 } ],
    "confidence": 0.98,            // 0..1, server-computed
    "needsReview": false
  },
  "meta": { "model": "deepseek-chat", "source": "scan", "latencyMs": 812, "attempts": 1, "stub": false }
}
```

**The 9 category keys (the SINGLE source — DeepSeek prompt list AND the Zod enum MUST equal this set):**
`meals, groceries, fuel, software, office, home, health, travel, income`. (Note: `income` is the only positive-amount key on the iOS side; the extractor never returns `custom`.)

**Per-category deductible defaults:** `meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null`.

**GST non-null guarantee:** on a 200, `gst` is non-null whenever `total > 0` — if absent, the server sets `gst = round(total / 11 * 100) / 100` (AU 10% GST is 1/11 of a GST-inclusive total). `gst` is `null` only when `total == 0`. This guarantee holds on EVERY 200 path — the DeepSeek `finalize()`, the heuristic `fallback()`, AND the stub — because the shared `extractionHeuristic` always sets `gst = total > 0 ? round(total/11) : 0` (so the iOS offline `HeuristicParser` path mirrors the same rule). The reviser MUST keep `extractionHeuristic.heuristicExtract`'s `if (gst === null) gst = total > 0 ? roundCents(total / 11) : 0;` branch intact (Task 2 Step 3) so `gst` is never null while `total > 0`.

**Deductible integer guarantee:** on a 200, `deductible` is ALWAYS an integer literal (`0..100`) or `null` — NEVER a float like `50.0`. The Zod schema only enforces integer-VALUED numbers (`z.number().int()` accepts `50.0`), so `finalize()` additionally coerces with `deductible = deductible == null ? null : Math.round(deductible)` before returning. This guarantees the wire emits an integer literal so the iOS `decodeIfPresent(Int.self, forKey: .deductible)` never throws on a `50.0` JSON token.

**Confidence (server-computed, never self-graded):** `finalConfidence = clamp01(0.55·modelStated + 0.25·ocrQuality + 0.20·arithmeticConsistency)`. `modelStated` = the model's own 0..1 (0.7 if absent). `ocrQuality` = heuristic on `ocrText` length/structure. `arithmeticConsistency` = 1 if `sum(lineItems.price) ≈ total` (±5%), else 0.5. **`needsReview = finalConfidence < 0.80 || validationFellBack`.**

**Validate/retry ladder (≤3 attempts):** (1) parse + Zod-validate; (2) on invalid → one corrective re-prompt including the validation errors; (3) on still-invalid → strip ``` fences / extract the first `{…}` and re-validate; (4) on exhaustion → the deterministic heuristic **fallback** (`category: "office"`, `deductible: 100`, `gst = round(total/11)`, `needsReview: true`, low `confidence ~0.4`).

**Stub gate:** when `env.E2E_EXTRACT_MODE === "1"` **OR** `!env.DEEPSEEK_API_KEY`, skip the network call and return a deterministic extraction from the SAME heuristic, but `needsReview: false`, `confidence: 0.9`, `meta.stub: true`. **For the stub path, `meta.attempts = 0`** (no network attempt was made — `0` is a legal `meta.attempts` value the iOS `ExtractionMeta` must accept). Gated exactly like the existing `E2E_TEST_MODE` magic-link seam.

**`meta` field set (spec §9, pinned here because the §9 mapping table omits `meta.*`):** every `200` carries `meta = { model: string, source: "scan"|"email_in" (echoes request.source), latencyMs: number, attempts: number (>=0; 0 on the stub path), stub: boolean }`. iOS `ExtractionMeta` decodes all five; the backend emits all five. `meta.source` is echo-only (iOS decodes but does not branch on it).

**Env additions** (`src/env.ts` `Env`): add `E2E_EXTRACT_MODE?: string` and `DEEPSEEK_MODEL?: string` (default `"deepseek-chat"` resolved in code). `DEEPSEEK_API_KEY: string` already present (declared as required; treat empty/undefined as "no key" via the gate).

**DeepSeek call (real path):** `POST https://api.deepseek.com/chat/completions`, header `Authorization: Bearer ${env.DEEPSEEK_API_KEY}`, body `{ model: env.DEEPSEEK_MODEL ?? "deepseek-chat", response_format: { type: "json_object" }, temperature: 0, max_tokens: 1500, messages: [system, user] }`. Both prompts contain the word "json". 20s hard timeout (`AbortController`). `meta.model` = the resolved model id.

**`POST /images`:** body = raw `image/jpeg` bytes. All metadata is **URL query params** (never headers): `transactionId?`, `pageIndex` (default 0), `width?`, `height?`, `ocrText?` (capped). Worker (1) validates content-type `image/jpeg` and `byteSize ≤ 6_291_456` (6 MiB); (2) `RECEIPTS.put("u/{userId}/{uuid}.jpg", body, { httpMetadata: { contentType: "image/jpeg" } })`; (3) sets `receipt_images.transaction_id = transactionId` ONLY if a `transactions` row with that id exists for this `userId`, else NULL; (4) inserts the `receipt_images` row (existing table columns); (5) returns `{ imageKey, getUrl, byteSize }` where `imageKey` = the FULL key `u/{userId}/{uuid}.jpg` and `getUrl = "/images/" + imageKey`.

**`receipt_images` columns** (existing, `migrations/0001_init.sql`): `id, user_id, profile_id, transaction_id, r2_key, thumb_r2_key, content_type, byte_size, width, height, page_index, ocr_text, ocr_source, extraction_json, extraction_model, source, created_at, updated_at, deleted_at, rev, last_edited_device_id`. `ocr_source` CHECK ∈ `('vision_on_device','workers_ai')` or NULL; `source` CHECK ∈ `('scan','email_in')`. For `/images` v1: `profile_id` NULL, `thumb_r2_key` NULL, `ocr_source = 'vision_on_device'`, `extraction_json`/`extraction_model` NULL, `source = 'scan'`, `deleted_at` NULL, `rev = 0`, `last_edited_device_id = c.var.deviceId`.

**`GET /images/*`:** read `key = c.req.path.slice("/images/".length)`. Ownership: `key` must start with `u/{currentUserId}/`, else `404`. Stream the R2 object with its content-type; missing object → `404`.

**Errors:** `400` invalid body (Zod VALIDATION_FAILED), `401` no/expired auth, `429` rate limited. `/extract` essentially always produces a usable `200` (the fallback is local — no `502` path in v1).

**Existing conventions to mirror (verified against real code):**
- `src/app.ts` mounts middleware/routes at **module scope** (no factory). Auth is applied once via `app.use("*", authMiddleware())`; per-class limiters are `app.use("/prefix/*", rateLimit(kind))` mounted AFTER `authMiddleware` so `c.var.userId` is set. For routes whose handler is registered at the group root (`POST /extract`, `POST /images` — i.e. the EXACT prefix path with no trailing segment), ALSO mount `app.use("/prefix", rateLimit(kind))` so the limiter runs for the bare path (the `/*` wildcard alone does not reliably match it in Hono v4).
- Route files export a `new Hono<AppEnv>()` instance (e.g. `export const extractRoutes = ...`).
- `validate(target, schema)` (exported from `src/routes/auth.ts`) wraps `zValidator` so failures throw `ApiError("VALIDATION_FAILED", …)`.
- Errors use `throw new ApiError(code, message, details?)` from `src/lib/errors.ts`; success bodies are unwrapped via `c.json(...)`.
- Ids via `uuidv7()` (`src/lib/ids.ts`); time via `nowMs()` (`src/lib/time.ts`).
- Tests run in-workerd: `import { env, SELF } from "cloudflare:test"`; auth tokens are minted by seeding a user+device and calling `issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY })` (returns `{ accessToken, … }`).
- e2e files live under `e2e/*.e2e.test.ts`, run via `npm run test:e2e` (Node env, `unstable_dev`), and apply migrations to an isolated persist dir before booting.

---

## Tasks

### Task 1: Env additions — `E2E_EXTRACT_MODE?`, `DEEPSEEK_MODEL?`

Goal: extend the `Env` type so the stub gate and the DeepSeek model id are typed. Pure type change; verified by `tsc`.

**Files**
- Modify: `src/env.ts`

---

- [ ] **Step 1: Add the two optional fields to `Env`.**

In `src/env.ts`, the `Env` type already has `DEEPSEEK_API_KEY: string;` and the `E2E_TEST_MODE?: string;` doc-commented seam. Add `DEEPSEEK_MODEL?` next to `DEEPSEEK_API_KEY`, and `E2E_EXTRACT_MODE?` next to `E2E_TEST_MODE`.

Replace this block:
```ts
  /** Secret: DeepSeek API key (unused this phase). */
  DEEPSEEK_API_KEY: string;
```
with:
```ts
  /** Secret: DeepSeek API key. When empty/undefined, /extract uses the stub seam. */
  DEEPSEEK_API_KEY: string;
  /**
   * Var: DeepSeek model id used in the request body + echoed as meta.model.
   * Optional; the route falls back to "deepseek-chat" when unset.
   */
  DEEPSEEK_MODEL?: string;
```

Then, immediately after the `E2E_TEST_MODE?: string;` field (the last field before the closing `};`), add:
```ts
  /**
   * E2E-ONLY extraction seam. When set to "1", POST /extract skips the DeepSeek
   * network call and returns a deterministic stub from extractionHeuristic
   * (needsReview:false, confidence:0.9, meta.stub:true). Also auto-engaged when
   * DEEPSEEK_API_KEY is empty/undefined. MUST be undefined in production with a
   * real key — never declared in wrangler.jsonc; only injected by the e2e harness.
   */
  E2E_EXTRACT_MODE?: string;
```

- [ ] **Step 2: Typecheck.**

```bash
npx tsc --noEmit
```
Expected (PASS): exits 0 with no output. No runtime behavior changed yet.

- [ ] **Step 3: Commit.**

```bash
git add src/env.ts
git commit -m "$(cat <<'EOF'
feat(extract): add E2E_EXTRACT_MODE + DEEPSEEK_MODEL to Env

E2E_EXTRACT_MODE gates the deterministic /extract stub seam (mirrors the
E2E_TEST_MODE magic-link seam); DEEPSEEK_MODEL is the model id sent to
DeepSeek and echoed as meta.model (defaults to "deepseek-chat" in code).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Deterministic heuristic extractor (`extractionHeuristic.ts`) + unit tests

Goal: the SINGLE deterministic extractor reused by both the dev/E2E stub and the always-invalid fallback. Given `ocrText` (+ a default date) it produces a `HeuristicReceipt` with `merchant` (first letter-rich line), `total` (largest **cents-bearing** dollar amount — see below), `date` (parsed AU date or the fallback), `gst` (printed GST line if found, else `round(total/11)`), `lineItems` (name+price pairs), `category: "office"`, `deductible: 100`. Pure + dependency-free; TDD.

**Total-selection safety:** the total scan only considers amounts that carry a `.NN` cents component (e.g. `42.50`), and it SKIPS any line that `parseDate` matches. This prevents a bare 4-digit integer (a year like `2026`, a postcode, or an ABN like `12 345 678 901`) from being mis-selected as the total when it is larger than the real grand total. Bare integers still seed `lineItems`/GST detection only when the line is otherwise a valid item; they are never total candidates.

**Files**
- Create: `src/lib/extractionHeuristic.ts`
- Test: `test/extractionHeuristic.test.ts`

---

- [ ] **Step 1: Write the failing unit test FIRST.**

```ts
// test/extractionHeuristic.test.ts
import { describe, expect, it } from "vitest";
import { heuristicExtract, type HeuristicReceipt } from "../src/lib/extractionHeuristic";

const SAMPLE = [
  "THE GROUNDS",
  "28/05/2026",
  "Flat White x2  9.00",
  "Big Brekkie 24.00",
  "GST 3.86",
  "TOTAL 42.50",
].join("\n");

describe("heuristicExtract()", () => {
  it("picks the first letter-rich line as the merchant", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.merchant).toBe("THE GROUNDS");
  });

  it("picks the largest dollar amount as the total", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.total).toBe(42.5);
  });

  it("does NOT pick a bare 4-digit year/ABN/postcode as the total (cents-bearing only, date lines skipped)", () => {
    // The date line carries 2026 and the ABN carries 12345678901 — both larger
    // than the real total (42.50), but neither has a .NN cents component and the
    // date line is skipped, so total stays 42.50.
    const withNoise = [
      "THE GROUNDS",
      "ABN 12 345 678 901",
      "28/05/2026",
      "Flat White x2  9.00",
      "Big Brekkie 24.00",
      "GST 3.86",
      "TOTAL 42.50",
    ].join("\n");
    const r = heuristicExtract(withNoise, "2026-05-30");
    expect(r.total).toBe(42.5);
  });

  it("does NOT let a year on the date line become the total even when no item is larger", () => {
    // Only a small cents-bearing total (10.00) plus a date line containing 2026.
    const r = heuristicExtract("WIDGET CO\n28/05/2026\nTOTAL 10.00", "2026-01-02");
    expect(r.total).toBe(10.0);
  });

  it("parses a DD/MM/YYYY AU date to YYYY-MM-DD", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.date).toBe("2026-05-28");
  });

  it("uses the printed GST line when present", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.gst).toBe(3.86);
  });

  it("infers GST as round(total/11) when no GST line is printed", () => {
    const noGst = ["CAFE X", "Coffee 5.00", "TOTAL 11.00"].join("\n");
    const r = heuristicExtract(noGst, "2026-05-30");
    expect(r.gst).toBe(1); // 11/11 = 1.00
  });

  it("falls back to the provided default date when none is parseable", () => {
    const r = heuristicExtract("WIDGET CO\nTOTAL 10.00", "2026-01-02");
    expect(r.date).toBe("2026-01-02");
  });

  it("always returns category 'office' and deductible 100 (the safe fallback)", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    expect(r.category).toBe("office");
    expect(r.deductible).toBe(100);
  });

  it("extracts line items as {name, price} pairs (excludes the GST/TOTAL summary lines)", () => {
    const r = heuristicExtract(SAMPLE, "2026-05-30");
    const names = r.lineItems.map((li) => li.name);
    expect(names).toContain("Flat White x2");
    expect(names).toContain("Big Brekkie");
    expect(names).not.toContain("TOTAL");
    expect(names).not.toContain("GST");
  });

  it("never returns a negative total and clamps empty input to a zero receipt", () => {
    const r = heuristicExtract("", "2026-05-30");
    expect(r.total).toBe(0);
    expect(r.gst).toBe(0);
    expect(r.merchant).toBe("");
    expect(r.lineItems).toEqual([]);
  });

  it("rounds GST to cents", () => {
    const r = heuristicExtract("SHOP\nTOTAL 100.00", "2026-05-30");
    expect(r.gst).toBe(9.09); // 100/11 = 9.0909 -> 9.09
  });
});

// Type guard: the shape the stub + fallback consume.
const _typecheck: HeuristicReceipt = {
  merchant: "",
  date: "2026-05-30",
  total: 0,
  gst: 0,
  category: "office",
  deductible: 100,
  lineItems: [],
};
void _typecheck;
```

- [ ] **Step 2: Run it and watch it FAIL (module missing).**

```bash
npx vitest run test/extractionHeuristic.test.ts
```
Expected (FAIL): `Failed to resolve import "../src/lib/extractionHeuristic"` — the module does not exist yet.

- [ ] **Step 3: Implement `src/lib/extractionHeuristic.ts`.**

```ts
// src/lib/extractionHeuristic.ts
// The SINGLE deterministic receipt extractor, reused by BOTH the dev/E2E stub
// (POST /extract when no DeepSeek key) AND the always-invalid fallback at the
// end of the DeepSeek retry ladder. Pure + dependency-free: same input ->
// same output, so the stub seam is fully reproducible in tests.

export interface HeuristicLineItem {
  name: string;
  price: number;
}

export interface HeuristicReceipt {
  merchant: string;
  date: string; // YYYY-MM-DD
  total: number; // dollars, >= 0
  gst: number; // dollars (printed line or round(total/11)); 0 when total == 0
  category: "office"; // the safe-fallback category
  deductible: 100; // the safe-fallback deductible
  lineItems: HeuristicLineItem[];
}

/** Round to 2dp avoiding binary float drift (e.g. 9.0909 -> 9.09). */
function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

/** A line that contains at least one ASCII letter (used to pick the merchant). */
function isLetterRich(line: string): boolean {
  return /[A-Za-z]/.test(line) && line.trim().length >= 2;
}

/** Parse the FIRST dollar-ish amount in a line, e.g. "Coffee $5.00" -> 5. */
function amountIn(line: string): number | null {
  const m = line.match(/(?:\$\s*)?(\d{1,7}(?:,\d{3})*(?:\.\d{1,2})?)/);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/**
 * Parse the FIRST amount that carries an explicit `.NN` cents component, e.g.
 * "TOTAL 42.50" -> 42.5, but "ABN 12 345 678 901" / "2026" -> null. Used ONLY
 * for total selection so a bare 4-digit year/ABN/postcode can never be chosen
 * as the grand total.
 */
function centsAmountIn(line: string): number | null {
  const m = line.match(/(?:\$\s*)?(\d{1,7}(?:,\d{3})*\.\d{2})\b/);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

/** Parse a DD/MM/YYYY (or DD-MM-YYYY) or an already-ISO date to YYYY-MM-DD. */
function parseDate(text: string): string | null {
  const iso = text.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const au = text.match(/\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b/);
  if (au) {
    let [, d, mo, y] = au;
    if (y.length === 2) y = `20${y}`;
    const dd = d.padStart(2, "0");
    const mm = mo.padStart(2, "0");
    if (Number(mm) >= 1 && Number(mm) <= 12 && Number(dd) >= 1 && Number(dd) <= 31) {
      return `${y}-${mm}-${dd}`;
    }
  }
  return null;
}

/** Lines that are summary/metadata, not purchasable line items. */
function isSummaryLine(line: string): boolean {
  return /\b(total|subtotal|gst|tax|change|cash|eftpos|balance|amount\s*due|tendered)\b/i.test(
    line,
  );
}

export function heuristicExtract(ocrText: string, defaultDate: string): HeuristicReceipt {
  const rawLines = ocrText.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);

  // Merchant: the first letter-rich line that isn't a pure date/amount.
  let merchant = "";
  for (const line of rawLines) {
    if (isLetterRich(line) && parseDate(line) === null) {
      merchant = line;
      break;
    }
  }

  // Total: the largest CENTS-BEARING dollar amount anywhere in the text (>= 0).
  // Cents-only (centsAmountIn) + skipping any date line prevents a bare 4-digit
  // year/ABN/postcode (e.g. 2026 on "28/05/2026", or an ABN) from being picked
  // as the total when it happens to exceed the real grand total.
  let total = 0;
  for (const line of rawLines) {
    if (parseDate(line) !== null) continue; // never read a total off a date line
    const a = centsAmountIn(line);
    if (a !== null && a > total) total = a;
  }
  total = roundCents(Math.max(0, total));

  // Date: first parseable date, else the caller-provided default (capturedAt/today).
  let date = defaultDate;
  for (const line of rawLines) {
    const d = parseDate(line);
    if (d) {
      date = d;
      break;
    }
  }

  // GST: a printed GST/tax line wins; otherwise infer round(total/11).
  let gst: number | null = null;
  for (const line of rawLines) {
    if (/\b(gst|tax)\b/i.test(line)) {
      const a = amountIn(line);
      if (a !== null) {
        gst = roundCents(a);
        break;
      }
    }
  }
  if (gst === null) gst = total > 0 ? roundCents(total / 11) : 0;

  // Line items: letter-rich, non-summary lines that carry an amount.
  const lineItems: HeuristicLineItem[] = [];
  for (const line of rawLines) {
    if (line === merchant) continue;
    if (isSummaryLine(line)) continue;
    if (!isLetterRich(line)) continue;
    const price = amountIn(line);
    if (price === null) continue;
    const name = line
      .replace(/(?:\$\s*)?\d{1,7}(?:,\d{3})*(?:\.\d{1,2})?/g, "")
      .replace(/\s{2,}/g, " ")
      .trim();
    if (name.length === 0) continue;
    lineItems.push({ name, price: roundCents(price) });
  }

  return {
    merchant,
    date,
    total,
    gst,
    category: "office",
    deductible: 100,
    lineItems,
  };
}
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/extractionHeuristic.test.ts
```
Expected (PASS): `Test Files  1 passed (1)`; all cases green (merchant, largest-total, **year/ABN/postcode NOT chosen as total**, **year-on-date-line NOT chosen as total**, AU-date parse, printed-vs-inferred GST, default-date fallback, fixed category/deductible, line-item extraction excluding GST/TOTAL, empty-input zero receipt, cents rounding).

- [ ] **Step 5: Typecheck + commit.**

```bash
npx tsc --noEmit && git add src/lib/extractionHeuristic.ts test/extractionHeuristic.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): deterministic heuristic extractor (stub + fallback source)

Add src/lib/extractionHeuristic.ts: a pure, dependency-free extractor that
picks merchant (first letter-rich line), total (largest amount), date (AU
DD/MM/YYYY or ISO, else the provided default), GST (printed line or
round(total/11)), and line items. Fixed safe-fallback category "office" /
deductible 100. Reused by the /extract dev stub AND the retry-ladder
fallback. Covered by test/extractionHeuristic.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Zod schemas (`src/schemas/extract.ts`) — request + receipt + category enum

Goal: the request schema (`ocrText` + `source` required; `defaultCurrency`/`locale`/`capturedAt`/`requestId` optional with defaults) and the receipt schema the DeepSeek output is validated against (the category enum = the 9 keys, ranges enforced). TDD against the Zod parse behavior.

**Files**
- Create: `src/schemas/extract.ts`
- Test: `test/extract-schema.test.ts`

---

- [ ] **Step 1: Write the failing schema test FIRST.**

```ts
// test/extract-schema.test.ts
import { describe, expect, it } from "vitest";
import {
  extractRequestSchema,
  deepseekReceiptSchema,
  CATEGORY_KEYS,
} from "../src/schemas/extract";

describe("extractRequestSchema", () => {
  it("requires ocrText + source and applies server defaults to the optional fields", () => {
    const parsed = extractRequestSchema.parse({ ocrText: "X", source: "scan" });
    expect(parsed.defaultCurrency).toBe("AUD");
    expect(parsed.locale).toBe("en-AU");
    expect(parsed.capturedAt).toBeUndefined();
    expect(parsed.requestId).toBeUndefined();
  });

  it("rejects an empty ocrText", () => {
    expect(extractRequestSchema.safeParse({ ocrText: "", source: "scan" }).success).toBe(false);
  });

  it("rejects an unknown source", () => {
    expect(
      extractRequestSchema.safeParse({ ocrText: "X", source: "fax" }).success,
    ).toBe(false);
  });

  it("accepts email_in as a source and a provided capturedAt + requestId", () => {
    const parsed = extractRequestSchema.parse({
      ocrText: "X",
      source: "email_in",
      capturedAt: "2026-05-28",
      requestId: "abc",
    });
    expect(parsed.source).toBe("email_in");
    expect(parsed.capturedAt).toBe("2026-05-28");
    expect(parsed.requestId).toBe("abc");
  });

  it("rejects a malformed capturedAt", () => {
    expect(
      extractRequestSchema.safeParse({ ocrText: "X", source: "scan", capturedAt: "28-05-2026" })
        .success,
    ).toBe(false);
  });
});

describe("CATEGORY_KEYS", () => {
  it("is exactly the 9 keys (no 'custom')", () => {
    expect(CATEGORY_KEYS).toEqual([
      "meals",
      "groceries",
      "fuel",
      "software",
      "office",
      "home",
      "health",
      "travel",
      "income",
    ]);
  });
});

describe("deepseekReceiptSchema", () => {
  const valid = {
    merchant: "The Grounds",
    date: "2026-05-28",
    currencyCode: "AUD",
    total: 42.5,
    gst: 3.86,
    category: "meals",
    deductible: 50,
    lineItems: [{ name: "Flat White", price: 9 }],
    confidence: 0.98,
  };

  it("accepts a well-formed DeepSeek receipt", () => {
    expect(deepseekReceiptSchema.safeParse(valid).success).toBe(true);
  });

  it("rejects an out-of-set category", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, category: "custom" }).success).toBe(false);
  });

  it("accepts a null gst (model omitted it) and a null deductible", () => {
    const r = deepseekReceiptSchema.parse({ ...valid, gst: null, deductible: null });
    expect(r.gst).toBeNull();
    expect(r.deductible).toBeNull();
  });

  it("rejects a negative total", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, total: -1 }).success).toBe(false);
  });

  it("rejects a deductible outside 0..100", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, deductible: 150 }).success).toBe(false);
  });

  it("rejects a confidence outside 0..1", () => {
    expect(deepseekReceiptSchema.safeParse({ ...valid, confidence: 2 }).success).toBe(false);
  });

  it("defaults confidence to undefined-tolerant (optional) when absent", () => {
    const { confidence, ...noConf } = valid;
    const parsed = deepseekReceiptSchema.parse(noConf);
    expect(parsed.confidence).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/extract-schema.test.ts
```
Expected (FAIL): `Failed to resolve import "../src/schemas/extract"`.

- [ ] **Step 3: Implement `src/schemas/extract.ts`.**

```ts
// src/schemas/extract.ts
import { z } from "zod";

/**
 * The 9 canonical category keys (spec §9). This array is the SINGLE source for:
 *  - the Zod enum below (validates DeepSeek output + the response), and
 *  - the verbatim list embedded in the DeepSeek system prompt (src/lib/deepseek.ts).
 * It deliberately EXCLUDES "custom" — the extractor never returns it.
 */
export const CATEGORY_KEYS = [
  "meals",
  "groceries",
  "fuel",
  "software",
  "office",
  "home",
  "health",
  "travel",
  "income",
] as const;

export type CategoryKey = (typeof CATEGORY_KEYS)[number];

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");

/**
 * POST /extract request body. ocrText + source are required; the rest carry
 * server defaults so the 3-arg iOS client (ocrText, source, capturedAt) is valid.
 * requestId is echo-only (no server dedupe in v1).
 */
export const extractRequestSchema = z.object({
  ocrText: z.string().min(1, "ocrText is required"),
  source: z.enum(["scan", "email_in"]),
  defaultCurrency: z.string().length(3).default("AUD"),
  locale: z.string().min(2).default("en-AU"),
  capturedAt: isoDate.optional(),
  requestId: z.string().min(1).max(200).optional(),
});

export type ExtractRequest = z.infer<typeof extractRequestSchema>;

/**
 * The shape DeepSeek is asked to emit (and what each retry attempt is validated
 * against). category MUST be one of the 9 keys; total >= 0; gst/deductible
 * nullable; confidence optional 0..1 (the server recomputes it regardless).
 */
export const deepseekReceiptSchema = z.object({
  merchant: z.string(),
  date: isoDate,
  currencyCode: z.string().length(3),
  total: z.number().nonnegative(),
  gst: z.number().nullable(),
  category: z.enum(CATEGORY_KEYS),
  // NOTE: `.int()` accepts integer-VALUED floats (50.0 passes, 33.3 is rejected).
  // The wire-level integer guarantee (no `50.0` token) is enforced in
  // deepseek.finalize() via Math.round, so the iOS Int? decode never throws.
  deductible: z.number().int().min(0).max(100).nullable(),
  lineItems: z
    .array(z.object({ name: z.string(), price: z.number() }))
    .default([]),
  confidence: z.number().min(0).max(1).optional(),
});

export type DeepseekReceipt = z.infer<typeof deepseekReceiptSchema>;
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/extract-schema.test.ts
```
Expected (PASS): all cases green (required fields, defaults, source enum, capturedAt regex, the 9-key enum rejecting `custom`, nullable gst/deductible, range guards, optional confidence).

- [ ] **Step 5: Typecheck + commit.**

```bash
npx tsc --noEmit && git add src/schemas/extract.ts test/extract-schema.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): Zod request + receipt schemas with the 9-key category enum

Add src/schemas/extract.ts: extractRequestSchema (ocrText+source required,
defaultCurrency/locale defaulting, optional capturedAt/requestId),
deepseekReceiptSchema (category enum = the 9 keys, total>=0, nullable
gst/deductible, optional 0..1 confidence), and the CATEGORY_KEYS source
array shared with the DeepSeek prompt. Covered by test/extract-schema.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: DeepSeek client (`src/lib/deepseek.ts`) — prompt, retry ladder, confidence, timeout (fetch mocked)

Goal: the real DeepSeek client. Builds the verbatim system prompt (the 9 keys + per-category deductible defaults), calls the chat-completions endpoint (JSON mode, temp 0, 20s timeout), runs the ≤3-attempt validate/retry ladder (valid→1 attempt; invalid-then-valid→2; always-invalid→heuristic fallback with `needsReview:true`), computes server confidence, and infers AU GST. `fetch` is mocked in tests (no key, no network). The function returns the §9 `receipt` + `meta` halves the route assembles.

**Files**
- Create: `src/lib/deepseek.ts`
- Test: `test/deepseek.test.ts`

---

- [ ] **Step 1: Write the failing test FIRST (fetch mocked via `vi.stubGlobal`).**

```ts
// test/deepseek.test.ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { runDeepseekExtraction } from "../src/lib/deepseek";

const ENV = {
  DEEPSEEK_API_KEY: "sk-test",
  DEEPSEEK_MODEL: "deepseek-chat",
} as unknown as import("../src/env").Env;

const OCR = ["THE GROUNDS", "28/05/2026", "Flat White 9.00", "Big Brekkie 24.00", "TOTAL 33.00"].join(
  "\n",
);

/** A DeepSeek chat-completions response wrapping the given content string. */
function chatResponse(content: string): Response {
  return new Response(
    JSON.stringify({ choices: [{ message: { content } }] }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
}

const VALID_CONTENT = JSON.stringify({
  merchant: "The Grounds",
  date: "2026-05-28",
  currencyCode: "AUD",
  total: 33.0,
  gst: 3.0,
  category: "meals",
  deductible: 50,
  lineItems: [
    { name: "Flat White", price: 9.0 },
    { name: "Big Brekkie", price: 24.0 },
  ],
  confidence: 0.95,
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("runDeepseekExtraction()", () => {
  it("returns the parsed receipt in ONE attempt for valid JSON", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(out.meta.attempts).toBe(1);
    expect(out.meta.model).toBe("deepseek-chat");
    expect(out.meta.stub).toBe(false);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.category).toBe("meals");
    expect(out.receipt.needsReview).toBe(false); // arithmetic consistent + high model conf
  });

  it("retries once on invalid-then-valid (2 attempts)", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(chatResponse("not json at all"))
      .mockResolvedValueOnce(chatResponse(VALID_CONTENT));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(out.meta.attempts).toBe(2);
    expect(out.receipt.category).toBe("meals");
  });

  it("strips ``` fences and extracts the first {…} on attempt 3 before falling back", async () => {
    const fenced = "```json\n" + VALID_CONTENT + "\n```";
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(chatResponse("garbage"))
      .mockResolvedValueOnce(chatResponse("still garbage"))
      .mockResolvedValueOnce(chatResponse(fenced));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(out.receipt.merchant).toBe("The Grounds");
    expect(out.receipt.needsReview).toBe(false);
  });

  it("falls back to the heuristic with needsReview when always invalid (<=3 attempts)", async () => {
    const fetchMock = vi.fn().mockResolvedValue(chatResponse("never valid json"));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(out.receipt.needsReview).toBe(true);
    expect(out.receipt.category).toBe("office"); // heuristic fallback default
    expect(out.receipt.deductible).toBe(100);
    expect(out.receipt.confidence).toBeLessThan(0.8);
    expect(out.receipt.total).toBe(33.0); // largest amount from OCR
  });

  it("infers AU GST = round(total/11) when the model returns gst:null and total>0", async () => {
    const noGst = JSON.stringify({
      merchant: "Cafe", date: "2026-05-28", currencyCode: "AUD",
      total: 11.0, gst: null, category: "meals", deductible: 50,
      lineItems: [{ name: "Coffee", price: 11.0 }], confidence: 0.9,
    });
    const fetchMock = vi.fn().mockResolvedValue(chatResponse(noGst));
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: "Cafe\nCoffee 11.00", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.gst).toBe(1); // 11/11
  });

  it("keeps gst null only when total is 0", async () => {
    const zero = JSON.stringify({
      merchant: "Refund", date: "2026-05-28", currencyCode: "AUD",
      total: 0, gst: null, category: "income", deductible: null,
      lineItems: [], confidence: 0.9,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(zero)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Refund", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.gst).toBeNull();
    expect(out.receipt.total).toBe(0);
  });

  it("coerces deductible to an integer (model 50.0 -> integer-valued 50, never a float)", async () => {
    const floaty = JSON.stringify({
      merchant: "Cafe", date: "2026-05-28", currencyCode: "AUD",
      total: 11.0, gst: 1.0, category: "meals", deductible: 50.0,
      lineItems: [{ name: "Coffee", price: 11.0 }], confidence: 0.9,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(floaty)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Cafe\nCoffee 11.00", source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.deductible).toBe(50);
    expect(Number.isInteger(out.receipt.deductible)).toBe(true);
  });

  it("lowers confidence + flips needsReview when line items don't sum to total", async () => {
    const mismatch = JSON.stringify({
      merchant: "Shop", date: "2026-05-28", currencyCode: "AUD",
      total: 100.0, gst: 9.09, category: "office", deductible: 100,
      lineItems: [{ name: "Thing", price: 5.0 }], confidence: 0.6,
    });
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(chatResponse(mismatch)));
    const out = await runDeepseekExtraction(ENV, { ocrText: "Shop\nThing 5.00\nTOTAL 100.00", source: "scan", defaultDate: "2026-05-30" });
    // 0.55*0.6 + 0.25*ocrQuality + 0.20*0.5 -> below 0.8
    expect(out.receipt.confidence).toBeLessThan(0.8);
    expect(out.receipt.needsReview).toBe(true);
  });

  it("aborts and falls back when the request times out (20s budget)", async () => {
    // Simulate fetch rejecting with an AbortError on every attempt.
    const abortErr = Object.assign(new Error("aborted"), { name: "AbortError" });
    const fetchMock = vi.fn().mockRejectedValue(abortErr);
    vi.stubGlobal("fetch", fetchMock);

    const out = await runDeepseekExtraction(ENV, { ocrText: OCR, source: "scan", defaultDate: "2026-05-30" });
    expect(out.receipt.needsReview).toBe(true);
    expect(out.receipt.category).toBe("office");
  });
});
```

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/deepseek.test.ts
```
Expected (FAIL): `Failed to resolve import "../src/lib/deepseek"`.

- [ ] **Step 3: Implement `src/lib/deepseek.ts`.**

```ts
// src/lib/deepseek.ts
import type { Env } from "../env";
import {
  deepseekReceiptSchema,
  type DeepseekReceipt,
} from "../schemas/extract";
import { heuristicExtract } from "./extractionHeuristic";

const DEEPSEEK_URL = "https://api.deepseek.com/chat/completions";
const TIMEOUT_MS = 20_000;
const MAX_ATTEMPTS = 3;

/** Per-category deductible defaults (spec §9), used to backfill when the model omits one. */
const DEDUCTIBLE_DEFAULTS: Record<string, number | null> = {
  meals: 50,
  groceries: 0,
  fuel: 100,
  software: 100,
  office: 100,
  home: 50,
  health: 0,
  travel: 100,
  income: null,
};

/**
 * VERBATIM system prompt. The 9-key list here MUST equal CATEGORY_KEYS
 * (src/schemas/extract.ts). Both prompts contain the word "json" (DeepSeek JSON
 * mode requires it).
 */
const SYSTEM_PROMPT = [
  "You extract structured data from noisy Australian receipt OCR text. Respond with ONLY a json object, no prose, no markdown fences:",
  '{ "merchant": string, "date": "YYYY-MM-DD", "currencyCode": "AUD", "total": number, "gst": number|null, "category": one of ["meals","groceries","fuel","software","office","home","health","travel","income"], "deductible": number 0-100|null, "lineItems": [{"name": string, "price": number}], "confidence": number 0-1 }',
  'Rules: AUD only. `category` MUST be exactly one of the nine keys above (no others). If GST isn\'t printed, set `gst` to total/11 rounded to cents. Set `deductible` to the per-category default unless the receipt clearly implies otherwise: meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null. `total` is the GST-inclusive grand total as a positive number. Use `income` only for money received.',
].join("\n");

export interface ExtractionInput {
  ocrText: string;
  source: "scan" | "email_in";
  defaultDate: string; // capturedAt or today, used for the date fallback
}

/** The §9 receipt half (server-finalized). */
export interface ExtractedReceipt {
  merchant: string;
  date: string;
  currencyCode: string;
  total: number;
  gst: number | null;
  category: string;
  deductible: number | null;
  lineItems: { name: string; price: number }[];
  confidence: number;
  needsReview: boolean;
}

export interface DeepseekResult {
  receipt: ExtractedReceipt;
  meta: { model: string; attempts: number; stub: false };
}

function clamp01(n: number): number {
  return Math.max(0, Math.min(1, n));
}
function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Heuristic OCR-quality score from length + line structure (0..1). */
function ocrQuality(ocrText: string): number {
  const len = ocrText.trim().length;
  const lines = ocrText.split(/\r?\n/).filter((l) => l.trim().length > 0).length;
  const lenScore = clamp01(len / 200); // ~200 chars reads as a full receipt
  const lineScore = clamp01(lines / 6); // ~6 lines reads as structured
  return clamp01(0.5 * lenScore + 0.5 * lineScore);
}

/** arithmeticConsistency: 1 when line items sum within 5% of total, else 0.5. */
function arithmeticConsistency(lineItems: { price: number }[], total: number): number {
  if (lineItems.length === 0 || total <= 0) return 0.5;
  const sum = lineItems.reduce((acc, li) => acc + li.price, 0);
  const diff = Math.abs(sum - total);
  return diff <= total * 0.05 ? 1 : 0.5;
}

/** Try to coerce a model string into a validated DeepseekReceipt; null on failure. */
function tryParseReceipt(content: string): DeepseekReceipt | null {
  // (a) direct parse
  let obj: unknown;
  try {
    obj = JSON.parse(content);
  } catch {
    // (b) strip ``` fences / extract the first {...}
    const fenceless = content.replace(/```(?:json)?/gi, "").replace(/```/g, "");
    const match = fenceless.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try {
      obj = JSON.parse(match[0]);
    } catch {
      return null;
    }
  }
  const parsed = deepseekReceiptSchema.safeParse(obj);
  return parsed.success ? parsed.data : null;
}

/** One DeepSeek call with a 20s abort budget. Returns the message content, or null on any failure. */
async function callDeepseek(env: Env, model: string, messages: { role: string; content: string }[]): Promise<string | null> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(DEEPSEEK_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.DEEPSEEK_API_KEY}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model,
        response_format: { type: "json_object" },
        temperature: 0,
        max_tokens: 1500,
        messages,
      }),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    const json = (await res.json()) as { choices?: { message?: { content?: string } }[] };
    return json.choices?.[0]?.message?.content ?? null;
  } catch {
    // AbortError (timeout) / network error -> treat as a failed attempt.
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Finalize a validated DeepSeek receipt: backfill deductible, infer GST, compute confidence. */
function finalize(input: ExtractionInput, r: DeepseekReceipt): ExtractedReceipt {
  const total = roundCents(Math.max(0, r.total));

  // GST non-null guarantee: infer round(total/11) when absent and total>0; null only at total==0.
  let gst = r.gst;
  if (total === 0) gst = null;
  else if (gst === null || gst === undefined) gst = roundCents(total / 11);
  else gst = roundCents(gst);

  // Deductible backfill from the per-category default when the model omitted it,
  // then coerce to an INTEGER literal so the wire never emits a float like 50.0
  // (the iOS decodeIfPresent(Int.self) would throw on a 50.0 JSON token).
  const deductibleRaw =
    r.deductible ?? (r.category in DEDUCTIBLE_DEFAULTS ? DEDUCTIBLE_DEFAULTS[r.category] : null);
  const deductible = deductibleRaw == null ? null : Math.round(deductibleRaw);

  const modelStated = r.confidence ?? 0.7;
  const confidence = clamp01(
    0.55 * modelStated +
      0.25 * ocrQuality(input.ocrText) +
      0.2 * arithmeticConsistency(r.lineItems, total),
  );

  return {
    merchant: r.merchant,
    date: r.date,
    currencyCode: "AUD",
    total,
    gst,
    category: r.category,
    deductible,
    lineItems: r.lineItems.map((li) => ({ name: li.name, price: roundCents(li.price) })),
    confidence,
    needsReview: confidence < 0.8,
  };
}

/** The deterministic fallback at the end of the ladder: heuristic + needsReview + low confidence. */
function fallback(input: ExtractionInput): ExtractedReceipt {
  const h = heuristicExtract(input.ocrText, input.defaultDate);
  return {
    merchant: h.merchant,
    date: h.date,
    currencyCode: "AUD",
    total: h.total,
    gst: h.total === 0 ? null : h.gst,
    category: h.category,
    deductible: h.deductible,
    lineItems: h.lineItems,
    confidence: 0.4,
    needsReview: true,
  };
}

/**
 * Run the real DeepSeek extraction with the <=3-attempt validate/retry ladder.
 * Attempt 1: base prompt. Attempt 2: corrective re-prompt with the prior raw
 * output ("return valid json"). Attempt 3: same corrective prompt — tryParseReceipt
 * already strips fences / extracts the first {...} on every attempt. On exhaustion,
 * the deterministic heuristic fallback (needsReview:true).
 */
export async function runDeepseekExtraction(env: Env, input: ExtractionInput): Promise<DeepseekResult> {
  const model = env.DEEPSEEK_MODEL ?? "deepseek-chat";
  const userPrompt = `Extract the receipt as json. OCR text:\n${input.ocrText}`;

  let attempts = 0;
  let lastRaw = "";

  while (attempts < MAX_ATTEMPTS) {
    attempts += 1;
    const messages =
      attempts === 1
        ? [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
          ]
        : [
            { role: "system", content: SYSTEM_PROMPT },
            { role: "user", content: userPrompt },
            { role: "assistant", content: lastRaw },
            {
              role: "user",
              content:
                "That was not valid against the schema. Return ONLY a valid json object matching the schema, no prose, no markdown fences.",
            },
          ];

    const content = await callDeepseek(env, model, messages);
    if (content !== null) {
      lastRaw = content;
      const parsed = tryParseReceipt(content);
      if (parsed) {
        return { receipt: finalize(input, parsed), meta: { model, attempts, stub: false } };
      }
    }
  }

  return { receipt: fallback(input), meta: { model, attempts, stub: false } };
}
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/deepseek.test.ts
```
Expected (PASS): all cases green (valid→1 attempt; invalid-then-valid→2; fenced→stripped on attempt 3; always-invalid→heuristic fallback `needsReview:true`/`office`/`<0.8`; GST inference at total 11→1.00; gst null only at total 0; **deductible `50.0`→integer-valued `50`**; arithmetic-mismatch lowers confidence + flips `needsReview`; AbortError → fallback).

- [ ] **Step 5: Typecheck + commit.**

```bash
npx tsc --noEmit && git add src/lib/deepseek.ts test/deepseek.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): DeepSeek client with retry ladder + confidence + GST inference

Add src/lib/deepseek.ts: verbatim system prompt (the 9 keys + per-category
deductible defaults), chat-completions call (json mode, temp 0, 20s abort
budget), the <=3-attempt validate/retry ladder (corrective re-prompt + fence
stripping / first-{...} extraction), AU-GST non-null inference, and the
server confidence formula (0.55 model + 0.25 ocrQuality + 0.20 arithmetic),
with the heuristic fallback (needsReview) on exhaustion. fetch mocked in
tests; covered by test/deepseek.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `rateLimit.ts` — add the `extract` tier

Goal: add the NEW `extract` rate tier (`30/user/hr`) to the `RateLimitKind` union + `RATE_LIMIT_TIERS` map + the tier-selection branch, so `app.use("/extract/*", rateLimit("extract"))` works. TDD against the existing `rateLimit` middleware via `SELF.fetch`.

> Done before the route task so the route's auth+rate-limit mount in Task 7 compiles. The `extract` route doesn't exist yet, so this task tests the tier wiring by temporarily — no: we test via a unit assertion on the exported map + a `SELF.fetch` once `/extract` exists. To keep this task self-contained and green NOW, it asserts the exported `RATE_LIMIT_TIERS.extract` shape and the `RateLimitKind` union by construction; the HTTP 429 behavior is covered in Task 7's route test.

**Files**
- Modify: `src/middleware/rateLimit.ts`
- Test: `test/rateLimit-extract.test.ts`

---

- [ ] **Step 1: Write the failing unit test FIRST.**

```ts
// test/rateLimit-extract.test.ts
import { describe, expect, it } from "vitest";
import { RATE_LIMIT_TIERS, rateLimit } from "../src/middleware/rateLimit";

describe("extract rate tier", () => {
  it("declares a 30/user/hr extract tier", () => {
    const t = RATE_LIMIT_TIERS.extract;
    expect(t).toBeDefined();
    expect(t.limit).toBe(30);
    expect(t.windowMs).toBe(3_600_000);
    expect(t.dimension).toBe("user");
    expect(t.name).toBe("extract");
  });

  it('rateLimit("extract") is constructible (kind is in the union)', () => {
    const mw = rateLimit("extract");
    expect(typeof mw).toBe("function");
  });
});
```

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/rateLimit-extract.test.ts
```
Expected (FAIL): `RATE_LIMIT_TIERS.extract` is `undefined` (and `rateLimit("extract")` is a type error / `kind` falls through to the `default` tier silently). The `expect(t).toBeDefined()` assertion fails.

- [ ] **Step 3: Add the `extract` tier + union member + selection branch.**

In `src/middleware/rateLimit.ts`, add the tier to `RATE_LIMIT_TIERS` (after `sync`, before `default`). **First confirm `HOUR_MS` is module-scope** (it is — `const HOUR_MS = 60 * 60 * 1000;` near the top of the file alongside `MINUTE_MS`); the literal below references it directly:
```ts
  /** receipt extraction — calls an external API; keep it tight. */
  extract: { name: "extract", limit: 30, windowMs: HOUR_MS, dimension: "user" },
```

Extend the union:
```ts
export type RateLimitKind = "auth" | "sync" | "extract" | "default";
```

Replace the single-dimension tier selection at the bottom of `rateLimit()`:
```ts
    const tier = kind === "sync" ? RATE_LIMIT_TIERS.sync : RATE_LIMIT_TIERS.default;
```
with:
```ts
    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : RATE_LIMIT_TIERS.default;
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/rateLimit-extract.test.ts
```
Expected (PASS): both cases green; the tier is defined with `30 / 3_600_000 / user / "extract"` and the middleware is constructible.

- [ ] **Step 5: Run the existing rate-limit suite to confirm no regression, then commit.**

```bash
npx vitest run test/rateLimit.test.ts test/rateLimit-extract.test.ts && npx tsc --noEmit && git add src/middleware/rateLimit.ts test/rateLimit-extract.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): add the 'extract' rate-limit tier (30/user/hr)

Add the extract tier to RATE_LIMIT_TIERS, the RateLimitKind union, and the
tier-selection branch so app.use("/extract/*", rateLimit("extract")) limits
the external-API extraction path. Existing rateLimit suite unaffected.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `POST /extract` route (`src/routes/extract.ts`) — stub gate, DeepSeek/heuristic, §9 response

Goal: the route handler. Auth is provided by the global `authMiddleware` once it is mounted in Task 8; for THIS task's tests we mount the route on a throwaway test app with a seeded session (mirroring `test/devices.test.ts`). The handler validates the body, resolves the default date (`capturedAt` ?? today), and either (stub gate: `E2E_EXTRACT_MODE==="1" || !DEEPSEEK_API_KEY`) returns a deterministic stub from the heuristic (`needsReview:false`, `confidence:0.9`, `meta.stub:true`), or calls `runDeepseekExtraction`. It assembles and returns the §9 response.

> The route is mounted into the real `src/app.ts` in Task 8. To test it in isolation here BEFORE the app mount, the test builds a local Hono app with `requestId()` + the route, and injects a fake `c.env`. We instead test through the REAL app after Task 8 — so this task implements the route + adds a focused test that mounts it standalone with the stub gate (no key) so it needs no DeepSeek mock.

**Files**
- Create: `src/routes/extract.ts`
- Test: `test/extract-route.test.ts`

---

- [ ] **Step 1: Write the failing route test FIRST (standalone Hono app, stub gate active).**

```ts
// test/extract-route.test.ts
import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { extractRoutes } from "../src/routes/extract";

/** Build a standalone app that mounts /extract with a fixed authed userId and a
 *  given env (no global auth/rate-limit — those are exercised in the app-mount + e2e tasks). */
function appWith(envOverrides: Record<string, unknown>) {
  const app = new Hono<AppEnv>();
  app.use("*", requestId());
  registerErrorHandler(app);
  // Inject a fake authed identity + env.
  app.use("*", async (c, next) => {
    c.set("userId", "u-test");
    c.set("deviceId", "d-test");
    Object.assign(c.env, envOverrides);
    await next();
  });
  app.route("/extract", extractRoutes);
  return app;
}

const OCR = ["THE GROUNDS", "28/05/2026", "Flat White 9.00", "Big Brekkie 24.00", "TOTAL 33.00"].join(
  "\n",
);

describe("POST /extract (stub gate)", () => {
  it("returns the deterministic stub when DEEPSEEK_API_KEY is empty", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan", capturedAt: "2026-05-30" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // §9 response shape.
    expect(typeof body.requestId).toBe("string");
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.receipt.merchant).toBe("THE GROUNDS");
    expect(body.receipt.date).toBe("2026-05-28");
    expect(body.receipt.total).toBe(33.0);
    expect(body.receipt.category).toBe("office"); // heuristic stub
    expect(body.receipt.deductible).toBe(100);
    expect(body.receipt.gst).toBe(3.0); // 33/11
    expect(body.receipt.needsReview).toBe(false); // stub forces false
    expect(body.receipt.confidence).toBe(0.9); // stub fixed
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
    expect(typeof body.meta.latencyMs).toBe("number");
    expect(body.meta.attempts).toBe(0);
  });

  it("engages the stub when E2E_EXTRACT_MODE === '1' even with a key set", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "sk-real", E2E_EXTRACT_MODE: "1" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "email_in" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("email_in");
  });

  it("echoes a provided requestId", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan", requestId: "client-123" }),
    });
    const body = (await res.json()) as any;
    expect(body.requestId).toBe("client-123");
  });

  it("rejects an empty ocrText with 400 VALIDATION_FAILED", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "", source: "scan" }),
    });
    expect(res.status).toBe(400);
    const body = (await res.json()) as any;
    expect(body.error.code).toBe("VALIDATION_FAILED");
  });

  it("defaults the date to today when no capturedAt and OCR has no date", async () => {
    const app = appWith({ DEEPSEEK_API_KEY: "" });
    const res = await app.request("/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "WIDGET CO\nTOTAL 10.00", source: "scan" }),
    });
    const body = (await res.json()) as any;
    expect(body.receipt.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});
```

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/extract-route.test.ts
```
Expected (FAIL): `Failed to resolve import "../src/routes/extract"`.

- [ ] **Step 3: Implement `src/routes/extract.ts`.**

```ts
// src/routes/extract.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { extractRequestSchema } from "../schemas/extract";
import { heuristicExtract } from "../lib/extractionHeuristic";
import { runDeepseekExtraction, type ExtractedReceipt } from "../lib/deepseek";

/**
 * POST /extract — auth (global middleware) + rate tier "extract" (mounted in
 * app.ts). Validates the body, resolves the fallback date (capturedAt ?? today),
 * and either returns a deterministic stub (when E2E_EXTRACT_MODE === "1" OR no
 * DEEPSEEK_API_KEY) or runs the real DeepSeek extraction. Always answers 200 with
 * the §9 response (needsReview may be true — the client still shows Review).
 */
export const extractRoutes = new Hono<AppEnv>();

/** Today's date as YYYY-MM-DD (UTC) — the final date fallback. */
function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

/** The deterministic stub: the same heuristic as the fallback, but confident. */
function stubReceipt(ocrText: string, defaultDate: string): ExtractedReceipt {
  const h = heuristicExtract(ocrText, defaultDate);
  return {
    merchant: h.merchant,
    date: h.date,
    currencyCode: "AUD",
    total: h.total,
    gst: h.total === 0 ? null : h.gst,
    category: h.category,
    deductible: h.deductible,
    lineItems: h.lineItems,
    confidence: 0.9,
    needsReview: false,
  };
}

extractRoutes.post("/", validate("json", extractRequestSchema), async (c) => {
  const body = c.req.valid("json");
  const startedAt = nowMs();
  const defaultDate = body.capturedAt ?? todayIso();
  const requestId = body.requestId ?? uuidv7();

  const stubGate = c.env.E2E_EXTRACT_MODE === "1" || !c.env.DEEPSEEK_API_KEY;

  let receipt: ExtractedReceipt;
  let model: string;
  let attempts: number;
  let stub: boolean;

  if (stubGate) {
    receipt = stubReceipt(body.ocrText, defaultDate);
    model = c.env.DEEPSEEK_MODEL ?? "deepseek-chat";
    attempts = 0;
    stub = true;
  } else {
    const result = await runDeepseekExtraction(c.env, {
      ocrText: body.ocrText,
      source: body.source,
      defaultDate,
    });
    receipt = result.receipt;
    model = result.meta.model;
    attempts = result.meta.attempts;
    stub = false;
  }

  return c.json({
    requestId,
    receipt,
    meta: {
      model,
      source: body.source,
      latencyMs: nowMs() - startedAt,
      attempts,
      stub,
    },
  });
});
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/extract-route.test.ts
```
Expected (PASS): all cases green (stub when no key; stub when `E2E_EXTRACT_MODE`; echoed requestId; empty ocrText → 400 VALIDATION_FAILED; today-date default; `meta.stub:true`, `attempts:0`, `confidence:0.9`, `needsReview:false`).

- [ ] **Step 5: Typecheck + commit.**

```bash
npx tsc --noEmit && git add src/routes/extract.ts test/extract-route.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): POST /extract route (stub gate + DeepSeek + §9 response)

Add src/routes/extract.ts: validates the request, resolves the date fallback
(capturedAt ?? today), and either returns the deterministic heuristic stub
(E2E_EXTRACT_MODE==="1" || no DEEPSEEK_API_KEY: needsReview:false,
confidence:0.9, meta.stub:true, attempts:0) or runs runDeepseekExtraction.
Returns the authoritative §9 { requestId, receipt, meta } shape. Covered by
test/extract-route.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `POST /images` + `GET /images/*` (`src/routes/images.ts`) — R2 + FK-safe link + wildcard read

Goal: the image service. `POST /images` reads raw JPEG bytes, validates content-type + size, writes to R2 (`u/{userId}/{uuid}.jpg`), inserts a `receipt_images` row (setting `transaction_id` only when the parent txn exists for the user, else NULL), and returns `{ imageKey, getUrl, byteSize }`. `GET /images/*` is a wildcard route that derives `key` from the path, enforces the `u/{userId}/` ownership prefix (else 404), and streams the R2 object. Tests run in-workerd against a **standalone Hono app** (mirroring Task 6's `/extract` test) so this task has NO dependency on `src/app.ts` — the app.ts wiring (imports, both route mounts, both limiters with exact+wildcard paths) is consolidated entirely into Task 8. The standalone app injects a fixed authed `userId`/`deviceId` and the REAL `env.DB` + `env.RECEIPTS` bindings (Miniflare's local D1 + R2) so the put→row→get round-trip is exercised end-to-end.

> Why a standalone app (not `SELF.fetch`): driving `src/app.ts` via `SELF.fetch` would force Task 7 to also edit `app.ts` (the route mount), splitting the app.ts wiring across Tasks 7 and 8 and risking a merge/edit collision. Instead — exactly like Task 6 mounts `extractRoutes` on a throwaway Hono app — Task 7 mounts `imageRoutes` on a throwaway app, sets `c.var.userId`/`deviceId`, and assigns the real bindings onto `c.env`. The 401-without-auth case is covered by the global middleware in Task 8's app-mount test (`test/extract-app.test.ts` exercises the auth gate); here we test the handler logic, the R2 round-trip, the FK-safe link, and the wildcard ownership 404 directly.

> Why the real R2 binding (not a mock): `@cloudflare/vitest-pool-workers` provides a working local R2 (`env.RECEIPTS`) and D1 (`env.DB`), so the put→row→get round-trip is exercised end-to-end exactly like `test/devices.test.ts` exercises the real D1. (The spec's "R2 mocked" is satisfied by Miniflare's in-memory R2.) The cross-user 404 + non-existent-txn→NULL paths need no mock.

**Files**
- Create: `src/routes/images.ts`
- Test: `test/images.test.ts`

---

- [ ] **Step 1: Write the failing test FIRST (standalone Hono app + real D1 + R2 bindings, injected identity).**

```ts
// test/images.test.ts
import { env } from "cloudflare:test";
import { Hono } from "hono";
import { beforeEach, describe, expect, it } from "vitest";
import type { AppEnv } from "../src/env";
import { requestId, registerErrorHandler } from "../src/middleware/error";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { imageRoutes } from "../src/routes/images";

/** A tiny valid-enough JPEG byte sequence (SOI ... EOI). Content is opaque to the worker. */
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

/**
 * Build a standalone app that mounts /images with a fixed authed identity and
 * the REAL D1 + R2 bindings injected onto c.env. No global auth/rate-limit —
 * those are exercised in Task 8's app-mount test (test/extract-app.test.ts).
 */
function appAs(userId: string, deviceId: string) {
  const app = new Hono<AppEnv>();
  app.use("*", requestId());
  registerErrorHandler(app);
  app.use("*", async (c, next) => {
    c.set("userId", userId);
    c.set("deviceId", deviceId);
    // Bring the real Miniflare bindings into the throwaway app's c.env.
    c.env.DB = env.DB;
    c.env.RECEIPTS = env.RECEIPTS;
    await next();
  });
  app.route("/images", imageRoutes);
  return app;
}

/** Insert a profile + transaction owned by userId; returns the txn id. */
async function seedTxn(userId: string): Promise<string> {
  const profileId = uuidv7();
  const txnId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'P','personal','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,cat_key,amount_cents,txn_date,created_at,updated_at)
     VALUES (?,?,?,'meals',-1250,'2026-05-30',?,?)`,
  ).bind(txnId, userId, profileId, now, now).run();
  return txnId;
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM line_items");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("POST /images", () => {
  it("stores the JPEG in R2, inserts a receipt_images row, returns {imageKey,getUrl,byteSize}", async () => {
    const userId = uuidv7();
    const deviceId = uuidv7();
    const app = appAs(userId, deviceId);
    const txnId = await seedTxn(userId);

    const res = await app.request(
      `/images?transactionId=${txnId}&width=1200&height=1600`,
      { method: "POST", headers: { "content-type": "image/jpeg" }, body: JPEG_BYTES },
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { imageKey: string; getUrl: string; byteSize: number };
    expect(body.imageKey).toMatch(new RegExp(`^u/${userId}/[0-9a-f-]+\\.jpg$`));
    expect(body.getUrl).toBe(`/images/${body.imageKey}`);
    expect(body.byteSize).toBe(JPEG_BYTES.byteLength);

    // R2 object exists.
    const obj = await env.RECEIPTS.get(body.imageKey);
    expect(obj).not.toBeNull();

    // receipt_images row exists with the FK link + metadata.
    const row = await env.DB.prepare(
      `SELECT user_id, transaction_id, r2_key, content_type, byte_size, width, height, page_index, source, ocr_source, last_edited_device_id
         FROM receipt_images WHERE r2_key = ?`,
    ).bind(body.imageKey).first<any>();
    expect(row.user_id).toBe(userId);
    expect(row.transaction_id).toBe(txnId);
    expect(row.content_type).toBe("image/jpeg");
    expect(row.byte_size).toBe(JPEG_BYTES.byteLength);
    expect(row.width).toBe(1200);
    expect(row.height).toBe(1600);
    expect(row.page_index).toBe(0);
    expect(row.source).toBe("scan");
    expect(row.ocr_source).toBe("vision_on_device");
    expect(row.last_edited_device_id).toBe(deviceId);
  });

  it("stores transaction_id = NULL when the txn does not exist for this user (FK-safe, still 200)", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const res = await app.request(`/images?transactionId=${uuidv7()}`, {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { imageKey: string };
    const row = await env.DB.prepare(`SELECT transaction_id FROM receipt_images WHERE r2_key = ?`)
      .bind(body.imageKey).first<{ transaction_id: string | null }>();
    expect(row?.transaction_id).toBeNull();
  });

  it("rejects a non-image/jpeg content-type with 400", async () => {
    const app = appAs(uuidv7(), uuidv7());
    const res = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/png" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("rejects a body over 6 MiB with 400", async () => {
    const app = appAs(uuidv7(), uuidv7());
    const big = new Uint8Array(6_291_457); // 6 MiB + 1
    big[0] = 0xff; big[1] = 0xd8;
    const res = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: big,
    });
    expect(res.status).toBe(400);
  });
});

describe("GET /images/*", () => {
  it("streams the owner's object back with its content-type", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const post = await app.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    const get = await app.request(`/images/${imageKey}`);
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    const bytes = new Uint8Array(await get.arrayBuffer());
    expect(bytes.byteLength).toBe(JPEG_BYTES.byteLength);
  });

  it("returns 404 for another user's key (ownership enforced by prefix)", async () => {
    const ownerA = uuidv7();
    const appA = appAs(ownerA, uuidv7());
    const post = await appA.request("/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    // A different user's app (different injected userId) cannot read A's key.
    const appB = appAs(uuidv7(), uuidv7());
    const get = await appB.request(`/images/${imageKey}`);
    expect(get.status).toBe(404);
  });

  it("returns 404 for an own-prefix key with no object", async () => {
    const userId = uuidv7();
    const app = appAs(userId, uuidv7());
    const get = await app.request(`/images/u/${userId}/${uuidv7()}.jpg`);
    expect(get.status).toBe(404);
  });
});
```

> The 401-without-auth case for `/images` is NOT tested here (this app has no global `authMiddleware`); it is covered in Task 8's `test/extract-app.test.ts` via `SELF.fetch` through the real app, alongside the `/extract` 401 gate.

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/images.test.ts
```
Expected (FAIL): `Failed to resolve import "../src/routes/images"` — the route module does not exist yet. (No `app.ts` dependency: the test mounts `imageRoutes` on a throwaway Hono app, so there is nothing to mount globally for this task. The global mount + limiters are added once, in Task 8.)

- [ ] **Step 3: Implement `src/routes/images.ts`.**

```ts
// src/routes/images.ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";

/**
 * Receipt image service.
 *  POST /images      — raw image/jpeg body; metadata via query params; writes to
 *                      R2 + inserts a FK-safe receipt_images row.
 *  GET  /images/*    — wildcard; streams the owner's R2 object (prefix ownership).
 * Both are auth-gated by the global middleware (c.var.userId is set).
 */
export const imageRoutes = new Hono<AppEnv>();

const MAX_BYTES = 6_291_456; // 6 MiB
const OCR_TEXT_CAP = 20_000;

/** Optional positive-int query param; returns null when absent/invalid. */
function intParam(c: { req: { query: (k: string) => string | undefined } }, key: string): number | null {
  const raw = c.req.query(key);
  if (raw === undefined) return null;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

imageRoutes.post("/", async (c) => {
  const userId = c.var.userId;
  const deviceId = c.var.deviceId;

  // 1. Content-type guard.
  const contentType = c.req.header("content-type") ?? "";
  if (!contentType.includes("image/jpeg")) {
    throw new ApiError("VALIDATION_FAILED", "Expected Content-Type: image/jpeg");
  }

  // 2. Read + size guard.
  const buf = await c.req.arrayBuffer();
  const byteSize = buf.byteLength;
  if (byteSize === 0) throw new ApiError("VALIDATION_FAILED", "Empty image body");
  if (byteSize > MAX_BYTES) {
    throw new ApiError("VALIDATION_FAILED", `Image exceeds ${MAX_BYTES} bytes`);
  }

  // 3. Query metadata.
  const pageIndex = intParam(c, "pageIndex") ?? 0;
  const width = intParam(c, "width");
  const height = intParam(c, "height");
  const reqTxnId = c.req.query("transactionId") ?? null;
  let ocrText = c.req.query("ocrText") ?? null;
  if (ocrText && ocrText.length > OCR_TEXT_CAP) ocrText = ocrText.slice(0, OCR_TEXT_CAP);

  // 4. Write to R2 under the per-user prefix.
  const key = `u/${userId}/${uuidv7()}.jpg`;
  await c.env.RECEIPTS.put(key, buf, { httpMetadata: { contentType: "image/jpeg" } });

  // 5. FK-safe link: keep transactionId ONLY if the txn exists for this user.
  let linkedTxnId: string | null = null;
  if (reqTxnId) {
    const owned = await c.env.DB.prepare(
      "SELECT 1 FROM transactions WHERE id = ? AND user_id = ?",
    ).bind(reqTxnId, userId).first<{ 1: number }>();
    if (owned) linkedTxnId = reqTxnId;
  }

  // 6. Insert the receipt_images row (existing table).
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO receipt_images
       (id, user_id, profile_id, transaction_id, r2_key, thumb_r2_key, content_type, byte_size,
        width, height, page_index, ocr_text, ocr_source, extraction_json, extraction_model, source,
        created_at, updated_at, deleted_at, rev, last_edited_device_id)
     VALUES (?, ?, NULL, ?, ?, NULL, 'image/jpeg', ?, ?, ?, ?, ?, 'vision_on_device', NULL, NULL, 'scan',
        ?, ?, NULL, 0, ?)`,
  ).bind(
    uuidv7(), userId, linkedTxnId, key, byteSize,
    width, height, pageIndex, ocrText,
    now, now, deviceId,
  ).run();

  return c.json({ imageKey: key, getUrl: `/images/${key}`, byteSize });
});

// Wildcard GET — Hono's :param is single-segment and can't match the slash-bearing
// key, so we read the path tail directly.
imageRoutes.get("/*", async (c) => {
  const key = c.req.path.slice("/images/".length);
  if (!key || !key.startsWith(`u/${c.var.userId}/`)) {
    throw new ApiError("NOT_FOUND", "Image not found");
  }
  const obj = await c.env.RECEIPTS.get(key);
  if (!obj) throw new ApiError("NOT_FOUND", "Image not found");

  return new Response(obj.body, {
    status: 200,
    headers: { "content-type": obj.httpMetadata?.contentType ?? "image/jpeg" },
  });
});
```

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/images.test.ts
```
Expected (PASS): all cases green (R2 put + row insert + `{imageKey,getUrl,byteSize}` + `last_edited_device_id`; FK-safe NULL when txn absent; 400 on non-jpeg; 400 over 6 MiB; GET round-trip with content-type; cross-user 404; own-prefix-missing 404). No `app.ts` edit in this task — the global mount is in Task 8.

- [ ] **Step 5: Typecheck + commit.**

```bash
npx tsc --noEmit && git add src/routes/images.ts test/images.test.ts && git commit -m "$(cat <<'EOF'
feat(images): POST /images + GET /images/* (R2 + FK-safe receipt_images link)

Add src/routes/images.ts: POST stores a raw image/jpeg in R2 under
u/{userId}/{uuid}.jpg (content-type + 6 MiB guards), inserts a
receipt_images row, and links transaction_id only when the parent txn
exists for the user (else NULL, still 200); returns {imageKey,getUrl,
byteSize}. GET is a wildcard route streaming the owner's object after a
u/{userId}/ prefix ownership check (404 otherwise). Covered by
test/images.test.ts (standalone Hono app + real D1 + local R2); the
global app.ts mount + limiters land in Task 8.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `app.ts` — mount `/images` + `/extract` + all rate limiters (single wiring step)

Goal: wire BOTH routes into the real app in ONE place (Task 7 left `app.ts` untouched). Import `imageRoutes` + `extractRoutes`; mount both routes AFTER `authMiddleware` (so they are auth-gated); and add the per-class limiters AFTER `authMiddleware` (so `c.var.userId` keys them). The limiters mount on BOTH the exact path AND the wildcard for each group (`/extract` + `/extract/*`, `/images` + `/images/*`) so the limiter is guaranteed to run for the exact-path POSTs (`POST /extract`, `POST /images`) as well as the wildcard GET reads — see the determinism note in Step 3. Verified via `SELF.fetch` through the REAL app (auth required on BOTH routes + the extract stub end-to-end + the 429 path + the `/images` round-trip).

**Files**
- Modify: `src/app.ts`
- Test: `test/extract-app.test.ts`

---

- [ ] **Step 1: Write the failing app-mount test FIRST.**

```ts
// test/extract-app.test.ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedSession() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', ?, ?, ?)`,
  ).bind(userId, `${userId}@example.com`, "free", now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const OCR = "THE GROUNDS\n28/05/2026\nTOTAL 33.00";
const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

describe("POST /extract (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/extract", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan" }),
    });
    expect(res.status).toBe(401);
  });

  it("returns the stub §9 shape for an authed request (no DeepSeek key in tests)", async () => {
    const { accessToken } = await seedSession();
    const res = await SELF.fetch("https://x/extract", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ ocrText: OCR, source: "scan" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
    expect(body.meta.attempts).toBe(0); // stub path
  });

  it("rate-limits the extract tier at 30/user/hr (the 31st request is 429)", async () => {
    const { accessToken } = await seedSession();
    const headers = { authorization: `Bearer ${accessToken}`, "content-type": "application/json" };
    const body = JSON.stringify({ ocrText: OCR, source: "scan" });
    let last = 200;
    for (let i = 0; i < 31; i++) {
      const res = await SELF.fetch("https://x/extract", { method: "POST", headers, body });
      last = res.status;
    }
    expect(last).toBe(429); // exact-path limiter engaged for POST /extract
  });
});

describe("/images (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/images", {
      method: "POST",
      headers: { "content-type": "image/jpeg" },
      body: JPEG_BYTES,
    });
    expect(res.status).toBe(401);
  });

  it("POST /images then GET /images/* round-trips for the owner (exact-path mount works)", async () => {
    const { accessToken, deviceId } = await seedSession();
    const post = await SELF.fetch("https://x/images", {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG_BYTES,
    });
    expect(post.status).toBe(200);
    const { imageKey, getUrl } = (await post.json()) as { imageKey: string; getUrl: string };
    const get = await SELF.fetch(`https://x${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(getUrl).toBe(`/images/${imageKey}`);
  });
});
```

> The DeepSeek key is unset in the test runtime (vitest.config.ts injects no `DEEPSEEK_API_KEY`), so the stub gate (`!DEEPSEEK_API_KEY`) engages — no network, no mock needed. If a later config adds a key, set `E2E_EXTRACT_MODE` for these tests via the miniflare bindings.

- [ ] **Step 2: Run it and watch it FAIL.**

```bash
npx vitest run test/extract-app.test.ts
```
Expected (FAIL): the authed `/extract` POST 404s and `/images` POST 404s (neither route mounted) and the 429 case never trips (no limiter), so the stub-shape, round-trip, and `expect(last).toBe(429)` assertions fail.

- [ ] **Step 3: Mount BOTH routes + ALL limiters in `src/app.ts` (single wiring step — deterministic exact + wildcard limiter paths).**

Add the imports alongside the other route imports:
```ts
import { imageRoutes } from "./routes/images";
import { extractRoutes } from "./routes/extract";
```

In the limiters block (where `app.use("/sync/*", rateLimit("sync"))` and `app.use("/devices/*", rateLimit("default"))` live, AFTER `app.use("*", authMiddleware())`), add BOTH the exact-path AND the wildcard mount for each group:
```ts
// Receipt extraction (external API) — tight 30/user/hr tier. Mount the limiter
// on BOTH the exact path AND the wildcard: the route handler serves POST /extract
// (no trailing slash, mounted at "/"), and Hono's "/extract/*" wildcard does NOT
// reliably match the exact "/extract" path, so the exact mount guarantees the
// limiter runs for the actual POST. (Belt-and-suspenders; no behavior depends on
// "try and see".)
app.use("/extract", rateLimit("extract"));
app.use("/extract/*", rateLimit("extract"));
// Image upload/read — default tier. POST /images is the exact path; GET /images/*
// is the wildcard. Mount both so the exact-path POST is also limited.
app.use("/images", rateLimit("default"));
app.use("/images/*", rateLimit("default"));
```

In the routes block (after `app.route("/sync", syncRoutes)`, before `app.route("/", miscRoutes)`), add BOTH route mounts:
```ts
// Protected: receipt image upload/read (R2 + FK-safe receipt_images link).
app.route("/images", imageRoutes);
// Protected: receipt extraction (DeepSeek + stub). Rate tier "extract" above.
app.route("/extract", extractRoutes);
```

> Why both `/extract` and `/extract/*` (and both `/images` and `/images/*`): a middleware mounted ONLY at `app.use("/extract/*", …)` is not guaranteed to run for the exact path `/extract` (no trailing segment) in Hono v4 — the `/*` wildcard targets sub-paths. Since the route serves `POST /extract` at exactly `/extract`, mounting the limiter on the exact path as well makes the 429 path deterministic instead of dependent on wildcard-matching nuance. The wildcard mount still covers `GET /images/<key>` reads. This is the determined wiring — there is no conditional "change it if the test fails" fallback.

- [ ] **Step 4: Run it and watch it PASS.**

```bash
npx vitest run test/extract-app.test.ts
```
Expected (PASS): `/extract` 401 without auth; authed `/extract` POST returns the stub §9 shape (`meta.stub:true`, `meta.attempts:0`); the 31st `/extract` request in a window returns 429 (the exact-path limiter engaged); `/images` 401 without auth; `/images` POST→GET round-trips for the owner.

- [ ] **Step 5: Run the FULL workers suite to confirm no regression, then commit.**

```bash
npx vitest run && npx tsc --noEmit && git add src/app.ts test/extract-app.test.ts && git commit -m "$(cat <<'EOF'
feat(extract): mount /images + /extract routes + limiters in app.ts

Mount imageRoutes at /images and extractRoutes at /extract (both auth-gated),
and add the per-class limiters on BOTH the exact path AND the wildcard for
each group (/extract + /extract/*, /images + /images/*) so the limiter is
guaranteed to run for the exact-path POSTs (Hono's /*-only mount does not
reliably match the bare path). extract tier = 30/user/hr; images tier =
default. Limiters sit after authMiddleware so c.var.userId keys them. Single
app.ts wiring step (Task 7 left app.ts untouched). Covered by
test/extract-app.test.ts (401 gates, stub §9 shape, 429 at the 31st request,
/images round-trip). Full workers suite green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: e2e (`e2e/extract.e2e.test.ts`) — black-box over real HTTP

Goal: a real-HTTP e2e (Node env, `unstable_dev`) proving the deployed shapes: `POST /extract` in `E2E_EXTRACT_MODE` returns the canned §9 shape; `POST /images` → `GET /images/*` round-trips; a cross-user `GET` 404s; and `POST /images` with a non-existent `transactionId` stores NULL but still 200s. Mirrors `e2e/snapceipt.e2e.test.ts` (migrate an isolated persist dir, boot the worker with the e2e seams, drive the magic-link flow to get a token).

**Files**
- Create: `e2e/extract.e2e.test.ts`

---

- [ ] **Step 1: Write the e2e spec (it boots the real worker; run it last).**

```ts
// e2e/extract.e2e.test.ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * E2E for the extraction + image service. Boots the REAL worker over HTTP via
 * unstable_dev (isolated persist dir + applied migrations), drives the
 * magic-link seam to obtain an access token, then exercises /extract (in
 * E2E_EXTRACT_MODE -> deterministic stub) and /images (POST -> GET, cross-user
 * 404, non-existent-txn -> NULL link but still 200). Mirrors snapceipt.e2e.test.ts.
 */

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const JWT_SIGNING_KEY = "e2e-signing-key-0123456789-abcdefghijklmnop";
const APPLE_BUNDLE_ID = "com.snapceipt.app";

let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;

function applyMigrations(dir: string): void {
  execFileSync(
    "node",
    [
      path.join(repoRoot, "node_modules", "wrangler", "bin", "wrangler.js"),
      "d1", "migrations", "apply", "snapceipt", "--local", "--persist-to", dir,
    ],
    { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-extract-e2e-"));
  applyMigrations(persistDir);
  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    vars: { E2E_TEST_MODE: "1", E2E_EXTRACT_MODE: "1", JWT_SIGNING_KEY, APPLE_BUNDLE_ID },
    logLevel: "warn",
  });
  const host = worker.address === "::" || worker.address === "0.0.0.0" ? "127.0.0.1" : worker.address;
  baseUrl = `http://${host}:${worker.port}`;
}, 120_000);

afterAll(async () => {
  if (worker) await worker.stop();
  if (persistDir) {
    try { rmSync(persistDir, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
});

/** Magic-link sign-in -> { accessToken, userId, deviceId }. */
async function signIn(): Promise<{ accessToken: string; userId: string; deviceId: string }> {
  const email = `extract+${Date.now()}-${Math.random()}@example.com`;
  const deviceId = crypto.randomUUID();
  const ip = "203.0.113.42";
  const reqRes = await fetch(`${baseUrl}/auth/magic-link/request`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ email }),
  });
  const { devToken } = (await reqRes.json()) as { devToken: string };
  const verifyRes = await fetch(`${baseUrl}/auth/magic-link/verify`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip, "x-device-id": deviceId },
    body: JSON.stringify({ token: devToken }),
  });
  const session = (await verifyRes.json()) as { accessToken: string; user: { id: string } };
  return { accessToken: session.accessToken, userId: session.user.id, deviceId };
}

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

describe("e2e: /extract (stub) + /images round-trip + ownership", () => {
  it("POST /extract in E2E_EXTRACT_MODE returns the canned §9 stub shape", async () => {
    const { accessToken } = await signIn();
    const res = await fetch(`${baseUrl}/extract`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "THE GROUNDS\n28/05/2026\nTOTAL 33.00", source: "scan" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(typeof body.requestId).toBe("string");
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.receipt.merchant).toBe("THE GROUNDS");
    expect(body.receipt.total).toBe(33.0);
    expect(body.receipt.gst).toBe(3.0);
    expect(body.receipt.needsReview).toBe(false);
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
  });

  it("POST /images then GET /images/* round-trips for the owner", async () => {
    const { accessToken, deviceId } = await signIn();
    const post = await fetch(`${baseUrl}/images?width=800&height=1000`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG,
    });
    expect(post.status).toBe(200);
    const { imageKey, getUrl, byteSize } = (await post.json()) as { imageKey: string; getUrl: string; byteSize: number };
    expect(getUrl).toBe(`/images/${imageKey}`);
    expect(byteSize).toBe(JPEG.byteLength);

    const get = await fetch(`${baseUrl}${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await get.arrayBuffer()).byteLength).toBe(JPEG.byteLength);
  });

  it("cross-user GET /images/* returns 404", async () => {
    const owner = await signIn();
    const post = await fetch(`${baseUrl}/images`, {
      method: "POST",
      headers: { authorization: `Bearer ${owner.accessToken}`, "content-type": "image/jpeg", "x-device-id": owner.deviceId },
      body: JPEG,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    const other = await signIn();
    const get = await fetch(`${baseUrl}/images/${imageKey}`, { headers: { authorization: `Bearer ${other.accessToken}` } });
    expect(get.status).toBe(404);
  });

  it("POST /images with a non-existent transactionId stores NULL but still 200s", async () => {
    const { accessToken, deviceId } = await signIn();
    const res = await fetch(`${baseUrl}/images?transactionId=${crypto.randomUUID()}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG,
    });
    expect(res.status).toBe(200);
    // The image is still retrievable (saved despite the dangling txn link).
    const { getUrl } = (await res.json()) as { getUrl: string };
    const get = await fetch(`${baseUrl}${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
  });
});
```

- [ ] **Step 2: Run the e2e suite and watch it PASS.**

```bash
npm run test:e2e
```
Expected (PASS): boots the worker once, applies migrations, and all four cases pass (extract stub §9 shape with inferred `gst:3.00` from total 33; image POST→GET round-trip; cross-user 404; non-existent-txn POST still 200 + retrievable). The whole `e2e/` glob (this file + the foundation e2e) runs green.

- [ ] **Step 3: Final full-suite gate + commit.**

```bash
npx vitest run && npm run test:e2e && npx tsc --noEmit && git add e2e/extract.e2e.test.ts && git commit -m "$(cat <<'EOF'
test(extract): black-box e2e for /extract stub + /images round-trip

Add e2e/extract.e2e.test.ts: boots the real worker via unstable_dev
(E2E_EXTRACT_MODE), signs in over the magic-link seam, and proves the
/extract deterministic stub §9 shape, the /images POST->GET owner round-trip,
the cross-user GET 404, and the non-existent-transactionId -> NULL-link but
still-200 + retrievable path. Mirrors snapceipt.e2e.test.ts.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done criteria

- `npx vitest run` (workers pool) and `npm run test:e2e` (Node/unstable_dev) both green; `npx tsc --noEmit` clean.
- `POST /extract` returns the §9 contract: stub when `E2E_EXTRACT_MODE==="1" || !DEEPSEEK_API_KEY` (`meta.stub:true`, `confidence:0.9`, `needsReview:false`, `attempts:0`); real DeepSeek path otherwise (≤3-attempt ladder, server confidence, AU-GST non-null guarantee, integer `deductible`). 400 on invalid body, 401 unauth, 429 over 30/user/hr (the limiter is mounted on BOTH the exact `/extract` path and `/extract/*`).
- `meta` always carries all five fields `{ model, source, latencyMs, attempts, stub }`; `attempts` is `0` on the stub path and `≥1` on the real path.
- `deductible` on the wire is always an integer literal (`0..100`) or `null` — `finalize()` `Math.round`s it so the iOS `Int?` decode never throws on a `50.0` token.
- The heuristic never mis-selects a bare 4-digit year/ABN/postcode as the total (cents-bearing candidates only; date lines skipped), and never returns `gst:null` while `total > 0`.
- `POST /images` stores the JPEG in R2 and inserts an FK-safe `receipt_images` row; `GET /images/*` streams the owner's object and 404s cross-user. Both auth-gated; limiters mounted on the exact path and the wildcard.
- All `/extract` + `/images` route mounts and limiters are wired in `src/app.ts` in ONE task (Task 8); Task 7's route is tested on a standalone Hono app with no `app.ts` dependency.
- The 9-key category set is identical across the DeepSeek prompt and the Zod enum; `extractionHeuristic.ts` is the single source for the stub and the fallback.
