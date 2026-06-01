# Receipt Capture → Extraction → Review → Save — Design Spec

- **Status:** Approved (brainstorm) — proceeding to implementation plans
- **Date:** 2026-05-30
- **Branch:** `foundation`
- **Builds on:** the Snapceipt foundation — iOS (`Snapceipt/` + `SnapceiptTests/` + `SnapceiptUITests/`) and the Cloudflare backend (root `src/`, D1 `migrations/0001_init.sql`, `wrangler.jsonc`). Reuses the on-device capture/OCR primitives in root `ReceiptScanner.swift`.

---

## 1. Goal

Implement the headline Snapceipt feature: **snap a receipt → on-device OCR → AI extraction → review/edit → save a transaction**, with the full designed 4-stage experience. AUD-only.

The user captures a receipt with VisionKit, the device runs Vision OCR to text, the backend `POST /extract` calls DeepSeek (JSON mode) to return structured fields, the user reviews/edits on a designed Review screen, and saving creates a `Transaction` (+ `LineItem`s) that syncs, plus uploads the (size-reduced) receipt image to R2.

**Decisions locked in brainstorming:**
- **Full designed flow** — all four stages with their animations (scan-line, one-by-one field-reveal chips, AI-suggestion banner + confidence badge, confetti saved screen), per `docs/superpowers/specs/extracted/screens.md` CaptureFlow.
- **On-device heuristic fallback** — if extraction is unavailable (offline / call fails), fall back to the on-device `HeuristicParser` (merchant/date/total/GST) so capture+save still work; mark `extractionStatus="pending"` and re-extract when back online.
- **Stub seam, no key yet** — the real DeepSeek call is wired but a deterministic dev/E2E stub (`E2E_EXTRACT_MODE`, and auto-stub when `DEEPSEEK_API_KEY` is absent) makes the whole feature testable hermetically with no key.
- **Image size reducer** before R2 upload (added per user) — downscale + recompress on-device so uploads are bounded.

**Non-goals (later phases):** email-in receipts (Workers AI OCR), Activity/Reports tab content, presigned-URL uploads, server-side thumbnail generation, multi-page receipts beyond page 0, live DeepSeek verification (no key this iteration), per-line-item editing on Review (line items are shown read-only and saved as extracted), `reviewReasons`/`fieldConfidence`/per-field highlighting (cut — `needsReview` is a single boolean), gallery/PDF import from CameraStep.

## 2. Architecture

**Smart backend, thin client.** All extraction logic — the DeepSeek call, JSON-schema validation, the retry ladder, and confidence scoring — lives server-side in `POST /extract`. The iOS client calls it once per scan and owns only the *offline fallback* + *image reduction/upload*. The `DEEPSEEK_API_KEY` never ships in the app.

Delivered as **two implementation plans** under this one shared contract (**§9 is authoritative and self-contained** — an engineer can build either side from §9 alone):
- **Plan A — Backend extraction + image service** (`src/`): `POST /extract`, `POST /images`, `GET /images/*`.
- **Plan B — iOS capture flow** (`Snapceipt/`): the 4-stage capture UI, the view-model, the extraction/upload clients, the offline fallback + re-extract, the save mapping.

Backend routes are **root-mounted (no `/v1` prefix)**, matching the implemented Worker. (The older `extracted/backend.md` uses `/v1/...` and an OLD category set — the implemented conventions win; see §9.)

## 3. Backend — `POST /extract`

**Auth:** required (Bearer; not in `PUBLIC_PATHS`). **Rate limit:** a NEW `"extract"` tier (calls an external API). Route in `src/routes/extract.ts`; mounted + rate-limited in `src/app.ts`; tier added to `src/middleware/rateLimit.ts`.

**Request** (`application/json`) — `defaultCurrency`/`locale`/`capturedAt`/`requestId` are **optional** (server defaults), so the 3-arg iOS client is valid:
```jsonc
{
  "ocrText": "THE GROUNDS\n28/05/2026\nFlat White x2  9.00\nBig Brekkie 24.00\nGST 3.86\nTOTAL 42.50",
  "source": "scan",                 // "scan" | "email_in"  (required)
  "defaultCurrency": "AUD",          // optional, default "AUD"
  "locale": "en-AU",                 // optional, default "en-AU"
  "capturedAt": "2026-05-28",        // optional, YYYY-MM-DD
  "requestId": "..."                 // optional; ECHO-ONLY in v1 (no server dedupe)
}
```

**Response** `200` (`needsReview` may be true on 200 — the client still shows Review):
```jsonc
{
  "requestId": "...",                // echoes request.requestId or a server-generated id
  "receipt": {
    "merchant": "The Grounds",
    "date": "2026-05-28",            // YYYY-MM-DD; falls back to capturedAt/today if unparseable
    "currencyCode": "AUD",
    "total": 42.50,                  // number (DOLLARS), >= 0 always
    "gst": 3.86,                     // number (dollars); see GST rule below (non-null when total>0)
    "category": "meals",             // EXACTLY one of the 9 keys (§9)
    "deductible": 50,                // 0..100 | null
    "lineItems": [ { "name": "Flat White x2", "price": 9.00 }, { "name": "Big Brekkie", "price": 24.00 } ],
    "confidence": 0.98,              // 0..1, server-computed
    "needsReview": false
  },
  "meta": { "model": "deepseek-chat", "source": "scan", "latencyMs": 812, "attempts": 1, "stub": false }
}
```

**GST rule (pins nullability):** on a 200 response `gst` is **non-null whenever `total > 0`** — if the model/OCR did not provide GST, the server sets `gst = round(total/11 * 100)/100` (AU 10% GST is 1/11 of a GST-inclusive total). `gst` is `null` only when `total == 0` (e.g. income with no GST). iOS maps `gst == null → gstCents = nil`.

**DeepSeek call (real path):** `POST https://api.deepseek.com/chat/completions`, `Authorization: Bearer $DEEPSEEK_API_KEY`, body `{ model: env.DEEPSEEK_MODEL, response_format:{type:"json_object"}, temperature:0, max_tokens:1500, messages:[system,user] }`. `env.DEEPSEEK_MODEL` defaults to `"deepseek-chat"` (a real DeepSeek model id) and is the value echoed in `meta.model`. Both prompts contain the word "json". 20 s hard timeout; exponential backoff on transient 429/5xx.

**System prompt (verbatim category list — the SINGLE source the Zod enum mirrors):**
> You extract structured data from noisy Australian receipt OCR text. Respond with ONLY a json object, no prose, no markdown fences:
> `{ "merchant": string, "date": "YYYY-MM-DD", "currencyCode": "AUD", "total": number, "gst": number|null, "category": one of ["meals","groceries","fuel","software","office","home","health","travel","income"], "deductible": number 0-100|null, "lineItems": [{"name": string, "price": number}], "confidence": number 0-1 }`
> Rules: AUD only. `category` MUST be exactly one of the nine keys above (no others). If GST isn't printed, set `gst` to total/11 rounded to cents. Set `deductible` to the per-category default unless the receipt clearly implies otherwise: meals 50, groceries 0, fuel 100, software 100, office 100, home 50, health 0, travel 100, income null. `total` is the GST-inclusive grand total as a positive number. Use `income` only for money received.

**Validation + retry ladder (≤3 attempts):**
1. Parse + Zod-validate against the receipt schema (types; `category` ∈ the 9 keys; ranges).
2. On invalid → one corrective re-prompt (include the validation errors; "return valid json").
3. On still-invalid → strip ``` fences / extract the first `{...}` and re-validate.
4. On exhaustion → the **safe fallback** (the same deterministic heuristic as the stub, §below): merchant = first letter-rich line; total = largest amount; `category = "office"`; `deductible = 100`; `gst = round(total/11)`; `needsReview = true`; `confidence` low (~0.4).

**Confidence (server-computed, never self-graded):** `finalConfidence = clamp01(0.55·modelStated + 0.25·ocrQuality + 0.20·arithmeticConsistency)`. `modelStated` = the model's own 0..1 (0.7 if absent); `ocrQuality` = heuristic on `ocrText` length/structure; `arithmeticConsistency` = 1 if `sum(lineItems.price) ≈ total` (±5%) else 0.5. **`needsReview = finalConfidence < 0.80 || validationFellBack`.**

**Dev/E2E stub seam:** when `env.E2E_EXTRACT_MODE === "1"` **or** `!env.DEEPSEEK_API_KEY`, skip the network call and return a **deterministic** extraction from the same heuristic as the fallback, but `needsReview:false`, `confidence:0.9`, `meta.stub:true`. Gated exactly like the existing `E2E_TEST_MODE` magic-link seam — never the real path in production with a key set.

**Errors:** `400` invalid body (Zod), `401` no/expired auth, `429` rate limited. (The fallback is local, so a usable `200` is essentially always produced; there is no `502` path in v1.)

## 4. Backend — `POST /images` + `GET /images/*`

**`POST /images`** (auth; rate tier `"default"`). Body: raw JPEG bytes (`Content-Type: image/jpeg`). **All metadata is URL query params (never headers):** `transactionId?`, `pageIndex` (default 0), `width?`, `height?`, `ocrText?` (capped length). Worker:
1. Validates content-type `image/jpeg` and `byteSize ≤ 6_291_456` (6 MiB guard; the client reduces well below this).
2. Writes to R2: `env.RECEIPTS.put("u/{userId}/{uuid}.jpg", body, { httpMetadata:{ contentType:"image/jpeg" } })`.
3. **FK-safe link:** sets `receipt_images.transaction_id = transactionId` **only if** a `transactions` row with that id exists for this `userId`; otherwise stores `NULL` (the image is still saved). This makes the insert safe regardless of sync ordering (no FK violation).
4. Inserts the `receipt_images` row (existing table): `id`(uuidv7), `user_id`, `profile_id`(null), `transaction_id`(per step 3), `r2_key`, `thumb_r2_key`(null v1), `content_type`, `byte_size`, `width`, `height`, `page_index`, `ocr_text`, `ocr_source:"vision_on_device"`, `extraction_json`(null v1), `extraction_model`(null v1), `source:"scan"`, + sync envelope (`created_at/updated_at/rev/last_edited_device_id`, `deleted_at` null).
5. Returns `{ imageKey, getUrl, byteSize }` where `imageKey` = the **full** R2 key `u/{userId}/{uuid}.jpg` and `getUrl = "/images/" + imageKey`.

**`GET /images/*`** (auth) — a **wildcard** route (Hono `:key` is single-segment and cannot match the slash-bearing key). Read `key = c.req.path.slice("/images/".length)`. Ownership: `key` must start with `u/{currentUserId}/`, else `404`. Streams the R2 object with its content-type. (v1 mostly exercises POST.)

**Tests:** vitest with the R2 binding mocked (put/get) + the auth/ownership path; an e2e (`unstable_dev`) POST a small JPEG → 200 + key, GET it back, cross-user GET → 404, and "transactionId of a non-existent txn → stored NULL, still 200".

## 5. iOS — capture primitives (reuse)

Lift the reusable pieces of root `ReceiptScanner.swift` into `Snapceipt/Features/Capture/Scanner/` and **delete the root file** (its stray `@Model Receipt`/`@Model LineItem` collide with the app's entities; its `ReceiptScanFlow`/`ReceiptReviewForm` use wrong models + no design system; USD default is wrong):
- **`DocumentScannerView`** (`UIViewControllerRepresentable` over `VNDocumentCameraViewController`) — kept as-is.
- **`OCR.recognize(in:languages:)`** — kept; languages **`["en-US","en-GB"]`** (Vision does NOT support an `en-AU` tag; drop zh). Optionally validate against `VNRecognizeTextRequest.supportedRecognitionLanguages()`.
- **`HeuristicParser`** + `ParsedReceipt` + `RecognizedLine` — kept, **retuned to AUD** and AU GST (`tax = total/11` when no GST/tax line), used for the offline fallback.

## 6. iOS — the capture flow

`Snapceipt/Features/Capture/`:
- **`CaptureViewModel`** (`@Observable @MainActor`) — stage machine `enum CaptureStage { case camera, scanning, review, saved }`, holding the captured `UIImage`, `rawText`, an `ExtractedReceipt` draft (editable), `errorMessage`, live `confidence`/`needsReview`. Injected dependencies (protocols, for tests): `ExtractionClient` (the `APIClient`), `ImageReducing`, plus the existing `SyncEnqueuing` protocol (already defined in `ProfilesStore.swift`, `extension SyncEngine: SyncEnqueuing`), `ProfilesStore`, and `ModelContext`. Drives:
  - `onScanned(image:)` → `rawText = OCR.recognize(...)`; `stage=.scanning`; call `extract()`.
  - `extract()` → `try api.extract(ocrText:source:capturedAt:)`. Success → map → `ExtractedReceipt` draft, `extractionStatus="done"`, `stage=.review`. Failure → `HeuristicParser.parse` → draft, `extractionStatus="pending"`, `needsReview=true`, `stage=.review` (never dead-ends offline).
  - `save()` → persist (§7), `stage=.saved`.
- **`ExtractedReceipt`** — editable struct mirroring the receipt fields **plus the Review-editable extras**: `merchant`, `date` (`String` YYYY-MM-DD), `total` (`Decimal`), `gst` (`Decimal?`), `categoryKey` (`String`), `deductible` (`Int?`), `paymentMethod` (`String?`), `taxLabel` (`String?`), `lineItems` (`[(name,price)]`), `confidence` (`Double`), `needsReview` (`Bool`), `extractionStatus` (`String`).
- **`ExtractionResponse`** (Codable) — decodes the §3 response; the receipt's category Codable key is **`category`** (not `categoryKey`), decoded into `ExtractedReceipt.categoryKey`.
- **`ExtractionClient`** = the `APIClient` protocol gains `extract(ocrText:source:capturedAt:) async throws -> ExtractionResponse`; `LiveAPIClient.extract` POSTs `/extract` hard-coding `defaultCurrency:"AUD", locale:"en-AU"` and generating `requestId`. `source` is a String ("scan"|"email_in").
- **`ImageReducing`** (the reducer) — `func reduce(_ image: UIImage) -> Data` (JPEG). Policy: downscale longest edge ≤ **2000 px** (preserve aspect), JPEG quality **0.6**, stepping **0.5/0.4/0.3** until `byteCount ≤ 1_500_000` (hard) or quality floor 0.3. Pure + unit-tested (asserts dimension ≤ 2000 and bytes ≤ 1_500_000 on a known image).
- **`uploadImage`** on `APIClient`: `uploadImage(jpeg:transactionId:width:height:) async throws -> UploadedImage` where `UploadedImage { imageKey: String; getUrl: String; byteSize: Int }`. `LiveAPIClient` POSTs `/images` with the query params (`transactionId,width,height`; `pageIndex` defaults server-side; `ocrText` omitted in v1).

## 7. iOS — save + sync + offline queues

On `save()`:
1. Map the (possibly edited) `ExtractedReceipt` → `Transaction`: `merchant`; `catKey = categoryKey`; `amountCents = round(total*100)` then **negate unless `categoryKey == "income"`** (income positive, all 8 others negative; `total >= 0`; the extractor never returns "custom"); `currency:"AUD"`; `txnDate = date`; `mode` = active profile type literal **`"personal"`|`"business"`** (lowercase); `gstCents = gst == nil ? nil : round(gst*100)`; `deductiblePct = deductible` (1:1, null stays null); `paymentMethod`; `taxLabel`; `isAi:true`; `source:"scan"`; `extractionStatus` ("done"|"pending"); `profileId` = active profile id; `userId` = session user id. Plus `LineItem`s: `priceCents = round(price*100)`, `sortOrder = array index`, `quantity = 1`, `userId` from session, `profileId = nil`, `transactionId` = parent.
2. `context.insert(...)`, `sync.enqueue(op:"upsert", entityType:.transaction, entity: txn)` + one enqueue per `.lineItem`.
3. **Local artifact:** insert a **local-only** `@Model PendingReceipt` (NOT `Syncable`, NO `EntityType` case, NEVER passed to `sync.enqueue`): `id`, `transactionId`, `ocrText` (so re-extract has a source), `imageLocalPath` (the reduced JPEG saved under Application Support), `width`, `height`, `uploadState` ("pending"|"done"|"failed"), `uploadAttempts`, `extractionAttempts`, `createdAt`. (The reducer runs here: `let jpeg = ImageReducing.reduce(capturedImage)` → written to `imageLocalPath`.)
4. **Image upload (`ReceiptUploadQueue`):** drains `PendingReceipt` rows with `uploadState=="pending"` on reconnect/foreground (uses `Reachability`, mirrors the sync outbox). For each, it uploads **only after the parent transaction's outbox mutation is applied** (so the server row exists; the worker is also FK-safe per §4). On success → `uploadState="done"`, delete the local JPEG. After a bounded `uploadAttempts` → `uploadState="failed"` (stop).
5. **Re-extract (`PendingExtractionReconciler`):** finds `Transaction`s with `source=="scan" && extractionStatus=="pending"` whose `PendingReceipt.ocrText` is available; when online, re-calls `extract`, updates `catKey/gstCents/deductiblePct/isAi`, sets `extractionStatus="done"`, re-enqueues the upsert. After bounded `extractionAttempts` → set `extractionStatus="failed"` and stop re-queuing. Runs on shell appear/reconnect; processes ≤N per pass and `log`s if capped.
6. When a `PendingReceipt` has `uploadState ∈ {done,failed}` AND its transaction's `extractionStatus ∈ {done,failed}` → delete the `PendingReceipt` row (+ local file).

## 8. iOS — UI (full designed flow) + shell wiring + test seam

Four SwiftUI steps in `Snapceipt/Features/Capture/Views/`, applying the design system (`Palette`, `.font(.ui/.display)`, accent) and recoloring live to the active profile accent:
- **CameraStep** — full-bleed `DocumentScannerView`. **VNDocumentCameraViewController provides the shutter, auto-capture, edge detection/dewarp, and flash natively** — we do NOT rebuild those. The only custom chrome is a Close affordance returning to the shell; the designed custom mode-pill / corner brackets / gallery-import / PDF-import are **deferred (non-goals)**.
- **ScanStep** — receipt thumbnail + animated scan line; the 5 field-reveal chips `[Merchant, Date, GST, Total, Category]` flip pending→found as extraction resolves (driven by real state, staggered for feel); auto-advance to Review when done.
- **ReviewStep** — the designed editable card: "Total detected" + amount + GST pill; the **AI-suggestion banner** (gradient/border accent) whose body is the template **"Looks like a {merchant} — filed under {Category label}, claimable at {deductible}%."** (deductible clause omitted when null); the **confidence badge** = `min(round(confidence*100), 99)`, shown **iff `!needsReview`**; editable Merchant / Date / Category (picker over the 9 `CATS`) / Payment / Tax-label; Personal/Business profile toggle (re-skins live); a small read-only line-items list (an intentional addition beyond the prototype, which shows them only in the thumbnail); disabled "Add to mileage" / "Match to bank" chips; bottom **Save receipt** button. When `needsReview`, the banner shows a neutral "Double-check the details" message instead of the confident template. A11y ids on the key controls.
- **SavedStep** — confetti + green success ring/checkmark; "Receipt saved!" + summary; **Snap another** (restart) / **Done** (dismiss).

**Shell wiring:** replace `RootView.capturePlaceholder` — the Snap tab (`tabbar.snap` → `router.go(.tab(.snap))` → `.capture` overlay) now presents the `CaptureFlow` (the 4 steps) full-screen instead of "coming soon".

**Test seam (camera-less simulator):** VisionKit's camera can't run in the simulator/XCUITest. `CaptureViewModel` takes an injected **image source**: production = the real `DocumentScannerView`; under `AppLaunch.useStub` (`-uiTestStub`) a **canned bundled image + canned `rawText`** so the flow starts at `.scanning` without a camera. With `StubAPIClient.extract` (canned), the hermetic XCUITest harness drives **Scan → Review → Save → Saved**.

## 9. Canonical Contracts (authoritative & self-contained — both plans build from THIS section)

**Routes (root-mounted, no `/v1`):**
- `POST /extract` — auth; rate tier **`extract`** (NEW tier: `limit: 30, windowMs: 3_600_000, dimension: "user"` — add to `RateLimitKind` union + `RATE_LIMIT_TIERS` in `src/middleware/rateLimit.ts`).
- `POST /images` — auth; rate tier **`default`**.
- `GET /images/*` — auth; wildcard route; key = `c.req.path` after `/images/`; ownership = key prefix `u/{userId}/`.

**`/extract` request:** `{ ocrText (req), source ("scan"|"email_in", req), defaultCurrency? ("AUD"), locale? ("en-AU"), capturedAt? ("YYYY-MM-DD"), requestId? (echo-only) }`. Zod treats `defaultCurrency`/`locale`/`capturedAt`/`requestId` **optional with server defaults**.
**`/extract` response:** `{ requestId, receipt:{ merchant, date, currencyCode, total, gst, category, deductible, lineItems:[{name,price}], confidence, needsReview }, meta:{ model, source, latencyMs, attempts, stub } }`. **All amounts are DOLLARS on the wire.** Dropped from the older backend.md schema (intentional v1 cuts): `receipt.tax`, `meta.reviewReasons`, `meta.fieldConfidence`.

**Field-mapping table (wire → iOS draft → entity):**
| wire (response.receipt) | iOS draft (`ExtractedReceipt`) | entity (`Transaction`/`LineItem`) |
|---|---|---|
| `merchant` | `merchant` | `merchant` |
| `date` (YYYY-MM-DD) | `date: String` | `txnDate` |
| `total` (dollars ≥0) | `total: Decimal` | `amountCents = round(total*100)`, **negated unless `category=="income"`** |
| `gst` (dollars, non-null iff total>0) | `gst: Decimal?` | `gstCents = gst==nil ? nil : round(gst*100)` |
| `category` (1 of 9 keys; Codable key **`category`**) | `categoryKey: String` | `catKey` |
| `deductible` (0..100\|null) | `deductible: Int?` | `deductiblePct` (1:1, null→null) |
| `lineItems[].name` / `.price` | `lineItems` | `LineItem.name` / `priceCents=round(price*100)`, `sortOrder=index`, `quantity=1` |
| `confidence` / `needsReview` | same | (not persisted; drive badge/banner) |
| — | `paymentMethod: String?` | `paymentMethod` |
| — | `taxLabel: String?` | `taxLabel` |

**Other pinned rules:**
- **9 category keys:** `meals, groceries, fuel, software, office, home, health, travel, income` (= `Snapceipt/Model/Categories.swift` `CATS`; `income` is the only positive-amount key). The DeepSeek system-prompt list and the Zod enum MUST equal this set.
- **GST non-null guarantee:** `gst` non-null when `total>0` (server infers `round(total/11*100)/100`); null only when `total==0`.
- **needsReview/badge:** server `needsReview = confidence<0.80 || validationFellBack`; iOS shows the badge `min(round(confidence*100),99)` iff `!needsReview`; offline-heuristic path forces `needsReview=true` (badge hidden).
- **`mode`:** `Transaction.mode ∈ {"personal","business"}` (lowercase, from active `profile.type`). Scope every txn by `userId` + `profileId` (never by `mode`).
- **`/images`:** POST raw `image/jpeg`; query `transactionId?,pageIndex=0,width?,height?,ocrText?`; iOS sends `transactionId,width,height`. Returns `{ imageKey, getUrl, byteSize }`, `imageKey` = full key `u/{userId}/{uuid}.jpg`, `getUrl = "/images/"+imageKey`. Worker sets `transaction_id` only if the parent txn exists (else NULL).
- **Image reducer:** longest edge ≤ 2000 px; JPEG 0.6→0.5/0.4/0.3 until `≤ 1_500_000` bytes or floor 0.3. Server guard `≤ 6_291_456` bytes.
- **Stub gate:** `E2E_EXTRACT_MODE==="1"` OR missing `DEEPSEEK_API_KEY` → deterministic stub (`meta.stub:true`, `needsReview:false`, `confidence:0.9`); fallback default `category:"office"`.
- **Env:** add `E2E_EXTRACT_MODE?: string` and `DEEPSEEK_MODEL?: string` (default `"deepseek-chat"`) to `src/env.ts` `Env`; `DEEPSEEK_API_KEY` already present. Bindings `RECEIPTS` (R2), `AI` already in `wrangler.jsonc`.
- **iOS `APIClient` additions** (protocol + LiveAPIClient + StubAPIClient + `MockAPIClient` [`SnapceiptTests/Mocks/MockAPIClient.swift`] + `PreviewAPIClient` [`Snapceipt/Features/Auth/SignInView.swift`]): `extract(ocrText:source:capturedAt:) -> ExtractionResponse`, `uploadImage(jpeg:transactionId:width:height:) -> UploadedImage`. **All five conformers must gain both** or it won't compile.
- **`PendingReceipt`** is a **local-only `@Model`** (registered in `SnapceiptSchema.models`, NOT `Syncable`, NO `EntityType` case, NEVER passed to `sync.enqueue`).

## 10. Error handling

- **Extraction unavailable** (offline/timeout/non-2xx) → `HeuristicParser` fallback, `extractionStatus="pending"`, `needsReview=true`; Review still opens. Reconciler upgrades later; after bounded attempts → `extractionStatus="failed"` (stop).
- **Validation fallback** (server) → `needsReview:true`, low confidence; badge hidden; neutral banner.
- **Image upload failure/offline** → queued in `PendingReceipt`; retried on reconnect (after txn sync); after bounded attempts → `uploadState="failed"`. The transaction is saved regardless.
- **Save with no active profile** → guarded (assert + surface an error, never write a malformed txn).
- **Camera permission denied** → existing priming + a clear "enable in Settings" path.

## 11. Testing strategy

- **Backend (vitest):** `/extract` — stub determinism; the validation/retry ladder (DeepSeek `fetch` mocked: valid→1 attempt; invalid-then-valid→2; always-invalid→fallback `needsReview`); confidence math; AU GST inference + the `gst` non-null guarantee; the category enum rejects an out-of-set value; auth/rate-limit. `/images` — put→row→get round-trip (R2 mocked), ownership 404, size/type guard, "transactionId of non-existent txn → NULL, still 200". **e2e (`unstable_dev`):** extract in `E2E_EXTRACT_MODE` returns the canned shape; image POST→GET; cross-user GET 404.
- **iOS (Swift Testing):** `ImageReducer` (dim ≤2000 + bytes ≤1_500_000 on a known image); the `ExtractedReceipt`→`Transaction` mapping (sign by `income`, cents, gst null→nil, `mode` lowercase, `taxLabel`/`paymentMethod`, line-item cents/sortOrder/quantity); `CaptureViewModel` (scanned→scanning→review on success; failure→heuristic+pending; save inserts txn+lineItems + enqueues + creates `PendingReceipt`); `extract`/`uploadImage` over `MockURLProtocol`; the reconciler (pending→done; bounded→failed); the upload queue (gates on txn-applied; done deletes file).
- **XCUITest:** `StubAPIClient` gains `extract`/`uploadImage`; under `-uiTestStub` the canned-image seam; `CaptureUITests` drives Snap tab → Scan → Review (assert fields + confidence badge) → Save → Saved ("Receipt saved!"). New `AccessibilityID` capture ids.

## 12. File structure (informs the two plans)

**Backend (Plan A):**
```
src/routes/extract.ts            # POST /extract (DeepSeek + stub + validate/retry/confidence)
src/routes/images.ts             # POST /images, GET /images/* (R2, FK-safe link)
src/lib/deepseek.ts              # DeepSeek client + prompt builder + retry ladder
src/lib/extractionHeuristic.ts   # deterministic heuristic (stub + fallback) — single source
src/schemas/extract.ts           # Zod request + receipt schemas (category enum = 9 keys)
src/middleware/rateLimit.ts      # MODIFY: add 'extract' tier + RateLimitKind member
src/app.ts                       # MODIFY: mount /extract, /images + rate limiters
src/env.ts                       # MODIFY: E2E_EXTRACT_MODE?, DEEPSEEK_MODEL? (DEEPSEEK_API_KEY present)
test/extract.test.ts, test/images.test.ts, e2e/extract.e2e.test.ts
```
**iOS (Plan B):**
```
Snapceipt/Features/Capture/Scanner/{DocumentScannerView,OCR,HeuristicParser}.swift  # lifted from root ReceiptScanner.swift (then delete the root file)
Snapceipt/Features/Capture/CaptureViewModel.swift
Snapceipt/Features/Capture/ExtractedReceipt.swift          # + ExtractionResponse/UploadedImage Codables
Snapceipt/Features/Capture/ImageReducer.swift
Snapceipt/Features/Capture/PendingReceipt.swift            # local-only @Model
Snapceipt/Features/Capture/ReceiptUploadQueue.swift
Snapceipt/Features/Capture/PendingExtractionReconciler.swift
Snapceipt/Features/Capture/Views/{CameraStep,ScanStep,ReviewStep,SavedStep,CaptureFlow}.swift
Snapceipt/Sync/APIClient.swift              # MODIFY: extract + uploadImage on protocol + LiveAPIClient
Snapceipt/Sync/StubAPIClient.swift          # MODIFY: canned extract/uploadImage
Snapceipt/Features/Auth/SignInView.swift    # MODIFY: PreviewAPIClient gains both methods
Snapceipt/Shared/AccessibilityID.swift      # MODIFY: capture ids
Snapceipt/App/RootView.swift                # MODIFY: Snap tab overlay -> CaptureFlow
Snapceipt/Model/SnapceiptSchema.swift       # MODIFY: register PendingReceipt (local @Model); update doc comment
SnapceiptTests/Mocks/MockAPIClient.swift    # MODIFY: extract/uploadImage handlers
SnapceiptTests/*  (CaptureViewModel, mapping, ImageReducer, reconciler, queue tests)
SnapceiptUITests/CaptureUITests.swift
```

## 13. Risks / notes

- **No DeepSeek key this iteration:** the real path is unverified live; the stub seam carries all automated tests. **Before activation:** `wrangler secret put DEEPSEEK_API_KEY`, and set `DEEPSEEK_MODEL` to the intended real model id (default `"deepseek-chat"`; the brainstorm named `deepseek-v4-flash`, which is not a current DeepSeek API model id — confirm the real id before going live). The code path is wired + unit-tested with a mocked `fetch`.
- **Camera in CI:** never runs in the simulator — the canned-image seam is mandatory for the capture XCUITest.
- **DeepSeek response variance:** mitigated by JSON mode + Zod (enum = the 9 keys) + the retry ladder + the local fallback (the user always reaches Review).
- **R2 in tests:** mocked in vitest; the e2e uses Miniflare's local R2.
- **Profile scoping:** transactions MUST carry `profileId` = active profile (never filter by `mode`).
- **OCR language tags:** use Vision-supported tags (`en-US`/`en-GB`), not `en-AU`.
