# F5 — Quotes — Design

**Status:** Approved (brainstorm complete 2026-06-01) → writing-plans.
**Feature:** F5 in the remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`). Builds on F1–F4 (all shipped & merged to `main`). F6 Email-in and F7 Settings follow in their own cycles.
**Goal:** A Business-profile-only quote builder for AU sole traders — compose a quote (saved client, editable line items, GST, totals), then **Send** it: the backend assigns a sequential `SN-####`, renders a PDF (reusing F2's pipeline), and emails it to the client.

**Two plans:** backend (`…-quotes-backend.md`) + iOS (`…-quotes-ios.md`). §4 is the **authoritative cross-plan contract**.

---

## 1. Scope & non-goals

**In scope (v1):**
- A **Business-only** Quotes feature: a Home "Create Quote" quick action (shown only when the active profile is Business) → a **quotes list** → a **create/edit editor** (bill-to client, inline-editable line items, GST 10% toggle, live totals) → **Send**.
- A new **saved-clients address book** (`Client` synced entity) with a picker + inline "New client".
- **Backend send**: `POST /quotes/:id/send` reusing F2's export pipeline — recompute totals authoritatively, **atomically assign the next per-user `SN-####`** (only if unset), render a quote PDF (`pdf-lib`) → R2 → a signed 7-day download link, and email the client via `env.EMAIL` + `email_outbox` (`kind='quote_send'`, Reply-To = the trader), all **gated on `env.EMAIL`** like F2 (stub/no-op in dev).
- Per-profile scoping; local-first quote/line-item/client CRUD via the generic `/sync` (no new CRUD route — only the send route is new).

**Non-goals / deferred:**
- **Invoice UI** — the `accepted`/`invoiced` statuses are modeled, but invoice display/editing/sending is post-v1 (per roadmap).
- A **client send-history** view (the `sent_at` timestamp + status badge suffice for v1).
- On-device PDF generation (the backend `pdf-lib` path is authoritative).
- Drag-reorder of line items (order = row index); multi-currency (AUD only); extra client fields beyond name/email (no phone/address/ABN on `Client` in v1).

---

## 2. Architecture & navigation

F5 spans **backend + iOS**. The `Quote` + `QuoteLineItem` `@Model`s, their D1 tables, `EntityType.quote`/`.quoteLineItem`, and the `QuoteSyncMapper`/`QuoteLineItemSyncMapper` already exist and round-trip via the generic `/sync` — quote CRUD needs **no new persistence or sync code**. The only new persistence is the `Client` entity (§4.1) + a server-only `quote_counters` table.

**Backend** (reusing F2 export infra in `src/routes/export.ts`, `src/lib/pdfExport.ts`, `src/lib/exportToken.ts`, `src/lib/email.ts`):
- migration `0002` adds `clients` (synced) + `quote_counters` (server-only).
- `src/lib/pdfQuote.ts` (quote PDF builder), `src/routes/quotes.ts` (`POST /quotes/:id/send`, public `GET /quotes/dl/:token`), `sendQuoteEmail` in `src/lib/email.ts`, `'client'` registered in the backend sync-table registry, route mounted in `src/app.ts` with a `'quotes'` rate tier.

**iOS** (`Snapceipt/`):
- `Client` `@Model` + `EntityType.client` + `ClientSyncMapper` + `ModelContainer` registration.
- `Router` gains `.quotes` + `.quoteEditor(id: String?)` full-screen overlays (mirroring `.budgets`/`.budgetEditor`). The client picker is a `.sheet` local to the editor (not a router overlay).
- A Home **"Create Quote"** quick action (doc icon, `home.quick.quote`) shown only when the active `Profile.type == "business"`; the existing Mileage/WFH/Loyalty actions are unchanged.
- `QuoteListView` / `QuoteEditorView` / `ClientPickerSheet` / a success overlay; `QuoteListViewModel` / `QuoteEditorViewModel` / `ClientPickerViewModel`; `APIClient.sendQuote`.

**Flow:** Home (Business) → `.quotes` → tap a row (edit/resend) or "New quote" → `.quoteEditor(nil)` → pick client + line items + GST → **Send** → `POST /quotes/:id/send` → apply response (number/status/sentAt/totals) → success overlay → back to the list.

**Reuses:** F2's `pdf-lib`→R2→`signDownloadToken`→`email_outbox`/`env.EMAIL` pipeline; the overlay chrome (`LbHeader`/`SheetHeader`/`LbFloatingCTA`/`EmptyArt`), `Card`/`IconCircle`/`Icon`/`Palette`/`Radius`/`fmt`; the `@Observable @MainActor`+injected-deps VM pattern + `SyncEnqueuing.enqueue`; the `ExportSheet`/`ActivityView` share pattern (for "View PDF"); the 4-conformer `APIClient` pattern (Live/Stub/Preview/Mock); the `.accessibilityElement(children:.contain)` convention.

---

## 3. Data model

- **Unchanged scaffold:** `Quote` (`Snapceipt/Model/Entities/Quote.swift`) — `id, userId, profileId(String?), number?, clientName?, clientEmail?, gstEnabled(Bool=true), subtotalCents, gstCents, totalCents, currency("AUD"), status(String="draft"), validUntil?, sentAt?` + envelope; `QuoteLineItem` — `id, userId, profileId(nil), quoteId, itemDescription("description" on the wire), quantity, unitPriceCents, sortOrder, computed lineTotalCents` + envelope. D1: `quotes` + `quote_line_items` (the latter has `line_total_cents` GENERATED), status `CHECK IN ('draft','sent','accepted','declined','expired','invoiced')`, `UNIQUE ux_quote_number(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL`.
- **NEW `Client` entity** — the address book (§4.1).
- **NEW `quote_counters`** — server-only per-user sequence (§4.3).
- **Per-profile scoping:** quotes, their line items (via the parent quote), and clients all filter by the active Business `profileId`; create always sets `profileId` = active profile (the editor/picker VMs set it non-nil, closing the `Quote.profileId?` nullability gap vs the D1 `NOT NULL`).
- **Client snapshot:** picking a `Client` copies its `name`/`email` into the quote's `clientName`/`clientEmail` (no `clientId` FK — keeps a sent quote stable).
- **Status typing:** add `enum QuoteStatus: String { draft, sent, accepted, declined, expired, invoiced }` + a computed `Quote.statusValue` bridge over the raw `status` String (storage unchanged; mirrors the D1 CHECK) — the F4 `BarcodeFormat` pattern.
- **Totals:** computed on-device for the live UI + stored on the quote; the send route **recomputes** authoritatively from the line items before rendering the PDF.

---

## 4. Authoritative contract

### 4.1 `Client` entity (new synced entity)
- **iOS** `Snapceipt/Model/Entities/Client.swift`: `@Model final class Client: Syncable` with `id (@Attribute(.unique), ID.uuidv7())`, `userId`, `profileId: String?`, `name`, `email`, + envelope (`createdAt/updatedAt/deletedAt/rev/lastEditedDeviceId`); `entityType => .client`. Add `case client` to `EntityType`; register `ClientSyncMapper` in `SyncEntityRegistry` (upsert + payload + `SyncableMutableEnvelope`/`MutableSyncRow`, mirroring `BudgetSyncMapper`); register `Client.self` in `ModelContainer+Snapceipt`.
- **Backend** migration `0002`: `clients` table — `id TEXT PK, user_id TEXT NOT NULL, profile_id TEXT, name TEXT NOT NULL, email TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted_at INTEGER, rev INTEGER NOT NULL DEFAULT 0, last_edited_device_id TEXT`; indexes `ix_client_user_updated(user_id, updated_at)`, `ix_client_profile(profile_id) WHERE deleted_at IS NULL`. Register `'client'` in the backend sync-table registry so it round-trips via the generic `/sync/push`+`/sync/pull` (no CRUD route). Wire fields camelCase: `name`, `email`.

### 4.2 `QuoteTotals` (pure, both sides agree)
`subtotalCents = Σ (quantity × unitPriceCents)`; `gstCents = gstEnabled ? Int(round(Double(subtotalCents) × 0.10)) : 0`; `totalCents = subtotalCents + gstCents`. iOS exposes a pure `QuoteTotals.compute(lineItems:gstEnabled:) -> (subtotal:Int, gst:Int, total:Int)`; the backend send route computes the identical formula. GST is quote-level (per `gstEnabled`), 10% AU.

### 4.3 Backend `POST /quotes/:id/send` (the only new quote route)
- Auth: Bearer; the quote must belong to the authed `user_id`. Rate tier `'quotes'` (60/user/hr).
- Steps: (1) load the quote + its non-deleted line items; (2) **recompute** totals (§4.2) and persist them; (3) if `number IS NULL`, **atomically assign** the next per-user sequence and set `number = "SN-" + seq.padStart(4,'0')` — re-send keeps the existing number; (4) `buildQuotePdf` → R2 `${userId}/quotes/${id}.pdf`; (5) set `status='sent'`, `sent_at=<nowMs>`; (6) `INSERT email_outbox (kind='quote_send', related_id=<quoteId>, to_email=<clientEmail>, status='queued', export_format='pdf', export_r2_key=<key>)` then `sendQuoteEmail` (PDF attached, Reply-To = the authed trader's email) → update outbox `'sent'`/`'failed'`; **gated on `env.EMAIL`** (absent → no send, `emailed:false`, outbox left/ marked accordingly); (7) issue a signed download token (`signDownloadToken`, 7-day) for a public `GET /quotes/dl/:token` (streams the R2 PDF, IP-limited, in `PUBLIC_PATHS`).
- **Sequence:** server-only `quote_counters(user_id TEXT PRIMARY KEY, next_seq INTEGER NOT NULL)`; assign atomically with `INSERT INTO quote_counters(user_id, next_seq) VALUES(?, 1) ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1 RETURNING next_seq` → first send returns `1`, then `2, 3, …`, so concurrent sends never collide; `ux_quote_number` is the unique backstop.
- **Response** `{ number, sentAt, status, subtotalCents, gstCents, totalCents, pdfUrl, expiresAt, emailed }` (camelCase). Validation failures → `400 VALIDATION_FAILED`; missing client email when emailing → `400`.

### 4.4 Quote PDF (`src/lib/pdfQuote.ts`)
`buildQuotePdf(quote, lineItems, sender)` — clone `pdfExport.ts` (pdf-lib A4, `StandardFonts.Helvetica`/`HelveticaBold`, no images). Header: sender `Profile.name`, `ABN: <abn>` (if set), "Registered for GST" (if `gstRegistered`). Meta: `Quote SN-####`, issued date, "Valid until <validUntil>". Bill-to: client `name` + `email`. Body: a line-items table (Description / Qty / Unit / Amount, all `fmt`-style AUD). Totals: Subtotal, "GST (10%)" (only if `gstEnabled`), **Total**. Footer: "Valid for 14 days. Accepted quotes convert to an invoice."

### 4.5 iOS `APIClient.sendQuote`
Add to the `APIClient` protocol + all 4 conformers (Live `PUT/POST /quotes/:id/send`, Stub, Preview, Mock): `func sendQuote(_ id: String) async throws -> SendQuoteResponse`. `struct SendQuoteResponse: Decodable { let number: String?; let sentAt: Int?; let status: String; let subtotalCents: Int; let gstCents: Int; let totalCents: Int; let pdfUrl: String?; let expiresAt: Int?; let emailed: Bool }`. `MockAPIClient` records calls + returns a scripted response (the F3 `updateDevice` pattern). On success the editor applies `number/status/sentAt/totals` to the local `Quote` + saves (sync reconciles).

### 4.6 Router, screens & AccessibilityIDs
- `Overlay` adds `.quotes` (id `"quotes"`) + `.quoteEditor(id: String?)` (id `"quoteEditor-<id ?? new>"`); both full-screen (excluded from `sheetBinding`/`sheetContent`, mirroring `.budgets`/`.budgetEditor` incl. the `hasPrefix("quoteEditor")` guard).
- AccessibilityIDs (`Snapceipt/Shared/AccessibilityID.swift`): `homeQuickQuote = "home.quick.quote"`, `quotesScreen = "quotes.screen"`, `quoteRowPrefix = "quote.row."`, `quotesAdd = "quotes.add"`, `quoteEditorScreen = "quote.editor.screen"`, `quoteEditorClient = "quote.editor.client"`, `quoteEditorAddLine = "quote.editor.addLine"`, `quoteLineRowPrefix = "quote.line.row."`, `quoteEditorGst = "quote.editor.gst"`, `quoteEditorSend = "quote.editor.send"`, `clientPickerScreen = "client.picker.screen"`, `clientPickerAdd = "client.picker.add"`, `clientRowPrefix = "client.row."`. All screen containers use `.accessibilityElement(children:.contain)`.

### 4.7 Scoping & access invariant
Quotes/line-items/clients are scoped by the active `profileId` (never by mode/type, never nil on create). The Quotes feature is **Business-only**: the Home "Create Quote" quick action renders only when `Profile.type == "business"`; Personal profiles cannot reach it.

---

## 5. Backend detail

- `quote_counters` + `clients` in migration `0002`. The counter upsert is the only place numbers are minted; the `ux_quote_number` unique index is a backstop.
- `sendQuoteEmail(env, { to, quoteNumber, clientName, total, pdf, replyTo })` in `src/lib/email.ts` mirrors `sendExportEmail` (MIME via `mimetext/browser`, base64 PDF attachment, `env.EMAIL.send`); a `Mailbox` Reply-To = the trader's email. Gated on `env.EMAIL`; tests `vi.spyOn` it.
- `src/routes/quotes.ts` mounted in `src/app.ts`; `/quotes/dl/:token` added to `PUBLIC_PATHS`; a `'quotes'` rate tier (60/user/hr; the public download IP-limited like `/export/dl`).
- Quote create/edit/delete remain on the generic `/sync` — the send route is the only new quote endpoint.

## 6. iOS detail

- **View-models** (`@Observable @MainActor`, injected `context/sync/userId/profileId`):
  - `QuoteListViewModel`: `quotes` (profile-scoped, newest first), `reload()`, `delete(_:)` (soft-delete + enqueue).
  - `QuoteEditorViewModel`: `load(id?)`, working `[QuoteLineItem]` set, `gstEnabled`, client snapshot, computed `totals` (via `QuoteTotals`), `saveDraft()` (upsert quote + diff line items → enqueue `upsert`/`delete` per item, `sortOrder` = index), `send()` (saveDraft → `api.sendQuote(id)` → apply response → save), `canSend` (client + ≥1 line item).
  - `ClientPickerViewModel`: profile-scoped `clients`, `reload()`, `create(name:email:)` + enqueue.
- **Screens** (`Snapceipt/Features/Quotes/`): `QuoteListView` (`LbHeader` + rows [client · `fmt(total)` · status badge · date] + `EmptyArt` + `LbFloatingCTA "New quote"`); `QuoteEditorView` (`SheetHeader` + `SN-####` badge; bill-to card → `ClientPickerSheet`; inline line-item rows; GST toggle; live totals card; validity note; Send button with in-flight/error states); `ClientPickerSheet` (saved clients + search + inline "New client"); a success overlay (income-green ring + "Quote sent!" + summary + Done; degrades to "ready + View PDF" via `ExportSheet`/`ActivityView` when `emailed:false`).

## 7. File structure

**Backend (created):** `migrations/0002_quotes_clients.sql`, `src/lib/pdfQuote.ts`, `src/routes/quotes.ts`; **(modified):** `src/lib/email.ts` (+`sendQuoteEmail`), `src/app.ts` (mount + rate tier + PUBLIC_PATHS), the backend sync-table registry (+`client`), `src/env.ts` if needed. **Tests:** `test/pdfQuote`, `test/quotes-send`, `test/quote-counter`, `test/schema-clients`, `e2e/quotes.e2e`.

**iOS (created):** `Snapceipt/Model/Entities/Client.swift`; `Snapceipt/Features/Quotes/{QuoteStatus.swift, QuoteTotals.swift, QuoteListViewModel.swift, QuoteEditorViewModel.swift, ClientPickerViewModel.swift, QuoteListView.swift, QuoteEditorView.swift, ClientPickerSheet.swift}`; **(modified):** `Snapceipt/Model/EntityType.swift` (+`client`), `Snapceipt/Sync/SyncEntityRegistry.swift` (+`ClientSyncMapper`), `Snapceipt/Model/ModelContainer+Snapceipt.swift` (+`Client.self`), `Snapceipt/Sync/DTOs.swift` (+`SendQuoteResponse`), `Snapceipt/Sync/APIClient.swift` + `StubAPIClient.swift` + `SignInView.swift`(Preview) + `SnapceiptTests/Mocks/MockAPIClient.swift` (+`sendQuote`), `Snapceipt/App/Router.swift` (+cases), `Snapceipt/App/RootView.swift` (Home quick action + overlays + sheet exclusions), `Snapceipt/Shared/AccessibilityID.swift`, `Snapceipt/App/AppLaunch.swift` (seed). **Tests:** `SnapceiptTests/QuoteTotalsTests`, `QuoteViewModelTests`, `ClientPickerViewModelTests`, `SnapceiptUITests/QuotesUITests`.

## 8. Error handling
- Send needs network (PDF/email): on failure show an error + retry; the quote **stays `draft`** and **no number is consumed** (numbers are minted server-side only on success). Offline → drafts save; Send shows "connect to send".
- `env.EMAIL` absent (dev): send still returns the PDF + signed link; `emailed:false` → success copy degrades to "ready" + "View PDF".
- Send disabled until a client + ≥1 line item; light email-format check on client create. Saves are optimistic local-first; sync failures ride the existing outbox/retry.

## 9. Testing
- **Backend:** `buildQuotePdf` (valid PDF bytes); send route (totals recompute, **atomic `SN-####`**, **idempotent re-send keeps the number**, `status→sent`/`sentAt`, email **gated + `vi.spyOn`-stubbed**, signed link); counter atomicity (two sends → distinct numbers); a `clients` schema/round-trip test; e2e `POST /quotes/:id/send` + `GET /quotes/dl/:token`.
- **iOS unit (Swift Testing):** `QuoteTotals.compute` (subtotal, GST rounding, GST-off); `QuoteEditorViewModel` (load, save-draft line-item diffing + enqueue, `canSend`, `send` applies the `MockAPIClient` response); `QuoteListViewModel` (profile-scope, delete+enqueue); `ClientPickerViewModel` (create+enqueue, profile-scope); `QuoteStatus` bridge; `SendQuoteResponse` decode.
- **iOS UI (hermetic, seeded):** seed a Business profile (active) + a `Client` + a `Quote`; Home "Create Quote" (Business-only) → list → new editor → pick client → add line item → toggle GST → **Send** (Mock stubs `sendQuote`) → success → list shows the quote. Real PDF/email = backend tests + manual QA.

## 10. Out of scope / deferred
Invoice UI (statuses modeled only); client send-history view; on-device PDF; line-item drag-reorder; extra `Client` fields (phone/address/ABN); multi-currency; a quote-number reset/series config.

## 11. Decisions log (brainstorm 2026-06-01)
1. **PDF + send:** backend PDF (reuse F2 `pdf-lib`/R2/signed-link) + **email the client** via `email_outbox 'quote_send'`/`env.EMAIL` (Reply-To = trader); gated on `env.EMAIL` like F2.
2. **Numbering:** **server assigns `SN-####` at send** (atomic per-user counter; drafts have no number; re-send keeps it).
3. **List + editor** (not editor-only).
4. **Saved-clients address book** — a NEW `Client` synced entity (+ migration `0002`) + picker; the quote snapshots name/email.
5. **Business-only** entry (Home "Create Quote" quick action, Business mode only); per-profile scoping. Invoice conversion modeled but UI deferred.
