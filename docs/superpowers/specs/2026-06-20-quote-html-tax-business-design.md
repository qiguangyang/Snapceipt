# Configurable GST + Business Profile + HTML Quotes — Design (2026-06-20)

## 1. Goal

Four related changes, one cycle:

1. **Configurable GST rate** — Tax & GST settings let a business pick the GST rate (presets **10%
   (Australia)** / **15% (New Zealand)** / **Custom %**), defaulting from the device region; it flows
   into quote/invoice totals and capture GST.
2. **HTML quotes** — replace the directly-generated quote PDF with a **hosted HTML quote page**
   (shareable link); the PDF is derived **on-device** from that HTML on demand.
3. **Business profile details** — address, phone, website, **business email**, logo, and
   **bank/payment details** (ABN already exists), used on the quote.
4. **Remove the duplicate "Review" button** on the Reports BAS card.

## 2. Authoritative decisions (confirmed — do not re-litigate)

1. **GST rate is stored in basis points** (`gstRateBp: Int`; `1000`=10%, `1500`=15%, `1250`=12.5%) —
   integer, no float drift, supports custom rates. Default at profile creation from the **device
   region** (AU→1000, NZ→1500, else 1000); editable in settings.
2. **The GST rate is snapshotted onto each document** (`quote.gstRateBp`, `invoice.gstRateBp`) at
   save/create from the profile's current rate, so a sent document's GST never changes if the profile
   rate later changes. The settings rate is only the **default for new documents**.
3. **BAS stays ÷11 (Australian 10%)** — BAS is an AU construct; a 15% (NZ) profile simply doesn't use
   it. `BasEngine`/`basEngine.ts` are unchanged. (BAS-by-country gating is out of scope.)
4. **HTML-first quotes:** the shareable artifact is a **hosted HTML page** (a link); the **PDF is
   rendered on-device** (`WKWebView` → PDF) from that same HTML. This **replaces `pdfQuote.ts`**
   (the `pdf-lib` quote builder). The shipped **invoice** PDF stays `pdf-lib` for now.
5. **"Send quote" emails the link** (not a PDF attachment).
6. **Logo** is uploaded to **R2**; the server-rendered HTML **inlines it as a data-URI** (the worker
   fetches the R2 object and base64-embeds it) so there's no separate logo route/token and the
   on-device PDF embeds it too.
7. **Bank/payment details is a single freeform multiline field** (covers AU BSB+account, NZ account,
   PayID, international) — not structured per-country fields.
8. **#4:** removing the BAS card's top-right pill also removes its "Lodged" badge from that spot
   (lodged state is still shown inside the BAS screen).

## 3. Configurable GST rate (#1)

- **`Profile.gstRateBp: Int`** (default `1000`). Device-region default applied when a business profile
  is created (iOS reads `Locale.current.region`: `AU`→1000, `NZ`→1500, else 1000).
- **Settings control** (Tax & GST): segmented presets **10% (Australia)** / **15% (New Zealand)** /
  **Custom**; Custom reveals a percent entry stored as bp (e.g. `12.5` → `1250`).
- **`QuoteTotals.compute(... gstRateBp:)`** (Swift + `quoteTotals.ts`) — the rate becomes a parameter,
  replacing the hardcoded `0.10`. Formulas (all integer cents):
  - **Exclusive:** `gst = round(subtotal × bp / 10000)`; `total = subtotal + gst`.
  - **Inclusive:** `gross = Σ lines`; `gst = round(gross × bp / (10000 + bp))`; `subtotal = gross − gst`;
    `total = gross`. (At `bp=1000` these reduce to the current `/10` and `/11` behaviour.)
- `InvoiceTotals` already delegates to `QuoteTotals`, so invoices pick up the rate. **Capture GST**
  (`GstTreatment`'s derived ÷11) uses the active profile's `gstRateBp`:
  `gst = round(totalCents × bp / (10000 + bp))`.
- **Snapshot:** `quote.gstRateBp` / `invoice.gstRateBp` are set from the profile at create/save; the
  totals engine, the HTML quote, and the invoice PDF use the **document's** `gstRateBp` (so the GST
  line label reads the right "GST (X%)"). Documents created before this feature have a null
  `gstRateBp` → treated as `1000` (10%) everywhere (totals + the "GST (10%)" label).
- **BAS unchanged** (§2.3).

## 4. HTML quote + on-device PDF (#2)

- **`GET /q/:token`** (public — added to `PUBLIC_PATHS`): verifies a signed token (reuse the
  HMAC `exportToken`/`signDownloadToken` machinery) that carries the quote id + user id, fetches the
  quote + line items + owning profile from D1, and renders a **self-contained styled HTML page**
  (inline CSS, mobile-responsive + print-friendly). The page is rendered **on-the-fly** (no stored
  HTML) so it always reflects the live quote. **Token TTL is long** (90 days) — a quote link a client
  opens days later must still work.
- **HTML content:** header (logo [data-URI] · company name · ABN · business email · phone · website ·
  address) · "Quote #N" + issue date + valid-until · "Bill to" (client name/email) · line-items table
  (description · qty · unit · amount) · totals (subtotal · **GST (rate%)** · total) · **Payment
  details** block (when `bankDetails` set) · validity note · footer **"Made with Snapceipt" badge**
  linking to the app.
- **`POST /quotes/:id/link`** → `{ url }` — mints the signed token and returns
  `https://api.snapceipt.cc/q/<token>`. Used by both the editor's **Share** action and the on-device
  PDF step.
- **`POST /quotes/:id/send`** (existing) now **emails the client the link** (via `sendQuoteEmail`,
  reworked to send a link, not a PDF attachment) and returns `{ url, emailed }`. Validate-before-mutate
  + email-failure isolation unchanged.
- **iOS:** the quote editor's primary share hands over the `url` (system share sheet). **"Generate
  PDF"** loads the `url` in a hidden `WKWebView`, renders it to PDF (`WKWebView.createPDF`/
  `UIPrintPageRenderer`), and shares the file.
- **Removes `src/lib/pdfQuote.ts`** + the `POST /quotes/:id/pdf` route and the `/quotes/dl` PDF
  download (superseded by `/q/:token`). iOS drops `GenerateQuotePdfResponse` / `generateQuotePdf` in
  favour of `quoteShareLink` + the WKWebView renderer. (This breaks the quote-PDF feature on app
  builds ≤ #35 — acceptable on TestFlight, since testers move to the HTML build that ships with this.
  Invoice routes/`/invoices/dl` are untouched.)

## 5. Business profile details (#3)

- **`Profile`** gains: `businessEmail`, `phone`, `website`, `addressText`, `bankDetails` (all
  `String?`, freeform; `addressText` + `bankDetails` multiline), and `logoR2Key: String?`. (`abn`
  already exists.)
- **Tax & GST settings** gains a **"Business details"** section (business email, phone, website,
  address, logo) and a **"Bank details"** section (the freeform payment block), editing the active
  Profile via the settings VM.
- **Logo upload:** `POST /profile/logo` accepts image bytes, stores to R2 (`<userId>/profiles/<id>/logo`),
  sets `profiles.logo_r2_key`, returns ok. iOS picks an image (`PhotosPicker`), reduces it (reuse the
  capture `ImageReducing`), uploads, and previews it. The HTML quote inlines the R2 logo as a data-URI
  (§2.6).
- All fields render on the HTML quote header/payment block (each shown only when set).

## 6. Remove duplicate Review button (#4)

`Snapceipt/Features/Reports/ReportsView.swift` `basCard`: remove the top-right
`Text(basLodged ? "Lodged" : "Review")` pill (~line 110); keep the bottom `Text("Review ›")` CTA. The
whole card remains tappable to the BAS screen.

## 7. Data model + migration

Migration **`0010`** (additive `ALTER TABLE ADD COLUMN`):
- `profiles`: `gst_rate_bp INTEGER DEFAULT 1000`, `business_email TEXT`, `phone TEXT`, `website TEXT`,
  `address TEXT`, `bank_details TEXT`, `logo_r2_key TEXT`.
- `quotes`: `gst_rate_bp INTEGER`.
- `invoices`: `gst_rate_bp INTEGER`.

Threaded through: iOS `Profile`/`Quote`/`Invoice` models + their sync mappers (`SyncEntityRegistry`);
`src/schemas/entities.ts` (profile/quote/invoice schemas); `src/lib/syncTables.ts` (profile/quote/
invoice column maps). New wire keys: `gstRateBp`, `businessEmail`, `phone`, `website`, `address`,
`bankDetails`, `logoR2Key`. (`logoR2Key` is server-owned — pull-only on iOS, per the N1 lesson: decode
it, never encode it.)

## 8. Testing

- **`QuoteTotals` golden tests** at 10% / 15% / a custom rate, exclusive + inclusive (the `bp` math).
- **Capture GST** at 15% (`GstTreatment`).
- **HTML render** (`/q/:token`): content assertions — company fields, ABN, GST(rate%) line, payment
  block present/absent, badge; token verify (valid → 200 HTML; bad/expired → 403).
- **`/quotes/:id/link`** returns a working URL; **send** emails the link (spied) + returns the url.
- **Logo upload** route stores the key; logo inlines into the HTML.
- **Profile/Quote/Invoice sync round-trips** for the new fields (logoR2Key pull-only).
- iOS settings VM (rate presets/custom, business fields); WKWebView→PDF smoke; the #4 removal.
- Document snapshot: a quote saved at 15% keeps 15% after the profile switches to 10%.

## 9. Build phasing

- **Backend plan:** migration `0010`; profile/quote/invoice rate + business fields in schema/sync;
  `quoteTotals.ts` rate param; the HTML template + `GET /q/:token` + `POST /quotes/:id/link`; rework
  `sendQuoteEmail` + `/quotes/:id/send` to email the link; `POST /profile/logo`; remove `pdfQuote.ts`
  + `/quotes/:id/pdf` + `/quotes/dl`.
- **iOS plan:** Profile/Quote/Invoice model fields + mappers; device-region GST default; Tax & GST
  settings (rate control + Business/Bank sections + logo pick/upload); `QuoteTotals` rate param +
  capture GST; quote editor share-link + `WKWebView`→PDF (drop `generateQuotePdf`); the #4 removal.
- Backend lands first (the iOS share/link/PDF flows depend on the routes).

## 10. Out of scope / non-goals

- Invoice HTML page (invoices keep the `pdf-lib` PDF — a future migration mirroring this).
- BAS-by-country gating; multi-currency beyond AUD/NZD display.
- Structured (per-country) bank fields; online payment collection.
- Server-side HTML→PDF (Cloudflare Browser Rendering) — PDF is on-device only.
