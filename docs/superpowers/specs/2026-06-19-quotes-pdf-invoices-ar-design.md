# Quotes PDF + Invoices & Accounts-Receivable — Design (2026-06-19)

## 1. Goal

Two related additions to the existing Quotes feature:

- **Part A — On-demand quote PDF.** Turn the (currently grey/disabled) `doc` button in the quote
  editor into **"Generate / Share PDF"**: produce a shareable/savable quote PDF *without* emailing,
  and persist it so a past quote's PDF is re-shareable from the quotes list (history).
- **Part C — Invoices & full accounts-receivable.** Convert a quote into an **editable tax
  invoice**, issue it (number + tax-invoice PDF), email/share it, and track payment with **payment
  records** (unpaid / partially paid / paid), **overdue** detection, and **in-app** due-date
  reminders.

Quote history (a quotes list with status badges) **already exists** (`QuoteListView`); Part A's only
history work is persisting + re-sharing the PDF.

## 2. Authoritative decisions (confirmed — do not re-litigate)

1. **Generating a quote PDF does NOT mark the quote `sent`.** It mints the quote `number` if absent
   (so the PDF shows a real number) but leaves `status = draft` until the quote is emailed (Send) or
   converted. The PDF's R2 key is persisted on the quote → re-shareable from history.
2. **Invoices are a separate entity** (`Invoice` / `InvoiceLineItem` / `Payment`), NOT an overloaded
   `Quote` with a type flag. New `EntityType`s + `SYNCABLE_TYPES` + sync registry + `syncTables` +
   schemas, and an additive migration `0009`.
3. **Convert is editable.** "Convert to invoice" pre-fills an invoice editor from the quote; the user
   edits, then "Issue invoice" finalizes (number + PDF + due date) and flips the quote to
   `status = invoiced`, linked both ways.
4. **Full A/R via payment records.** Multiple `Payment` rows per invoice; payment state is **derived**
   (`unpaid` / `partial` / `paid`), not a single toggle. `overdue` = past `dueDate` and not fully paid.
5. **In-app reminders only — NO push.** Overdue / due-soon surface as soft amber badges + a
   "Needs attention" section in the Invoices list (and optionally a Home bell dot). Same soft framing
   as BAS; never alarming red. (Push remains a separate, deferred GA decision.)
6. **Invoice delivery mirrors quotes:** "Send invoice" (email via the existing `email_outbox`) **plus**
   share/save the PDF.
7. **Placement:** a **separate "Invoices" list** (sibling to Quotes), not a combined Sales hub.
8. **Tax math reuses the existing quote GST engine** (`QuoteTotals`); the invoice carries the same
   GST-enabled / GST-inclusive semantics as the quote it came from.

## 3. Part A — On-demand quote PDF

- **Button.** `QuoteEditorView`'s `doc` button becomes **"Generate / Share PDF"**, enabled whenever
  the quote is valid (a client + ≥1 line item) — not gated on `pdfUrl != nil`.
- **Flow.** Tap → save + `await sync.flush()` (the quote must exist server-side) → **`POST
  /quotes/:id/pdf`** → reuses `buildQuotePdf` (`src/lib/pdfQuote.ts`) → stores to R2 → returns
  `{ pdfUrl }` and persists `quotes.pdf_r2_key`; mints `number` if absent (no email, **no status
  change**). Then present the existing iOS share sheet (`QuoteActivityView`) for Share / Save to Files.
- **History re-share.** Because `pdf_r2_key` is persisted (and surfaced via the quote's sync row),
  re-opening a past quote shows an **enabled** Generate/Share button; tapping it always (re)builds
  the PDF from the current quote state and refreshes `pdf_r2_key`, so edits are always reflected. The
  persisted key is what lets the quotes list/detail offer the last-generated PDF.
- **Schema (migration 0009, additive):** `ALTER TABLE quotes ADD COLUMN pdf_r2_key TEXT` +
  `ADD COLUMN invoice_id TEXT` (the latter for §4.2's link). Threaded through `entities.ts`
  (quote) + `syncTables.ts` + iOS `Quote` model + `QuoteSyncMapper`.

## 4. Part C — Invoices & A/R

### 4.1 Data model

Three new synced entities (mirroring `Quote`/`QuoteLineItem` conventions: `@Attribute(.unique) id`,
`userId`, `profileId`, sync fields `createdAt`/`updatedAt`/`deletedAt`/`rev`/`lastEditedDeviceId`):

- **`Invoice`** — `number: String?` (minted on issue), `quoteId: String?` (origin link),
  `clientName/clientEmail: String?`, `gstEnabled: Bool`, `gstInclusive: Bool`,
  `subtotalCents/gstCents/totalCents: Int`, `currency: String`,
  `status: String` = `draft | issued | void`, `issueDate: String?` ("YYYY-MM-DD"),
  `dueDate: String?` ("YYYY-MM-DD"), `issuedAt: Int?`, `pdfR2Key: String?`.
- **`InvoiceLineItem`** — `invoiceId`, `itemDescription`, `quantity`, `unitPriceCents`, `sortOrder`
  (a clone of `QuoteLineItem`; `profileId` always nil — child of an invoice). `lineTotalCents = quantity * unitPriceCents`.
- **`Payment`** — `invoiceId`, `amountCents: Int`, `paidOn: String` ("YYYY-MM-DD"),
  `method: String?`, `note: String?`.

**Derived (not stored), computed identically on iOS and in the PDF builder:**
- `amountPaidCents(invoice)` = Σ non-deleted `Payment.amountCents` for the invoice.
- `paymentState` = `paid` if `amountPaid >= total`, else `partial` if `amountPaid > 0`, else `unpaid`.
- `isOverdue` = `status == issued && paymentState != paid && today > dueDate`.

**Sync wiring:** add `invoice`, `invoiceLineItem`, `payment` to `EntityType` (iOS) + `SYNCABLE_TYPES`
(`src/schemas/entities.ts`) + `SyncEntityRegistry` (iOS mappers) + `syncTables.ts` (backend
table/column maps) + per-entity Zod schemas. **Migration `0009`** creates `invoices`,
`invoice_line_items`, `payments` (additive new tables) and the two `quotes` columns from §3.

### 4.2 Convert flow (editable)

- **Entry:** on a quote with `status ∈ {sent, accepted}`, a **"Convert to invoice"** action (in the
  quote editor and/or the quotes list row).
- **Create draft:** client-side clones the quote → a new `Invoice(status: draft, quoteId: quote.id)`
  + cloned `InvoiceLineItem`s (client, GST flags, prices), `dueDate = today + 14 days` (editable),
  and opens an **Invoice editor** (a near-mirror of `QuoteEditorView`: bill-to, line items, GST
  toggles, totals, due-date picker).
- **Issue:** "Issue invoice" → save + `await sync.flush()` → **`POST /invoices/:id/issue`** mints the
  invoice number (§5), builds the tax-invoice PDF → R2, sets `status = issued`, `issueDate`/`issuedAt`,
  persists `pdf_r2_key`, returns `{ pdfUrl }`. Client then sets `quote.status = invoiced` +
  `quote.invoiceId = invoice.id` and enqueues both upserts. Re-converting a quote that already has an
  `invoiceId` opens the existing invoice instead of creating a second.

### 4.3 Tax-invoice PDF (`src/lib/pdfInvoice.ts`)

ATO tax-invoice content, reusing `pdfQuote.ts` drawing helpers: **"Tax invoice"** heading, seller
name + **ABN** + "Registered for GST" (from the profile), **invoice number**, **issue date** + **due
date**, bill-to (client name/email), line items (desc · qty · unit · line total), subtotal / GST(10%)
/ total, and "Total price includes GST $X". GST-inclusive mode relabels exactly as the quote PDF does.

### 4.4 Accounts-receivable

- **Record payment:** a "Record payment" action on an issued invoice → a `Payment` upsert
  (amount, date, optional method/note). Amount defaults to the outstanding balance.
- **Status badge** (derived, §4.1): `Draft` / `Issued · Unpaid` / `Issued · Partial` / `Paid` /
  `Overdue` (overdue takes visual precedence, soft amber).
- **In-app reminders:** the Invoices list opens with a **"Needs attention"** section — overdue first,
  then due-soon (within **7 days** of `dueDate`) — using the soft amber framing. The existing Home
  bell dot's unread-alert count also includes overdue invoices (reuse the alerts pattern; no new infra).

### 4.5 Delivery

Mirror quotes: **"Send invoice"** → **`POST /invoices/:id/send`** reuses the quote send/email path
(`email.ts` + `email_outbox`) to email the client the tax-invoice PDF, **plus** the same
Generate/Share PDF button for manual share/save. `email_outbox.kind` gains `'invoice_send'`
(migration `0009` rebuilds the `kind` CHECK; `related_id` = invoice id). A public
**`GET /invoices/dl/:token`** download mirrors `quotes/dl` (added to `PUBLIC_PATHS`).

### 4.6 Placement / IA

A new **`InvoiceListView`** (mirror `QuoteListView`): rows = client · total · status/payment badge ·
due-date; "Needs attention" section on top; tap → invoice editor/detail; swipe → soft-delete. Reached
from **Home** (a new "Invoices" quick action) — Pro-gated like Quotes. A `.invoices` /
`.invoiceEditor(id)` Router overlay pair mirrors `.quotes` / `.quoteEditor`. The quote↔invoice link is
shown on each (the quote row shows "Invoiced →"; the invoice shows "From quote #…").

## 5. Numbering

`src/lib/invoiceCounter.ts` mirrors `quoteCounter.ts` — a per-profile monotonic invoice sequence,
minted atomically on issue (never on draft). Quote numbering is unchanged (now also minted on first
PDF generation per §2.1).

## 6. Backend surface (new routes)

- `POST /quotes/:id/pdf` — build/store quote PDF, persist `pdf_r2_key`, mint number if absent, return
  `{ pdfUrl }`. No email, no status change.
- `POST /invoices/:id/issue` — mint number, build tax-invoice PDF → R2, set `issued` + dates +
  `pdf_r2_key`, return `{ pdfUrl, number }`.
- `POST /invoices/:id/send` — ensure PDF, email client (reuse quote email path), `email_outbox`
  `kind='invoice_send'`.
- `POST /invoices/:id/pdf` — (re)build/return the invoice PDF for share.
- `GET /invoices/dl/:token` — public PDF download (mirror `quotes/dl`).
- Payments + invoice drafts flow through the **generic sync upsert** (no bespoke route).

## 7. Testing

- **Pure logic (unit + golden):** A/R derivation (`amountPaid`/`paymentState`/`isOverdue` across
  unpaid/partial/paid/overdue + due-date boundaries), invoice totals (reusing/parallel to
  `QuoteTotals`), convert-clone (invoice mirrors the quote's fields + line items), tax-invoice PDF
  content assertions.
- **Backend (vitest):** `/quotes/:id/pdf` (no status change, mints number, persists key);
  `/invoices/:id/issue` (number minted once, status→issued, PDF stored); `/invoices/:id/send`
  (email path + outbox row); sync round-trips for the 3 new entities; `dl` token.
- **iOS view-models:** invoice editor (convert pre-fill, edits, issue), payment recording → derived
  state, list "Needs attention" ordering.
- **UI test:** convert quote → edit → issue → record a partial payment → status shows `Partial`.

## 8. Out of scope / non-goals (this cycle)

- **No push / notifications** — reminders are in-app badges only.
- **No payment gateway / online payment collection** — payments are manually recorded.
- **No recurring invoices, no multi-currency** beyond the existing AUD default.
- **No combined Sales hub** — Quotes and Invoices stay separate lists.
- Quote↔invoice is **one-to-one** (a quote converts to one invoice); splitting/partial-invoicing a
  quote is out.

## 9. Build phasing

The plan phase splits this into a **backend plan** (migration 0009, sync wiring for the 3 entities,
`pdfInvoice.ts`, `invoiceCounter.ts`, the 5 routes, `/quotes/:id/pdf`) and an **iOS plan** (the 3
models + mappers, `QuoteEditorView` Generate/Share button + persisted PDF, the invoice editor +
convert flow, `InvoiceListView` + A/R badges + Needs-attention, record-payment, Router + Home wiring).
Backend lands first (the iOS issue/send/pdf calls depend on the routes).
