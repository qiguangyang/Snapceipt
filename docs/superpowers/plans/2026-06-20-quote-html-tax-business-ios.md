# Configurable GST + Business Profile + HTML Quotes — iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the iOS slice of the configurable-GST + business-profile + HTML-quotes feature — a per-profile GST rate (basis points, device-region default) snapshotted onto quotes/invoices and threaded into the totals engine + capture GST; a Tax & GST settings screen gaining a GST-rate control, a Business-details section (email/phone/website/address/logo) and a Bank-details section; a quote-editor flow that shares a hosted HTML link and renders the on-device PDF from it via `WKWebView` (dropping the old `generateQuotePdf`); and removal of the duplicate "Review" pill on the Reports BAS card — all calling backend routes that are assumed to already exist.

**Architecture:** Mirror the existing patterns exactly. New optional `Profile` fields + `gstRateBp` on `Profile`/`Quote`/`Invoice` follow the established `@Model` + sync-mapper conventions (the encode/decode `payload`/`upsert` pair in `SyncEntityRegistry`); `logoR2Key` reuses the shipped pull-only pattern (`pdfR2Key`'s N1 fix: decode it, never encode it). `QuoteTotals.compute` gains a `gstRateBp:` parameter replacing the hardcoded `0.10`; `InvoiceTotals` (which delegates) and the capture-GST `GstTreatment.derivedGstCents` thread the same rate. Documents snapshot `gstRateBp` from the active profile at save. The settings screen extends `TaxSettingsView`/`TaxSettingsViewModel` (already profile-backed). The quote editor's Share + Generate-PDF replace the PDF route with `quoteShareLink` + a hidden `WKWebView.createPDF`. The API client gains `quoteShareLink`/`uploadProfileLogo`, changes `sendQuote`'s response shape, and drops `generateQuotePdf` — across all four conformers (Live/Stub/Preview/Mock).

**Tech Stack:** Swift 5.10 / SwiftUI, SwiftData, WebKit (`WKWebView`), PhotosUI (`PhotosPicker`), Swift Testing (`import Testing`, `@Test`, `#expect`), XCUITest, Xcode 16 (`xcodebuild`), XcodeGen (`project.yml` → `Snapceipt.xcodeproj`).

## Global Constraints

- **Backend routes are assumed to EXIST** (separate backend plan lands first). This plan's tasks only CALL them: `POST /quotes/:id/link` → `{ url: string, number: string }` (mints number if absent); `POST /quotes/:id/send` → `{ url: string, emailed: boolean, number: string }` (changed response — status/totals persisted server-side only); `POST /profile/logo` (raw image bytes) → ok. The old `POST /quotes/:id/pdf` and `/quotes/dl` are REMOVED on the backend — iOS must drop `generateQuotePdf` / `GenerateQuotePdfResponse` (spec §4).
- **Cross-plan wire-key contract (spec §7) — use these EXACT camelCase keys in the sync mappers + API client:** `gstRateBp`, `businessEmail`, `phone`, `website`, `address` (the `Profile.addressText` property maps to wire key `address`), `bankDetails`, `logoR2Key`. The backend maps them to snake_case columns.
- **GST stored in basis points (spec §2.1):** `1000` = 10%, `1500` = 15%, `1250` = 12.5%. Integer, no float drift. `Profile.gstRateBp: Int` default `1000`. Device-region default at business-profile creation: `Locale.current.region` `AU`→1000, `NZ`→1500, else 1000 (spec §3).
- **GST snapshot (spec §2.2 / §3):** `Quote.gstRateBp: Int?` and `Invoice.gstRateBp: Int?` are set from the active profile at save/convert. A null document rate ⇒ treat as `1000` (10%) everywhere — totals AND the "GST (10%)" label. The profile rate is only the default for NEW documents; a sent document's GST never changes if the profile rate later changes.
- **GST formulas (spec §3, all integer cents):**
  - Exclusive (`gstInclusive == false`): `gst = round(subtotal × bp / 10000)`, `total = subtotal + gst`.
  - Inclusive (`gstInclusive == true`): `gross = Σ lines`, `gst = round(gross × bp / (10000 + bp))`, `subtotal = gross − gst`, `total = gross`.
  - Capture GST (`GstTreatment` derived): `gst = round(totalCents × bp / (10000 + bp))`. At `bp = 1000` these all reduce to the current `/10` and `/11` behaviour (golden tests assert this).
- **`logoR2Key` is SERVER-OWNED → pull-only (spec §7):** decode it in the `Profile` mapper `upsert`, NEVER encode it in `payload`. Same lesson as the shipped `pdfR2Key` N1 fix. The editable business fields (`businessEmail`/`phone`/`website`/`address`/`bankDetails`) and `gstRateBp` are encode + decode (full round-trip).
- **BAS stays ÷11 (spec §2.3):** `BasEngine`/`basEngine.ts` are UNCHANGED. BAS is an AU 10% construct; a 15% profile simply doesn't use it. Do NOT thread `gstRateBp` into BAS reconciliation math.
- **Dormant column (resolved ambiguity — see "Resolved Ambiguities" at end):** `TaxSettings.gstRateBps` (note the `s`) already exists and syncs but is read NOWHERE. This plan does NOT consolidate onto it; it follows the spec's `Profile.gstRateBp` (no `s`) + wire key `gstRateBp` exactly, to keep the cross-plan §7 contract intact. Leave `TaxSettings.gstRateBps` untouched.
- **Bank details = single freeform multiline field** (spec §7 of the prior memory / §5): `Profile.bankDetails: String?`, multiline; `Profile.addressText: String?` also multiline. No structured per-country fields.
- **WKWebView → PDF runs on-device** (spec §4): the quote editor's "Generate PDF" loads the share `url` in a hidden off-screen `WKWebView`, waits for load, calls `createPDF`, writes a temp file, and shares the FILE via `UIActivityViewController`. The "Share link" action shares the `url` string directly. No server-side HTML→PDF.
- **Scope by profileId.** Unchanged. `Profile.profileId` stays nil (a profile is not profile-scoped). Quote/Invoice keep their `profileId`.
- **Entity raw values (camelCase, verbatim):** `profile`, `quote`, `invoice` — unchanged; only new fields are added to their existing mappers.
- **XcodeGen / build:** `.xcodeproj` is gitignored and generated from `project.yml` (sources auto-globbed under `path: Snapceipt` and `path: SnapceiptTests`). **Any task that ADDS a new `.swift` file MUST run `/opt/homebrew/bin/xcodegen generate` BEFORE `xcodebuild`** — otherwise the file is silently excluded and tests can falsely report 0/pass. Tasks that only modify existing files do NOT need `xcodegen generate`.
- **Test command (run the WHOLE suite — single-method selectors are flaky):**
  `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/<Suite> 2>&1 | tail -20`
  Swift Testing suites print "Executed 0 tests" in the legacy XCTest summary — trust the `** TEST SUCCEEDED **` line and the `Test run with N tests … passed` line. `xcodebuild` takes minutes.
- **Commit messages end with:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

**New source files (each requires `xcodegen generate` before building):**
- `Snapceipt/Features/Quotes/QuotePdfRenderer.swift` — a `@MainActor` helper that loads a URL in a hidden `WKWebView` and returns a PDF file URL (`WKWebView.createPDF`).

**Modified source files:**
- `Snapceipt/Model/Entities/Profile.swift` — add `gstRateBp: Int` (default 1000) + `businessEmail`/`phone`/`website`/`addressText`/`bankDetails`/`logoR2Key` (all `String?`).
- `Snapceipt/Model/Entities/Quote.swift` — add `gstRateBp: Int?`.
- `Snapceipt/Model/Entities/Invoice.swift` — add `gstRateBp: Int?`.
- `Snapceipt/Sync/SyncEntityRegistry.swift` — extend `ProfileSyncMapper` (new fields; `logoR2Key` pull-only), `QuoteSyncMapper` + `InvoiceSyncMapper` (`gstRateBp`).
- `Snapceipt/Features/Quotes/QuoteTotals.swift` — add `gstRateBp:` param to both `compute` overloads (replace `0.10`).
- `Snapceipt/Features/Invoices/InvoiceTotals.swift` — thread `gstRateBp:` through to `QuoteTotals.compute`.
- `Snapceipt/Features/Reports/Bas/GstTreatment.swift` — add `bp:` to `derivedGstCents` + `applyGstFree`.
- `Snapceipt/Features/Capture/CaptureViewModel.swift` — add `gstRateBp` to `ProfileOption` (from the profile's `gstRateBp`).
- `Snapceipt/Features/Capture/Views/ReviewStep.swift` — pass the selected profile's `gstRateBp` into `applyGstFree`.
- `Snapceipt/Features/Profiles/AddProfileViewModel.swift` — device-region GST default on business-profile `Profile(...)` creation.
- `Snapceipt/Features/Settings/TaxSettingsViewModel.swift` — GST-rate state/setter + business-field/bank-field state/setters + logo upload via `api`.
- `Snapceipt/Features/Settings/TaxSettingsView.swift` — GST-rate control, Business-details section (incl. `PhotosPicker` logo), Bank-details section.
- `Snapceipt/App/RootView.swift` — pass `api: captureAPI` into the `TaxSettingsView(` construction (line 371).
- `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift` — `shareLink(api:)` returning the url; replace `generatePdf` with `generatePdf(api:renderer:)` that mints the link then renders on-device; `send` reads new `{url, emailed}` response; snapshot `gstRateBp` into the quote in `saveDraft`; totals read the document/profile rate.
- `Snapceipt/Features/Quotes/QuoteEditorView.swift` — Share-link button + Generate-PDF (WKWebView) wiring; pass the active profile's `gstRateBp`; drop dead pdfUrl-from-route assumptions.
- `Snapceipt/Features/Reports/ReportsView.swift` — remove the top-right `Text(basLodged ? "Lodged" : "Review")` pill in `basCard`.
- `Snapceipt/Sync/APIClient.swift` — protocol: add `quoteShareLink` + `uploadProfileLogo`, change `sendQuote` return shape, remove `generateQuotePdf`; `LiveAPIClient` impls.
- `Snapceipt/Sync/StubAPIClient.swift` — stub impls for the changed protocol.
- `Snapceipt/Sync/DTOs.swift` — add `QuoteShareLinkResponse` (with `number`), `UploadProfileLogoResponse`; trim `SendQuoteResponse` to `{ url, emailed, number }` (drop `status`, `sentAt`, `subtotalCents`, `gstCents`, `totalCents`, `pdfUrl`/`expiresAt`); remove `GenerateQuotePdfResponse`.
- `Snapceipt/Features/Auth/SignInView.swift` — `PreviewAPIClient` (DEBUG) impls for the changed protocol.
- `Snapceipt/Shared/AccessibilityID.swift` — new ids for the GST control, business fields, logo picker, bank field, share-link + generate-PDF buttons.
- `SnapceiptTests/Mocks/MockAPIClient.swift` — add `quoteShareLink`/`uploadProfileLogo` handlers+call arrays; change `sendQuote`; remove `generateQuotePdf`.

**Test files:**
- `SnapceiptTests/ProfileBusinessFieldsTests.swift` — Profile new-field defaults + sync round-trip (logoR2Key pull-only).
- `SnapceiptTests/QuoteTotalsRateTests.swift` — golden GST math at 10/15/custom, exclusive + inclusive, null⇒1000.
- `SnapceiptTests/GstTreatmentRateTests.swift` — capture GST at 15% + null default + existing /11 still green.
- `SnapceiptTests/DocumentRateSnapshotTests.swift` — quote saved at 15% keeps 15% after profile flips to 10%.
- `SnapceiptTests/AddProfileGstDefaultTests.swift` — device-region default mapping (pure helper).
- `SnapceiptTests/TaxSettingsBusinessFieldsTests.swift` — settings VM rate presets/custom + business/bank field setters persist + enqueue + logo upload.
- `SnapceiptTests/QuoteEditorShareLinkTests.swift` — VM `shareLink` returns url; `send` reads `{url, emailed}`; `generatePdf` calls renderer with the minted url.
- `SnapceiptTests/AccessibilityIDQuoteHtmlTests.swift` — the new id constants exist + are stable.

---

### Task 1: Model fields — `Profile` / `Quote` / `Invoice`

Adds the new persisted columns. `Profile` gains `gstRateBp: Int` (default 1000) plus the six business `String?` fields; `Quote` and `Invoice` each gain `gstRateBp: Int?`. No mappers yet (Task 2). This unblocks everything else. These are additive properties on existing `@Model`s registered in `SnapceiptSchema` — no schema-registration change is needed (the classes are already registered), and no new files are created (so no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Model/Entities/Profile.swift`
- Modify: `Snapceipt/Model/Entities/Quote.swift`
- Modify: `Snapceipt/Model/Entities/Invoice.swift`
- Test: `SnapceiptTests/ProfileBusinessFieldsTests.swift`

**Interfaces:**
- Produces:
  - `Profile` gains stored `var gstRateBp: Int`, `var businessEmail: String?`, `var phone: String?`, `var website: String?`, `var addressText: String?`, `var bankDetails: String?`, `var logoR2Key: String?`; init gains params `gstRateBp: Int = 1000, businessEmail: String? = nil, phone: String? = nil, website: String? = nil, addressText: String? = nil, bankDetails: String? = nil, logoR2Key: String? = nil` (inserted before `createdAt`).
  - `Quote` gains stored `var gstRateBp: Int?`; init gains `gstRateBp: Int? = nil` (inserted before `createdAt`).
  - `Invoice` gains stored `var gstRateBp: Int?`; init gains `gstRateBp: Int? = nil` (inserted before `createdAt`).

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/ProfileBusinessFieldsTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Profile business fields + document rate")
struct ProfileBusinessFieldsTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    @Test("Profile defaults: gstRateBp 1000, business fields nil")
    func profileDefaults() throws {
        let c = try ctx()
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
        c.insert(p)
        try c.save()
        let stored = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(stored.gstRateBp == 1000)
        #expect(stored.businessEmail == nil)
        #expect(stored.phone == nil)
        #expect(stored.website == nil)
        #expect(stored.addressText == nil)
        #expect(stored.bankDetails == nil)
        #expect(stored.logoR2Key == nil)
    }

    @Test("Profile persists business fields + custom rate")
    func profilePersists() throws {
        let c = try ctx()
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500, businessEmail: "hi@biz.au", phone: "0400 000 000",
                        website: "biz.au", addressText: "1 Test St\nSydney NSW",
                        bankDetails: "BSB 000-000\nAcct 12345678", logoR2Key: "u1/profiles/p1/logo")
        c.insert(p)
        try c.save()
        let s = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(s.gstRateBp == 1500)
        #expect(s.businessEmail == "hi@biz.au")
        #expect(s.phone == "0400 000 000")
        #expect(s.website == "biz.au")
        #expect(s.addressText == "1 Test St\nSydney NSW")
        #expect(s.bankDetails == "BSB 000-000\nAcct 12345678")
        #expect(s.logoR2Key == "u1/profiles/p1/logo")
    }

    @Test("Quote + Invoice gstRateBp default nil and persist a value")
    func documentRate() throws {
        let c = try ctx()
        let q = Quote(userId: "u1", profileId: "p1")
        let i = Invoice(userId: "u1", profileId: "p1")
        c.insert(q); c.insert(i)
        try c.save()
        let sq = try c.fetch(FetchDescriptor<Quote>())[0]
        let si = try c.fetch(FetchDescriptor<Invoice>())[0]
        #expect(sq.gstRateBp == nil)
        #expect(si.gstRateBp == nil)
        sq.gstRateBp = 1500
        si.gstRateBp = 1250
        try c.save()
        #expect(try c.fetch(FetchDescriptor<Quote>())[0].gstRateBp == 1500)
        #expect(try c.fetch(FetchDescriptor<Invoice>())[0].gstRateBp == 1250)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ProfileBusinessFieldsTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `value of type 'Profile' has no member 'gstRateBp'` (and the other new members).

- [ ] **Step 3: Add the fields to `Profile`**

In `Snapceipt/Model/Entities/Profile.swift`, add the stored properties after `var abn: String?` (line 18):

```swift
    var abn: String?
    var gstRegistered: Bool
    /// GST rate in basis points (1000 = 10%, 1500 = 15%). Device-region default at
    /// business-profile creation; the default rate for NEW documents (snapshotted onto
    /// each quote/invoice). Mirrors D1 `profiles.gst_rate_bp`. (spec §3)
    var gstRateBp: Int
    /// Business contact + payment details rendered on the HTML quote (each shown only
    /// when set). All freeform/optional; `addressText` + `bankDetails` are multiline. (spec §5)
    var businessEmail: String?
    var phone: String?
    var website: String?
    var addressText: String?
    var bankDetails: String?
    /// R2 key of the uploaded logo. SERVER-OWNED — pull-only on iOS (decode, never
    /// encode), set by POST /profile/logo. (spec §7, mirrors pdfR2Key's N1 fix)
    var logoR2Key: String?
```

Add the init params after `gstRegistered: Bool = false,` (line 41):

```swift
        gstRegistered: Bool = false,
        gstRateBp: Int = 1000,
        businessEmail: String? = nil,
        phone: String? = nil,
        website: String? = nil,
        addressText: String? = nil,
        bankDetails: String? = nil,
        logoR2Key: String? = nil,
```

Add the assignments after `self.gstRegistered = gstRegistered` (line 60):

```swift
        self.gstRegistered = gstRegistered
        self.gstRateBp = gstRateBp
        self.businessEmail = businessEmail
        self.phone = phone
        self.website = website
        self.addressText = addressText
        self.bankDetails = bankDetails
        self.logoR2Key = logoR2Key
```

- [ ] **Step 4: Add the field to `Quote`**

In `Snapceipt/Model/Entities/Quote.swift`, add after `var invoiceId: String?` (line 29):

```swift
    var invoiceId: String?
    /// GST rate snapshot in basis points, set from the profile at save. null ⇒ 10%
    /// (1000) for legacy quotes. Totals + the "GST (X%)" label read THIS value. (spec §3)
    var gstRateBp: Int?
```

Add the init param after `invoiceId: String? = nil,` (line 56):

```swift
        invoiceId: String? = nil,
        gstRateBp: Int? = nil,
```

Add the assignment after `self.invoiceId = invoiceId` (line 79):

```swift
        self.invoiceId = invoiceId
        self.gstRateBp = gstRateBp
```

- [ ] **Step 5: Add the field to `Invoice`**

In `Snapceipt/Model/Entities/Invoice.swift`, add after `var pdfR2Key: String?` (line 27):

```swift
    var pdfR2Key: String?            // persisted R2 key of the last-built PDF
    /// GST rate snapshot in basis points, set from the profile at convert/save. null ⇒
    /// 10% (1000) for legacy invoices. Totals + PDF GST label read THIS value. (spec §3)
    var gstRateBp: Int?
```

Add the init param after `pdfR2Key: String? = nil,` (line 55):

```swift
        pdfR2Key: String? = nil,
        gstRateBp: Int? = nil,
```

Add the assignment after `self.pdfR2Key = pdfR2Key` (line 79):

```swift
        self.pdfR2Key = pdfR2Key
        self.gstRateBp = gstRateBp
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/ProfileBusinessFieldsTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 3 tests … passed`.

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Model/Entities/Profile.swift Snapceipt/Model/Entities/Quote.swift Snapceipt/Model/Entities/Invoice.swift SnapceiptTests/ProfileBusinessFieldsTests.swift
git commit -m "feat(model): Profile gstRateBp + business fields; Quote/Invoice gstRateBp snapshot

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Sync mappers — encode/decode the new fields

Threads the new fields through `ProfileSyncMapper`, `QuoteSyncMapper`, `InvoiceSyncMapper` in `SyncEntityRegistry.swift`. The editable fields (`gstRateBp` + the five business strings) are encode + decode; `logoR2Key` is **pull-only** (decode in `upsert`, OMIT from `payload`) per the shipped `pdfR2Key` N1 fix. Uses the exact §7 wire keys: `gstRateBp`, `businessEmail`, `phone`, `website`, `address` (↔ `addressText`), `bankDetails`, `logoR2Key`. Modifies one existing file (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Sync/SyncEntityRegistry.swift` (`ProfileSyncMapper` ~lines 252–292; `QuoteSyncMapper` ~lines 511–556; `InvoiceSyncMapper` ~lines 845–892)
- Test: `SnapceiptTests/ProfileBusinessFieldsTests.swift` (add a sync round-trip suite)

**Interfaces:**
- Consumes: the `SyncRowMapper` protocol (`upsert`, `payload`), the `sharedFields`/`str`/`num`/`boolv` helpers, and `PullChange` accessors `env.string`/`env.int`/`env.bool` — all already in `SyncEntityRegistry.swift`.
- Produces: wire payloads carrying `gstRateBp`, `businessEmail`, `phone`, `website`, `address`, `bankDetails` for Profile (and `logoR2Key` decode-only); `gstRateBp` for Quote + Invoice.

- [ ] **Step 1: Write the failing test**

Add to `SnapceiptTests/ProfileBusinessFieldsTests.swift` a new suite that round-trips through the registry's encode (`encodePayload`) and decode (`applyPulled`). Match the existing sync-test idiom in `SnapceiptTests` (see `InvoiceSyncTests.swift` for the `SyncEntityRegistry.shared.handler(for:)` / `PullChange` shape):

```swift
@MainActor
@Suite("Profile/Quote/Invoice new-field sync round-trip")
struct NewFieldSyncTests {
    private func ctx() throws -> ModelContext {
        ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
    }

    @Test("Profile payload carries editable fields, OMITS logoR2Key")
    func profileEncode() throws {
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500, businessEmail: "hi@biz.au", phone: "0400",
                        website: "biz.au", addressText: "1 St", bankDetails: "BSB 1",
                        logoR2Key: "u1/profiles/p1/logo")
        let h = SyncEntityRegistry.shared.handler(for: .profile)!
        let payload = h.encodePayload(p)
        #expect(payload["gstRateBp"] == .number(1500))
        #expect(payload["businessEmail"] == .string("hi@biz.au"))
        #expect(payload["phone"] == .string("0400"))
        #expect(payload["website"] == .string("biz.au"))
        #expect(payload["address"] == .string("1 St"))
        #expect(payload["bankDetails"] == .string("BSB 1"))
        // logoR2Key is pull-only: NEVER in the outbound payload.
        #expect(payload["logoR2Key"] == nil)
    }

    @Test("Profile upsert decodes editable fields AND logoR2Key")
    func profileDecode() throws {
        let c = try ctx()
        let env = PullChange.test(
            type: "profile", id: "p1", userId: "u1",
            fields: ["name": .string("Biz"), "profileType": .string("business"),
                     "accent1": .string("#0E7C72"), "accent2": .string("#DCF0ED"),
                     "accent3": .string("#0A5950"),
                     "gstRateBp": .number(1500), "businessEmail": .string("hi@biz.au"),
                     "phone": .string("0400"), "website": .string("biz.au"),
                     "address": .string("1 St"), "bankDetails": .string("BSB 1"),
                     "logoR2Key": .string("u1/profiles/p1/logo")])
        SyncEntityRegistry.shared.handler(for: .profile)!.applyPulled(c, env)
        try c.save()
        let s = try c.fetch(FetchDescriptor<Profile>())[0]
        #expect(s.gstRateBp == 1500)
        #expect(s.businessEmail == "hi@biz.au")
        #expect(s.phone == "0400")
        #expect(s.website == "biz.au")
        #expect(s.addressText == "1 St")
        #expect(s.bankDetails == "BSB 1")
        #expect(s.logoR2Key == "u1/profiles/p1/logo")
    }

    @Test("Quote + Invoice round-trip gstRateBp")
    func documentRateRoundTrip() throws {
        let q = Quote(userId: "u1", profileId: "p1", gstRateBp: 1500)
        let i = Invoice(userId: "u1", profileId: "p1", gstRateBp: 1250)
        let qh = SyncEntityRegistry.shared.handler(for: .quote)!
        let ih = SyncEntityRegistry.shared.handler(for: .invoice)!
        #expect(qh.encodePayload(q)["gstRateBp"] == .number(1500))
        #expect(ih.encodePayload(i)["gstRateBp"] == .number(1250))
    }
}
```

> Note for the implementer: `PullChange.test(...)` and `handler(for:)` are the existing test helpers used by `InvoiceSyncTests.swift` / `QuoteSyncTests.swift`. Read one of those files first and copy its exact constructor/accessor names; the suite above assumes the same surface. If the project uses a different test-construction helper, mirror that file's pattern verbatim instead of inventing one.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/NewFieldSyncTests 2>&1 | tail -20`
Expected: FAIL — `payload["gstRateBp"]` is `nil` (not yet encoded), decode leaves fields nil.

- [ ] **Step 3: Extend `ProfileSyncMapper.upsert` (decode)**

In `SyncEntityRegistry.swift`, in `ProfileSyncMapper.upsert`, after `if let v = env.bool("isDefault") { row.isDefault = v }`:

```swift
        if let v = env.bool("isDefault") { row.isDefault = v }
        if let v = env.int("gstRateBp") { row.gstRateBp = v }
        if let v = env.string("businessEmail") { row.businessEmail = v }
        if let v = env.string("phone") { row.phone = v }
        if let v = env.string("website") { row.website = v }
        if let v = env.string("address") { row.addressText = v }
        if let v = env.string("bankDetails") { row.bankDetails = v }
        if let v = env.string("logoR2Key") { row.logoR2Key = v }
```

- [ ] **Step 4: Extend `ProfileSyncMapper.payload` (encode) — OMIT `logoR2Key`**

In `ProfileSyncMapper.payload`, after `f["isDefault"] = boolv(r.isDefault)`:

```swift
        f["isDefault"] = boolv(r.isDefault)
        f["gstRateBp"] = num(r.gstRateBp)
        f["businessEmail"] = str(r.businessEmail)
        f["phone"] = str(r.phone)
        f["website"] = str(r.website)
        f["address"] = str(r.addressText)   // wire key `address` ↔ model `addressText`
        f["bankDetails"] = str(r.bankDetails)
        // logoR2Key is server-owned (set on POST /profile/logo): pull-only — decode it,
        // never encode it, so a follow-up push can't clobber the server value to NULL.
```

- [ ] **Step 5: Extend `QuoteSyncMapper`**

In `QuoteSyncMapper.upsert`, after `if let v = env.string("invoiceId") { row.invoiceId = v }`:

```swift
        if let v = env.string("invoiceId") { row.invoiceId = v }
        if let v = env.int("gstRateBp") { row.gstRateBp = v }
```

In `QuoteSyncMapper.payload`, after `f["invoiceId"] = str(r.invoiceId)`:

```swift
        f["invoiceId"] = str(r.invoiceId)
        f["gstRateBp"] = num(r.gstRateBp)
```

> `num(Int?)` already exists (the `num` helper has an `Int?` overload that emits `.null` when nil) — confirm in `SyncEntityRegistry.swift` lines ~109-112; the `Quote.gstRateBp` / `Invoice.gstRateBp` are optional `Int?`, so call `num(r.gstRateBp)`.

- [ ] **Step 6: Extend `InvoiceSyncMapper`**

In `InvoiceSyncMapper.upsert`, after `if let v = env.string("pdfR2Key") { row.pdfR2Key = v }`:

```swift
        if let v = env.string("pdfR2Key") { row.pdfR2Key = v }
        if let v = env.int("gstRateBp") { row.gstRateBp = v }
```

In `InvoiceSyncMapper.payload`, after the `issuedAt` line and the existing `pdfR2Key` pull-only comment, add `gstRateBp`:

```swift
        f["issuedAt"] = num(r.issuedAt)
        f["gstRateBp"] = num(r.gstRateBp)
        // pdfR2Key is server-owned (set on POST /invoices/:id/issue and /invoices/:id/pdf):
        // pull-only — decode it, never encode it, so a follow-up push can't clobber it to NULL.
```

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/NewFieldSyncTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 3 tests … passed`.

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Sync/SyncEntityRegistry.swift SnapceiptTests/ProfileBusinessFieldsTests.swift
git commit -m "feat(sync): map Profile business fields + gstRateBp; logoR2Key pull-only; Quote/Invoice gstRateBp

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `QuoteTotals` + `InvoiceTotals` — `gstRateBp` parameter

Replaces the hardcoded `0.10` in `QuoteTotals.compute` with a `gstRateBp:` parameter using the integer-cents formulas (spec §3); a null rate ⇒ `1000`. `InvoiceTotals.compute` forwards the rate. Modifies existing files (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Features/Quotes/QuoteTotals.swift`
- Modify: `Snapceipt/Features/Invoices/InvoiceTotals.swift`
- Test: `SnapceiptTests/QuoteTotalsRateTests.swift`

**Interfaces:**
- Produces:
  - `QuoteTotals.compute(lineItems: [QuoteTotals.Line], gstEnabled: Bool, gstInclusive: Bool = false, gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int)`
  - `QuoteTotals.compute(lineItems: [QuoteLineItem], gstEnabled: Bool, gstInclusive: Bool = false, gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int)`
  - `InvoiceTotals.compute(lineItems: [InvoiceLineItem], gstEnabled: Bool, gstInclusive: Bool = false, gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int)`

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/QuoteTotalsRateTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("QuoteTotals configurable GST rate")
struct QuoteTotalsRateTests {
    private func lines(_ pairs: [(Int, Int)]) -> [QuoteTotals.Line] {
        pairs.map { QuoteTotals.Line(quantity: $0.0, unitPriceCents: $0.1) }
    }

    @Test("Exclusive 10% (default + explicit) — 400.00 → gst 40.00, total 440.00")
    func excTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true)
        #expect(t == (40_000, 4_000, 44_000))
        let t2 = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true, gstRateBp: 1000)
        #expect(t2 == (40_000, 4_000, 44_000))
    }

    @Test("Exclusive 15% — 200.00 → gst 30.00, total 230.00")
    func excFifteen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 20_000)]), gstEnabled: true, gstRateBp: 1500)
        #expect(t == (20_000, 3_000, 23_000))
    }

    @Test("Exclusive custom 12.5% — 200.00 → gst 25.00, total 225.00")
    func excCustom() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 20_000)]), gstEnabled: true, gstRateBp: 1250)
        #expect(t == (20_000, 2_500, 22_500))
    }

    @Test("Inclusive 10% — gross 110.00 → gst 10.00, subtotal 100.00")
    func incTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 11_000)]), gstEnabled: true,
                                    gstInclusive: true, gstRateBp: 1000)
        #expect(t == (10_000, 1_000, 11_000))
    }

    @Test("Inclusive 15% — gross 115.00 → gst 15.00, subtotal 100.00")
    func incFifteen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 11_500)]), gstEnabled: true,
                                    gstInclusive: true, gstRateBp: 1500)
        #expect(t == (10_000, 1_500, 11_500))
    }

    @Test("null rate ⇒ 10%")
    func nullDefaultsTen() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: true, gstRateBp: nil)
        #expect(t == (40_000, 4_000, 44_000))
    }

    @Test("gst disabled ignores rate")
    func disabled() {
        let t = QuoteTotals.compute(lineItems: lines([(1, 40_000)]), gstEnabled: false, gstRateBp: 1500)
        #expect(t == (40_000, 0, 40_000))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/QuoteTotalsRateTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `compute` has no `gstRateBp` argument.

- [ ] **Step 3: Implement the rate in `QuoteTotals`**

Replace the body of `Snapceipt/Features/Quotes/QuoteTotals.swift` (keeping the file's doc comment header, updating it to describe the rate param) with:

```swift
import Foundation

/// Pure quote-totals math, shared by the live editor UI and asserted to match the
/// backend send route. GST is quote-level, rate-configurable (basis points), rounded
/// to the nearest cent (half-up). null ⇒ 1000 (10% AU). Two GST modes when enabled:
///   • exclusive (`gstInclusive == false`): entered prices are ex-GST; GST is added on
///     top. subtotal = Σ(line), gst = round(subtotal × bp / 10000), total = subtotal+gst.
///   • inclusive (`gstInclusive == true`): entered prices already contain GST; the grand
///     total stays the entered sum and GST is the embedded portion.
///     gross = Σ(line), gst = round(gross × bp / (10000 + bp)), subtotal = gross − gst.
/// In every mode the invariant `subtotal + gst == total` holds. Mirrors
/// `src/lib/quoteTotals.ts` exactly. (spec §3)
enum QuoteTotals {
    /// Default GST rate in basis points (10% AU) used when a document/profile rate is nil.
    static let defaultRateBp = 1000

    /// A minimal line input (decoupled from the `QuoteLineItem` @Model so the helper
    /// stays pure + trivially testable).
    struct Line {
        let quantity: Int
        let unitPriceCents: Int
    }

    /// Compute (subtotal, gst, total) in integer cents. `gstInclusive` only applies when
    /// `gstEnabled` is true. `gstRateBp` nil ⇒ `defaultRateBp` (10%).
    static func compute(lineItems: [Line], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        let gross = lineItems.reduce(0) { $0 + $1.quantity * $1.unitPriceCents }
        guard gstEnabled else { return (gross, 0, gross) }
        let bp = gstRateBp ?? defaultRateBp
        if gstInclusive {
            // GST embedded in `gross`: round(gross × bp / (10000 + bp)).
            let gst = Int((Double(gross) * Double(bp) / Double(10_000 + bp)).rounded())
            return (gross - gst, gst, gross)
        }
        // GST added on top: round(subtotal × bp / 10000).
        let gst = Int((Double(gross) * Double(bp) / 10_000.0).rounded())
        return (gross, gst, gross + gst)
    }

    /// Convenience overload for the editor: maps `QuoteLineItem`s to `Line`s.
    static func compute(lineItems: [QuoteLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        compute(lineItems: lineItems.map { Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
                gstEnabled: gstEnabled, gstInclusive: gstInclusive, gstRateBp: gstRateBp)
    }
}
```

- [ ] **Step 4: Forward the rate from `InvoiceTotals`**

Replace `Snapceipt/Features/Invoices/InvoiceTotals.swift` with:

```swift
import Foundation

/// Invoice totals reuse the quote GST engine verbatim (spec §3): the invoice carries the
/// same GST-enabled / GST-inclusive semantics AND the same snapshotted `gstRateBp` as the
/// quote it came from.
enum InvoiceTotals {
    /// Compute (subtotal, gst, total) in integer cents from invoice line items.
    /// `gstRateBp` nil ⇒ 10% (QuoteTotals.defaultRateBp).
    static func compute(lineItems: [InvoiceLineItem], gstEnabled: Bool,
                        gstInclusive: Bool = false,
                        gstRateBp: Int? = nil) -> (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(
            lineItems: lineItems.map { QuoteTotals.Line(quantity: $0.quantity, unitPriceCents: $0.unitPriceCents) },
            gstEnabled: gstEnabled, gstInclusive: gstInclusive, gstRateBp: gstRateBp)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/QuoteTotalsRateTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 7 tests … passed`.

- [ ] **Step 6: Guard existing callers compile**

The existing `QuoteEditorViewModel.totals`, `InvoiceEditorViewModel`, and `convertToInvoice` call `compute(...)` without `gstRateBp` — the new param defaults to nil so they still compile and behave as today. Run the broader quotes/invoices suites to confirm no regression:

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/QuoteTotalsTests -only-testing:SnapceiptTests/QuoteEditorViewModelTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (existing 10% golden tests stay green — the default-arg path is unchanged).

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Features/Quotes/QuoteTotals.swift Snapceipt/Features/Invoices/InvoiceTotals.swift SnapceiptTests/QuoteTotalsRateTests.swift
git commit -m "feat(totals): configurable gstRateBp in QuoteTotals/InvoiceTotals (replaces hardcoded 0.10)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Capture GST — `GstTreatment` rate parameter

Generalizes the hardcoded `÷11` in `GstTreatment.derivedGstCents` to `round(totalCents × bp / (10000 + bp))` with a `bp:` parameter (default 1000 keeps existing tests green), threaded through `applyGstFree`. Modifies existing files (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Features/Reports/Bas/GstTreatment.swift`
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift` (add `gstRateBp` to `ProfileOption`)
- Modify: `Snapceipt/Features/Capture/Views/ReviewStep.swift` (pass the selected profile's rate)
- Test: `SnapceiptTests/GstTreatmentRateTests.swift`

**Interfaces:**
- Produces:
  - `GstTreatment.derivedGstCents(totalCents: Int, bp: Int = 1000) -> Int`
  - `GstTreatment.applyGstFree(_ gstFree: Bool, totalCents: Int, bp: Int = 1000) -> GstTreatment.Result`
  - `ProfileOption(id: String, name: String, type: String, gstRateBp: Int)` and `CaptureViewModel.profileOptions` populated from each profile's `gstRateBp`.
- Consumes: `vm.profileOptions` in `ReviewStep` (now carrying `gstRateBp`).

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/GstTreatmentRateTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("GstTreatment configurable rate")
struct GstTreatmentRateTests {
    @Test("default bp 1000 == legacy ÷11 (110.00 → 10.00)")
    func defaultEleven() {
        #expect(GstTreatment.derivedGstCents(totalCents: 11_000) == 1_000)
        #expect(GstTreatment.derivedGstCents(totalCents: 11_000, bp: 1000) == 1_000)
    }

    @Test("15% — 115.00 → 15.00")
    func fifteen() {
        #expect(GstTreatment.derivedGstCents(totalCents: 11_500, bp: 1500) == 1_500)
    }

    @Test("applyGstFree(false, bp:1500) derives at 15%")
    func applyFifteen() {
        let r = GstTreatment.applyGstFree(false, totalCents: 11_500, bp: 1500)
        #expect(r.gstCents == 1_500)
        #expect(r.gstSource == "derived")
    }

    @Test("applyGstFree(true) zeroes regardless of bp")
    func freeZeroes() {
        let r = GstTreatment.applyGstFree(true, totalCents: 11_500, bp: 1500)
        #expect(r.gstCents == 0)
        #expect(r.gstSource == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/GstTreatmentRateTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `derivedGstCents` has no `bp` argument.

- [ ] **Step 3: Add `bp` to `GstTreatment`**

In `Snapceipt/Features/Reports/Bas/GstTreatment.swift`, replace `derivedGstCents` and `applyGstFree`:

```swift
    /// round(totalCents × bp / (10000 + bp)), half-up. `totalCents` is the magnitude
    /// (>= 0). `bp` is the profile's GST rate in basis points (default 1000 = 10%, which
    /// reduces to the legacy ÷11). (spec §3)
    static func derivedGstCents(totalCents: Int, bp: Int = 1000) -> Int {
        Int((Double(totalCents) * Double(bp) / Double(10_000 + bp)).rounded())
    }

    /// Toggle gstFree. true ⇒ gstCents=0, gstSource=nil. false ⇒ re-derive at `bp`
    /// (gstSource="derived"). `totalCents` is the magnitude of the txn amount.
    static func applyGstFree(_ gstFree: Bool, totalCents: Int, bp: Int = 1000) -> Result {
        if gstFree { return Result(gstCents: 0, gstSource: nil) }
        return Result(gstCents: derivedGstCents(totalCents: totalCents, bp: bp), gstSource: "derived")
    }
```

> Leave `applyManualGst`, `confirmIncome`, and the `BasViewModel` call sites unchanged — BAS stays 10% (spec §2.3) and `applyGstFree(true, …)` is unaffected by `bp`.

- [ ] **Step 4: Add `gstRateBp` to `ProfileOption` + populate it**

In `Snapceipt/Features/Capture/CaptureViewModel.swift`, change the `ProfileOption` struct (lines ~10-14):

```swift
struct ProfileOption: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String   // "personal" | "business"
    let gstRateBp: Int  // the profile's GST rate (basis points) for capture-GST derivation
}
```

And the `profileOptions` computed property (lines ~67-69):

```swift
    var profileOptions: [ProfileOption] {
        profiles.profiles.map { ProfileOption(id: $0.id, name: $0.name, type: $0.type, gstRateBp: $0.gstRateBp) }
    }
```

- [ ] **Step 5: Pass the selected profile's rate in `ReviewStep`**

In `Snapceipt/Features/Capture/Views/ReviewStep.swift`, add a computed `selectedGstRateBp` next to `selectedType` (lines ~42-45):

```swift
    private var selectedGstRateBp: Int {
        vm.profileOptions.first(where: { $0.id == selectedProfileId })?.gstRateBp ?? 1000
    }
```

Then update the GST-free toggle's setter (line ~259) to pass it:

```swift
                        let r = GstTreatment.applyGstFree(isFree, totalCents: Int((draft.total as NSDecimalNumber).doubleValue * 100), bp: selectedGstRateBp)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/GstTreatmentRateTests -only-testing:SnapceiptTests/GstTreatmentTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` — both the new rate tests and the existing `GstTreatmentTests` (10% ÷11 + the `.5`-boundary cases) pass, since the default arg keeps them at 10%.

- [ ] **Step 7: Commit**

```bash
git add Snapceipt/Features/Reports/Bas/GstTreatment.swift Snapceipt/Features/Capture/CaptureViewModel.swift Snapceipt/Features/Capture/Views/ReviewStep.swift SnapceiptTests/GstTreatmentRateTests.swift
git commit -m "feat(capture): GstTreatment derives at profile gstRateBp (15% etc.), default 10%

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Device-region GST default on profile creation

When a **business** profile is created, default `gstRateBp` from `Locale.current.region`: `AU`→1000, `NZ`→1500, else 1000. Adds a tiny pure helper (for testability) and wires it into the `Profile(...)` construction in `AddProfileViewModel.create()`. Modifies existing files (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Features/Profiles/AddProfileViewModel.swift`
- Test: `SnapceiptTests/AddProfileGstDefaultTests.swift`

**Interfaces:**
- Produces: `AddProfileViewModel.defaultGstRateBp(regionCode: String?) -> Int` (static, pure) and a `gstRateBp:` set on the created business `Profile`.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/AddProfileGstDefaultTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("AddProfile device-region GST default")
struct AddProfileGstDefaultTests {
    @Test("AU → 1000")
    func au() { #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "AU") == 1000) }

    @Test("NZ → 1500")
    func nz() { #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "NZ") == 1500) }

    @Test("other / nil → 1000")
    func other() {
        #expect(AddProfileViewModel.defaultGstRateBp(regionCode: "US") == 1000)
        #expect(AddProfileViewModel.defaultGstRateBp(regionCode: nil) == 1000)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/AddProfileGstDefaultTests 2>&1 | tail -20`
Expected: BUILD FAILURE — no `defaultGstRateBp`.

- [ ] **Step 3: Add the helper + wire it into `create()`**

In `Snapceipt/Features/Profiles/AddProfileViewModel.swift`, add the static helper to the class:

```swift
    /// Device-region GST default in basis points: AU → 1000 (10%), NZ → 1500 (15%),
    /// else 1000. (spec §3)
    static func defaultGstRateBp(regionCode: String?) -> Int {
        switch regionCode {
        case "NZ": return 1500
        case "AU": return 1000
        default: return 1000
        }
    }
```

In `create()`, compute the rate for business profiles and pass it to the `Profile(...)` init. Add before the `let p = Profile(`:

```swift
        let gstRateBp = isBusiness
            ? Self.defaultGstRateBp(regionCode: Locale.current.region?.identifier)
            : 1000
```

Then add `gstRateBp: gstRateBp,` to the `Profile(...)` call, immediately after `gstRegistered: isBusiness ? gstRegistered : false,`:

```swift
            gstRegistered: isBusiness ? gstRegistered : false,
            gstRateBp: gstRateBp,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/AddProfileGstDefaultTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 3 tests … passed`.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Profiles/AddProfileViewModel.swift SnapceiptTests/AddProfileGstDefaultTests.swift
git commit -m "feat(profiles): default gstRateBp from device region (AU 10% / NZ 15%) on business create

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: API client — `quoteShareLink` + `uploadProfileLogo`; change `sendQuote`; drop `generateQuotePdf`

Changes the `APIClient` protocol and all four conformers (Live/Stub/Preview/Mock), plus the DTOs. Adds `quoteShareLink(quoteId:) -> { url }` and `uploadProfileLogo(profileId:png:) -> ok`, changes `sendQuote` to return `{ url, emailed }`, and removes `generateQuotePdf`/`GenerateQuotePdfResponse`. The logo upload mirrors the existing raw-body image upload (`performRawJPEG`). Modifies existing files (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Sync/DTOs.swift`
- Modify: `Snapceipt/Sync/APIClient.swift` (protocol + `LiveAPIClient`)
- Modify: `Snapceipt/Sync/StubAPIClient.swift`
- Modify: `Snapceipt/Features/Auth/SignInView.swift` (`PreviewAPIClient`, DEBUG)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift`
- Test: covered by Task 7's VM tests + a build check here.

**Interfaces:**
- Produces:
  - `struct QuoteShareLinkResponse: Decodable { let url: String; let number: String? }` — `number` is the minted quote number; apply it to the local quote so "Quote #N" displays immediately after sharing.
  - `struct UploadProfileLogoResponse: Decodable { let logoR2Key: String }`
  - `struct SendQuoteResponse: Decodable { let url: String?; let emailed: Bool; let number: String? }` — trimmed to only what the backend returns; status/totals are synced separately.
  - `func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse`
  - `func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse`
  - `func sendQuote(_ id: String) async throws -> SendQuoteResponse` (changed return shape)
- Removed: `func generateQuotePdf(_ id: String)`, `struct GenerateQuotePdfResponse`.

- [ ] **Step 1: Update DTOs**

In `Snapceipt/Sync/DTOs.swift`, REPLACE the `SendQuoteResponse` struct (drop `pdfUrl`/`expiresAt`, add `url`) and REMOVE `GenerateQuotePdfResponse`; add the two new response structs:

```swift
/// `POST /quotes/:id/send` → the hosted HTML quote link + email status + minted number.
/// Status/totals are persisted server-side and synced via /sync — NOT returned here.
struct SendQuoteResponse: Decodable {
    /// The hosted HTML quote URL (https://api.snapceipt.cc/q/<token>).
    let url: String?
    let emailed: Bool
    /// The minted (or existing) quote number, e.g. "SN-0001". Apply to the local quote
    /// so "Quote #N" displays immediately without waiting for a sync pull.
    let number: String?
}

/// `POST /quotes/:id/link` → the hosted HTML quote URL + minted quote number (spec §4).
struct QuoteShareLinkResponse: Decodable {
    let url: String
    /// The minted (or existing) quote number. Apply to the local quote so the editor
    /// can show "Quote #N" immediately after sharing without a sync pull.
    let number: String?
}

/// `POST /profile/logo` → the stored R2 key (server-owned; iOS persists it locally
/// pull-only via sync, but the upload response lets us reflect it immediately). (spec §5)
struct UploadProfileLogoResponse: Decodable {
    let logoR2Key: String
}
```

> Delete the entire `struct GenerateQuotePdfResponse { … }` block.

- [ ] **Step 2: Update the protocol + `LiveAPIClient`**

In `Snapceipt/Sync/APIClient.swift`, in `protocol APIClient`, REPLACE the line `func generateQuotePdf(_ id: String) async throws -> GenerateQuotePdfResponse` with:

```swift
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse
    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse
```

(`func sendQuote(_ id: String) async throws -> SendQuoteResponse` stays — only its DTO changed.)

In `LiveAPIClient`, REPLACE the `generateQuotePdf` impl with the two new methods. `sendQuote` is unchanged (it already decodes `SendQuoteResponse`):

```swift
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        try await send("POST", "/quotes/\(id)/link", body: NoBody(), authenticated: true)
    }

    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        let data = try await performRawImage("/profile/logo",
                                             query: [URLQueryItem(name: "profileId", value: profileId)],
                                             bytes: png, contentType: "image/png")
        do { return try decoder.decode(UploadProfileLogoResponse.self, from: data) }
        catch { throw APIError.decoding }
    }
```

- [ ] **Step 3: Generalize the raw-body uploader**

In `Snapceipt/Sync/APIClient.swift`, rename/generalize `performRawJPEG` to `performRawImage(_:query:bytes:contentType:)` so both the existing JPEG upload and the new PNG logo upload share it. Replace `performRawJPEG`'s signature and the `Content-Type` line; keep the refresh-on-401 dance. Then update `uploadImage` to call the renamed helper with `contentType: "image/jpeg"`:

```swift
    private func performRawImage(_ path: String, query: [URLQueryItem], bytes: Data,
                                 contentType: String) async throws -> Data {
        func makeImageRequest() throws -> URLRequest {
            var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                           resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw APIError.transport }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
            if let bearer = auth.bearer() {
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = bytes
            return request
        }
        let (data, response) = try await dataResponse(for: try makeImageRequest())
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401, await tryRefresh() {
            let (data2, response2) = try await dataResponse(for: try makeImageRequest())
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.transport }
            return try validate(data2, http2)
        }
        return try validate(data, http)
    }
```

And in `uploadImage`, change the call:

```swift
        let data = try await performRawImage("/images", query: items, bytes: jpeg, contentType: "image/jpeg")
```

- [ ] **Step 4: Update `StubAPIClient`**

In `Snapceipt/Sync/StubAPIClient.swift`, REPLACE the `generateQuotePdf` stub with the two new methods, and change the `sendQuote` stub to the new shape:

```swift
    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        SendQuoteResponse(url: "https://api.snapceipt.cc/q/stub-token", emailed: false,
                          number: "SN-0001")
    }
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/stub-token", number: "SN-0001")
    }
    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        UploadProfileLogoResponse(logoR2Key: "\(profileId)/profiles/stub/logo")
    }
```

- [ ] **Step 5: Update `PreviewAPIClient`**

In `Snapceipt/Features/Auth/SignInView.swift` (the `#if DEBUG PreviewAPIClient`), REPLACE the `generateQuotePdf` impl and update `sendQuote`:

```swift
    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        SendQuoteResponse(url: "https://api.snapceipt.cc/q/preview-token", emailed: false,
                          number: "SN-0001")
    }
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/preview-token", number: "SN-0001")
    }
    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        UploadProfileLogoResponse(logoR2Key: "\(profileId)/profiles/preview/logo")
    }
```

- [ ] **Step 6: Update `MockAPIClient`**

In `SnapceiptTests/Mocks/MockAPIClient.swift`: remove the `generateQuotePdf` handler/calls/method; add handlers + call arrays + methods for `quoteShareLink` and `uploadProfileLogo`; keep `sendQuote` (only its DTO changed). Add to the handler/var block:

```swift
    var quoteShareLinkHandler: ((String) async throws -> QuoteShareLinkResponse)?
    var uploadProfileLogoHandler: ((String, Data) async throws -> UploadProfileLogoResponse)?
    private(set) var quoteShareLinkCalls: [String] = []
    private(set) var uploadProfileLogoCalls: [(profileId: String, bytes: Int)] = []
```

Remove `generateQuotePdfHandler` + `generateQuotePdfCalls`, and the `generateQuotePdf(_:)` method. Add the two methods (mirroring `sendQuote`'s record-then-handler pattern):

```swift
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        quoteShareLinkCalls.append(id)
        guard let h = quoteShareLinkHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }

    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        uploadProfileLogoCalls.append((profileId, png.count))
        guard let h = uploadProfileLogoHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, png)
    }
```

- [ ] **Step 7: Build the whole test target to confirm all conformers compile**

Run: `xcodebuild build-for-testing -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`. (If any conformer still references `generateQuotePdf`/`GenerateQuotePdfResponse`, the build fails — fix the straggler. The `QuoteEditorViewModel.generatePdf` straggler is addressed in Task 7; if this build fails ONLY on `QuoteEditorViewModel`, that is expected and resolved next — but `sendQuote`'s response shape change will also break the VM's `r.pdfUrl` reference, also fixed in Task 7. To keep this task self-contained, do a temporary minimal fix in `QuoteEditorViewModel` here: in `send`, change `pdfUrl = r.pdfUrl` to `pdfUrl = r.url`, and delete the `generatePdf(api:)` method body's `api.generateQuotePdf` call by leaving it for Task 7 — OR simply proceed to Task 7 immediately and run the build there. Prefer doing Task 6 + Task 7 back-to-back.)

> Implementer note: Task 6 and Task 7 are tightly coupled (the protocol change breaks the VM). Execute them back-to-back; the build green-check belongs at the end of Task 7. The "expected output" for Step 7 here is therefore "BUILD FAILS only in `QuoteEditorViewModel.swift` referencing the removed method / old DTO field" — proceed to Task 7.

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift Snapceipt/Sync/StubAPIClient.swift Snapceipt/Features/Auth/SignInView.swift SnapceiptTests/Mocks/MockAPIClient.swift
git commit -m "feat(api): add quoteShareLink + uploadProfileLogo; sendQuote returns {url,emailed}; drop generateQuotePdf

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Quote editor — share link + on-device WKWebView PDF; snapshot rate

Replaces the editor's PDF-route flow with: a **Share link** action (calls `quoteShareLink`, shares the `url` string) and a **Generate PDF** action (mints the link, loads it in a hidden `WKWebView`, renders a PDF file, shares the file). Snapshots `gstRateBp` from the active profile into the quote in `saveDraft`, and computes totals from the document/profile rate so the GST line is correct. Adds the new `QuotePdfRenderer.swift` (so this task runs `xcodegen generate`).

**Files:**
- Create: `Snapceipt/Features/Quotes/QuotePdfRenderer.swift`
- Modify: `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`
- Modify: `Snapceipt/Features/Quotes/QuoteEditorView.swift`
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (share-link + generate-PDF ids — see Task 9 for the full id list; add the two quote ids here)
- Test: `SnapceiptTests/QuoteEditorShareLinkTests.swift`

**Interfaces:**
- Consumes: `APIClient.quoteShareLink(_:) -> QuoteShareLinkResponse`, changed `SendQuoteResponse.url`, `QuoteTotals.compute(..., gstRateBp:)`, `Profile.gstRateBp`.
- Produces:
  - `@MainActor final class QuotePdfRenderer: NSObject` with `func renderPDF(from url: URL, fileName: String) async throws -> URL`.
  - `QuoteEditorViewModel.shareLink(api:) async -> String?` (returns the url, persists nothing else).
  - `QuoteEditorViewModel.generatePdf(api:renderer:) async -> URL?` (mints link, renders PDF, returns the file URL).
  - `QuoteEditorViewModel` snapshots `quote.gstRateBp` from the active profile in `saveDraft`; `totals` reads the snapshotted/profile rate.

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/QuoteEditorShareLinkTests.swift`. Uses the in-memory container + `MockAPIClient`, mirroring existing `QuoteEditorViewModelTests`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Quote editor share link + rate snapshot")
struct QuoteEditorShareLinkTests {
    private func makeVM() throws -> (QuoteEditorViewModel, ModelContext) {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        // Active business profile at 15%.
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500)
        p.id = "p1"
        c.insert(p); try c.save()
        let vm = QuoteEditorViewModel(context: c, sync: NoopSync(), userId: "u1", profileId: "p1")
        vm.load(id: nil)
        vm.setClient(name: "Acme", email: "a@acme.au")
        vm.addLine()
        vm.lineItems[0].itemDescription = "Work"
        vm.lineItems[0].quantity = 1
        vm.lineItems[0].unitPriceCents = 20_000
        return (vm, c)
    }

    @Test("saveDraft snapshots gstRateBp from the active profile + totals use it")
    func snapshotRate() throws {
        let (vm, c) = try makeVM()
        vm.saveDraft()
        let q = try c.fetch(FetchDescriptor<Quote>())[0]
        #expect(q.gstRateBp == 1500)
        // 200.00 @ 15% exclusive → gst 30.00, total 230.00
        #expect(q.gstCents == 3_000)
        #expect(q.totalCents == 23_000)
        #expect(vm.totals.gst == 3_000)
    }

    @Test("shareLink returns the url from the API and applies the minted number")
    func shareLink() async throws {
        let (vm, _) = try makeVM()
        let mock = MockAPIClient()
        mock.quoteShareLinkHandler = { _ in
            QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/tok", number: "SN-0001")
        }
        let url = await vm.shareLink(api: mock)
        #expect(url == "https://api.snapceipt.cc/q/tok")
        #expect(mock.quoteShareLinkCalls.count == 1)
        // The minted number is applied to the VM so "Quote #N" shows immediately.
        #expect(vm.number == "SN-0001")
    }

    @Test("send reads {url, emailed, number} — does NOT reference status/subtotalCents/gstCents/totalCents")
    func send() async throws {
        let (vm, _) = try makeVM()
        let mock = MockAPIClient()
        mock.sendQuoteHandler = { _ in
            SendQuoteResponse(url: "https://api.snapceipt.cc/q/tok", emailed: true,
                              number: "SN-0001")
        }
        let ok = await vm.send(api: mock)
        #expect(ok)
        #expect(vm.pdfUrl == "https://api.snapceipt.cc/q/tok")
        #expect(vm.emailed == true)
        // The minted number is applied immediately (no sync pull needed).
        #expect(vm.number == "SN-0001")
    }
}
```

> The test uses `NoopSync()` — the existing test-double `SyncEnqueuing` used by `QuoteEditorViewModelTests`. Read that file and reuse the exact double it uses (it may be named differently, e.g. `SpySync`/`StubSync`); substitute that name.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/QuoteEditorShareLinkTests 2>&1 | tail -20`
Expected: BUILD FAILURE — `shareLink` / changed `send` / `quoteShareLinkHandler` undefined; `gstRateBp` not snapshotted.

- [ ] **Step 3: Create the WKWebView PDF renderer**

Create `Snapceipt/Features/Quotes/QuotePdfRenderer.swift`:

```swift
import WebKit
import UIKit

/// Renders a hosted HTML quote page (the `/q/:token` link) to a PDF file on-device
/// (spec §4): load the URL in an off-screen `WKWebView`, wait for the page to finish,
/// `createPDF`, and write a temp file. `@MainActor` (WebKit is main-thread only).
@MainActor
final class QuotePdfRenderer: NSObject, WKNavigationDelegate {
    enum RenderError: Error { case load, pdf }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Load `url`, render to PDF, and return a temp file URL named `<fileName>.pdf`.
    func renderPDF(from url: URL, fileName: String) async throws -> URL {
        // A4-ish frame so the print-friendly CSS lays out correctly (595×842 pt).
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842), configuration: config)
        web.navigationDelegate = self
        self.webView = web

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.continuation = cont
            web.load(URLRequest(url: url))
        }

        // Give layout/web-fonts a beat to settle before snapshotting.
        try? await Task.sleep(nanoseconds: 300_000_000)

        let pdfData: Data = try await withCheckedThrowingContinuation { cont in
            web.createPDF(configuration: WKPDFConfiguration()) { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure: cont.resume(throwing: RenderError.pdf)
                }
            }
        }

        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        try pdfData.write(to: fileURL, options: .atomic)
        self.webView = nil
        return fileURL
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.continuation?.resume(); self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: RenderError.load); self.continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: RenderError.load); self.continuation = nil
        }
    }
}
```

- [ ] **Step 4: Snapshot the rate + add `shareLink`/`generatePdf` to the VM**

In `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`:

(a) Add a stored snapshot of the active profile's rate. Add after `@ObservationIgnored let profileId: String` a lazily-resolved rate, and a helper to fetch the profile:

```swift
    /// The active profile's GST rate (basis points), resolved lazily from storage; used
    /// for live totals + snapshotted onto the quote at save. (spec §3)
    @ObservationIgnored private lazy var profileGstRateBp: Int = {
        fetchProfile(profileId)?.gstRateBp ?? QuoteTotals.defaultRateBp
    }()

    private func fetchProfile(_ id: String) -> Profile? {
        var d = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
```

(b) Make `totals` read the document's snapshotted rate when loaded, else the profile rate. Add a stored `private(set) var gstRateBp: Int?` (loaded from the quote), set it in `load`, and change `totals`:

```swift
    private(set) var gstRateBp: Int?
```

In `load(id:)`, in the existing-quote branch add `gstRateBp = q.gstRateBp`; in the new-quote branch add `gstRateBp = nil`.

Change the `totals` computed property:

```swift
    var totals: (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled,
                            gstInclusive: gstInclusive, gstRateBp: gstRateBp ?? profileGstRateBp)
    }
```

(c) In `saveDraft()`, snapshot the rate onto the quote and persist it. After `quote.gstInclusive = gstInclusive`:

```swift
        quote.gstInclusive = gstInclusive
        // Snapshot the GST rate from the active profile on first save; keep an existing
        // snapshot so a re-save never re-rates an already-sent quote. (spec §2.2/§3)
        if quote.gstRateBp == nil { quote.gstRateBp = profileGstRateBp }
        gstRateBp = quote.gstRateBp
```

(The line items + totals are computed from `totals` which now uses this rate — and since the snapshot is set before `let t = totals` is read… ensure ordering: move the snapshot assignment to BEFORE `let t = totals` near the top of `saveDraft`. Concretely, set `quote.gstRateBp` right after the `quote` is fetched/created and `quote.profileId = profileId`, then compute `let t = totals`.)

Reordered `saveDraft` head:

```swift
    func saveDraft() {
        guard let qid = quoteId else { return }
        let quote = fetchQuote(qid) ?? {
            let q = Quote(userId: userId, profileId: profileId)
            q.id = qid
            context.insert(q)
            return q
        }()
        quote.profileId = profileId
        if quote.gstRateBp == nil { quote.gstRateBp = profileGstRateBp }
        gstRateBp = quote.gstRateBp
        let t = totals
        quote.clientName = clientName
        quote.clientEmail = clientEmail
        quote.gstEnabled = gstEnabled
        quote.gstInclusive = gstInclusive
        quote.subtotalCents = t.subtotal
        quote.gstCents = t.gst
        quote.totalCents = t.total
        quote.validUntil = validUntil
        quote.updatedAt = Epoch.nowMs()
        // …(line-item diff unchanged)…
```

(d) Change `send` to read `r.url` and `r.number`. Replace `pdfUrl = r.pdfUrl` with `pdfUrl = r.url`. Also apply the minted number: after `pdfUrl = r.url` add `if let n = r.number { number = n }` so the editor shows "Quote #N" without waiting for a sync pull. The emailed flag: `emailed = r.emailed`. Status is set locally (the response no longer carries it): `quote.status = "sent"` (the VM already does this — confirm and keep it; do NOT read `r.status`).

(e) Add `shareLink` and replace `generatePdf`. Replace the entire existing `generatePdf(api:)` method with:

```swift
    /// Mint (or re-mint) the hosted HTML quote link for the Share action (spec §4).
    /// Saves + flushes so the quote exists server-side, then POST /quotes/:id/link.
    /// Applies the minted number to the local quote so "Quote #N" displays immediately.
    func shareLink(api: APIClient) async -> String? {
        guard let qid = quoteId else { return nil }
        errorMessage = nil
        saveDraft()
        isSending = true
        defer { isSending = false }
        await sync.flush()
        do {
            let r = try await api.quoteShareLink(qid)
            pdfUrl = r.url
            // Apply the server-minted number immediately so the editor shows "Quote #N"
            // without waiting for a sync pull (spec §4: link issues the quote).
            if let n = r.number, number == nil {
                number = n
                if let q = fetchQuote(qid) { q.number = n; try? context.save() }
            }
            return r.url
        } catch let e as APIError {
            errorMessage = e.message
            return nil
        } catch {
            errorMessage = "Couldn’t create the link. Try again."
            return nil
        }
    }

    /// Generate the on-device PDF (spec §4): mint the link, then render it in a hidden
    /// WKWebView and return the temp PDF file URL for sharing.
    func generatePdf(api: APIClient, renderer: QuotePdfRenderer) async -> URL? {
        guard let urlString = await shareLink(api: api), let url = URL(string: urlString) else { return nil }
        isSending = true
        defer { isSending = false }
        do {
            let name = "Quote-\(number ?? "draft")"
            return try await renderer.renderPDF(from: url, fileName: name)
        } catch {
            errorMessage = "Couldn’t build the PDF. Try again."
            return nil
        }
    }
```

> Remove the now-dead `pdfR2Key` assignment that referenced `quote.pdfR2Key` inside the old `generatePdf`. `pdfR2Key` stays a `private(set) var` loaded from the quote (it's still synced/persisted) but is no longer set by a PDF route.

- [ ] **Step 5: Update the editor View**

In `Snapceipt/Features/Quotes/QuoteEditorView.swift`:

(a) Add a renderer + share-file state near the other `@State`:

```swift
    @State private var shareURL: URL?
    @State private var shareFileURL: URL?
    @State private var renderer = QuotePdfRenderer()
```

(b) Replace the "Generate / Share PDF" icon button's action (lines ~311-328) so it offers BOTH actions. Keep the icon-button shape but make it a `Menu` with "Share link" and "Generate PDF":

```swift
            Menu {
                Button {
                    Task {
                        if let url = await vm.shareLink(api: api), let u = URL(string: absolute(url)) {
                            shareURL = u
                        }
                    }
                } label: { Label("Share link", systemImage: "link") }
                .accessibilityIdentifier(AccessibilityID.quoteEditorShareLink)

                Button {
                    Task {
                        if let file = await vm.generatePdf(api: api, renderer: renderer) {
                            shareFileURL = file
                        }
                    }
                } label: { Label("Generate PDF", systemImage: "doc") }
                .accessibilityIdentifier(AccessibilityID.quoteEditorGeneratePdf)
            } label: {
                Icon(name: "doc", size: 22, color: Palette.ink2)
                    .frame(width: 56, height: 56)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Palette.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .disabled(!vm.canGeneratePdf || vm.isSending)
            .opacity(vm.canGeneratePdf ? 1 : 0.45)
            .accessibilityIdentifier(AccessibilityID.quoteEditorShareMenu)
```

(c) Add an absolute-URL helper + a second share sheet for the file. Replace the existing `openPDF` helper + `shareItem` plumbing with both a url-share and a file-share sheet. Keep `QuoteActivityView` (it already shares any item; for the file use a file-URL variant). Add:

```swift
    private func absolute(_ url: String) -> String {
        url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
    }

    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } })
    }
    private var shareFileItem: Binding<ShareItem?> {
        Binding(get: { shareFileURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareFileURL = nil } })
    }
```

And in `body`, add the file-share sheet next to the existing `.sheet(item: shareItem)`:

```swift
        .sheet(item: shareItem) { item in QuoteActivityView(url: item.url) }
        .sheet(item: shareFileItem) { item in QuoteActivityView(url: item.url) }
```

(d) In the success overlay's "View PDF" button (shown when `!vm.emailed`), change its action to share the link (the route no longer returns a PDF url to a download; it returns the HTML link). Replace its action with:

```swift
                Task {
                    if let url = await vm.shareLink(api: api), let u = URL(string: absolute(url)) {
                        shareURL = u
                    }
                }
```

> Update the overlay's gate from `vm.pdfUrl != nil` to keep it shown when `!vm.emailed` (the link is always mintable for a sent quote).

- [ ] **Step 6: Add the new AccessibilityIDs (quote editor share)**

In `Snapceipt/Shared/AccessibilityID.swift`, in the "Quote editor — new PDF + convert affordances" group, ADD (keep `quoteEditorGeneratePdf`):

```swift
    static let quoteEditorShareMenu = "quote.editor.shareMenu"
    static let quoteEditorShareLink = "quote.editor.shareLink"
```

- [ ] **Step 7: Generate the project (new file) + run the test**

Run: `/opt/homebrew/bin/xcodegen generate`
Then: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/QuoteEditorShareLinkTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 3 tests … passed`.

- [ ] **Step 8: Full-target build to confirm View + all conformers compile**

Run: `xcodebuild build-for-testing -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Snapceipt/Features/Quotes/QuotePdfRenderer.swift Snapceipt/Features/Quotes/QuoteEditorViewModel.swift Snapceipt/Features/Quotes/QuoteEditorView.swift Snapceipt/Shared/AccessibilityID.swift SnapceiptTests/QuoteEditorShareLinkTests.swift project.yml
git commit -m "feat(quotes): share HTML link + on-device WKWebView PDF; snapshot gstRateBp; drop PDF route

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> Note: `git add project.yml` only if `xcodegen generate` changed it; the `.xcodeproj` itself is gitignored.

---

### Task 8: Document rate snapshot — quote keeps its rate after profile flips

Verifies (spec §8 / §2.2) that a quote saved at 15% keeps 15% after the profile switches to 10% — the snapshot, not the live profile, drives totals/labels. No production code beyond Task 7; this task adds the guarding test (it would have caught a regression where `saveDraft` re-snapshots on every save). Modifies a test file only (no `xcodegen generate`).

**Files:**
- Test: `SnapceiptTests/DocumentRateSnapshotTests.swift`

**Interfaces:**
- Consumes: `QuoteEditorViewModel` (Task 7), `Profile.gstRateBp`, `Quote.gstRateBp`.

- [ ] **Step 1: Write the test**

Create `SnapceiptTests/DocumentRateSnapshotTests.swift`:

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("Document GST rate snapshot survives profile change")
struct DocumentRateSnapshotTests {
    @Test("quote saved at 15% keeps 15% after profile flips to 10%")
    func snapshotSurvives() throws {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                        gstRateBp: 1500)
        p.id = "p1"
        c.insert(p); try c.save()

        let vm = QuoteEditorViewModel(context: c, sync: NoopSync(), userId: "u1", profileId: "p1")
        vm.load(id: nil)
        vm.setClient(name: "Acme", email: nil)
        vm.addLine()
        vm.lineItems[0].itemDescription = "Work"
        vm.lineItems[0].unitPriceCents = 20_000
        vm.saveDraft()

        let q = try c.fetch(FetchDescriptor<Quote>())[0]
        #expect(q.gstRateBp == 1500)
        let qid = q.id

        // Profile rate later changes to 10%.
        p.gstRateBp = 1000
        try c.save()

        // Re-open the quote in a fresh VM — it must still total at 15%.
        let vm2 = QuoteEditorViewModel(context: c, sync: NoopSync(), userId: "u1", profileId: "p1")
        vm2.load(id: qid)
        #expect(vm2.totals.gst == 3_000)   // 200.00 @ 15%, NOT 20.00 @ 10%
        vm2.saveDraft()
        #expect(try c.fetch(FetchDescriptor<Quote>())[0].gstRateBp == 1500)
    }
}
```

> Use the same `NoopSync` (or its real name) double as Task 7.

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/DocumentRateSnapshotTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 1 test … passed`. (If it fails because `saveDraft` re-snapshots, fix the `if quote.gstRateBp == nil` guard in Task 7's `saveDraft`.)

- [ ] **Step 3: Commit**

```bash
git add SnapceiptTests/DocumentRateSnapshotTests.swift
git commit -m "test(quotes): document gstRateBp snapshot survives profile rate change

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: Tax & GST settings — rate control + Business/Bank sections + logo

Extends `TaxSettingsViewModel` with a GST-rate preset/custom control (stored as bp on the active `Profile.gstRateBp`), business-field setters (`businessEmail`/`phone`/`website`/`addressText`/`bankDetails`), and a logo upload (`PhotosPicker` → `ImageReducer` → `api.uploadProfileLogo` → store `logoR2Key`). Extends `TaxSettingsView` with the GST-rate control, a "Business details" section (incl. the logo picker/preview) and a "Bank details" section. The VM must now take an `api` client (it currently doesn't). Modifies existing files + the AccessibilityID file (no new source file → no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Features/Settings/TaxSettingsViewModel.swift`
- Modify: `Snapceipt/Features/Settings/TaxSettingsView.swift`
- Modify: `Snapceipt/Shared/AccessibilityID.swift`
- Modify: `Snapceipt/App/RootView.swift:371` — the sole `TaxSettingsView(` call site; pass `api: captureAPI`.
- Test: `SnapceiptTests/TaxSettingsBusinessFieldsTests.swift`

**Interfaces:**
- Consumes: `ImageReducer().reduce(_: UIImage) -> Data`, `APIClient.uploadProfileLogo(profileId:png:)`, `Profile.gstRateBp` + business fields.
- Produces:
  - `TaxSettingsViewModel.init(context:sync:userId:profile:api:defaults:)` (adds `api: APIClient`).
  - `var gstRateBp: Int` (mirror) + `func setGstRateBp(_:)`, `var gstRatePreset: GstRatePreset` (`.au`/`.nz`/`.custom`) + `func setGstRatePreset(_:)`, `func setCustomGstPercent(_ percent: Double)`.
  - `var businessEmail/phone/website/addressText/bankDetails: String` mirrors + `setBusinessEmail/...` setters.
  - `var logoR2Key: String?` mirror + `func uploadLogo(_ image: UIImage) async` (sets `isUploadingLogo`, calls api, stores key, saves profile).
  - `enum GstRatePreset: String { case au, nz, custom }` with `displayName` (`"10% (Australia)"`, `"15% (New Zealand)"`, `"Custom %"`).

- [ ] **Step 1: Write the failing test**

Create `SnapceiptTests/TaxSettingsBusinessFieldsTests.swift`:

```swift
import Foundation
import SwiftData
import UIKit
import Testing
@testable import Snapceipt

@MainActor
@Suite("TaxSettings business fields + GST rate")
struct TaxSettingsBusinessFieldsTests {
    private func makeVM() throws -> (TaxSettingsViewModel, Profile, MockAPIClient) {
        let c = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
        p.id = "p1"
        c.insert(p); try c.save()
        let mock = MockAPIClient()
        let vm = TaxSettingsViewModel(context: c, sync: NoopSync(), userId: "u1", profile: p, api: mock)
        return (vm, p, mock)
    }

    @Test("preset NZ sets 1500; AU sets 1000")
    func presets() throws {
        let (vm, p, _) = try makeVM()
        vm.setGstRatePreset(.nz)
        #expect(vm.gstRateBp == 1500)
        #expect(p.gstRateBp == 1500)
        vm.setGstRatePreset(.au)
        #expect(vm.gstRateBp == 1000)
        #expect(p.gstRateBp == 1000)
    }

    @Test("custom 12.5% → 1250 bp; preset reads back as .custom")
    func custom() throws {
        let (vm, p, _) = try makeVM()
        vm.setCustomGstPercent(12.5)
        #expect(vm.gstRateBp == 1250)
        #expect(p.gstRateBp == 1250)
        #expect(vm.gstRatePreset == .custom)
    }

    @Test("preset derives from existing rate: 1000→.au, 1500→.nz, else .custom")
    func presetDerivation() throws {
        let (vm, p, _) = try makeVM()
        p.gstRateBp = 1500; #expect(vm.derivedPreset == .nz)
        p.gstRateBp = 1000; #expect(vm.derivedPreset == .au)
        p.gstRateBp = 1250; #expect(vm.derivedPreset == .custom)
    }

    @Test("business field setters persist + normalize blank to nil")
    func businessFields() throws {
        let (vm, p, _) = try makeVM()
        vm.setBusinessEmail("hi@biz.au")
        vm.setPhone("0400")
        vm.setWebsite("biz.au")
        vm.setAddressText("1 St\nSydney")
        vm.setBankDetails("BSB 000-000\nAcct 1")
        #expect(p.businessEmail == "hi@biz.au")
        #expect(p.phone == "0400")
        #expect(p.website == "biz.au")
        #expect(p.addressText == "1 St\nSydney")
        #expect(p.bankDetails == "BSB 000-000\nAcct 1")
        vm.setBusinessEmail("   ")
        #expect(p.businessEmail == nil)
    }

    @Test("uploadLogo reduces + uploads + stores key")
    func logo() async throws {
        let (vm, p, mock) = try makeVM()
        mock.uploadProfileLogoHandler = { pid, _ in
            UploadProfileLogoResponse(logoR2Key: "\(pid)/profiles/p1/logo")
        }
        let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        await vm.uploadLogo(img)
        #expect(mock.uploadProfileLogoCalls.count == 1)
        #expect(mock.uploadProfileLogoCalls[0].profileId == "p1")
        #expect(vm.logoR2Key == "p1/profiles/p1/logo")
        #expect(p.logoR2Key == "p1/profiles/p1/logo")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/TaxSettingsBusinessFieldsTests 2>&1 | tail -20`
Expected: BUILD FAILURE — VM has no `api` param / no `setGstRatePreset` / no business setters / no `uploadLogo`.

- [ ] **Step 3: Extend `TaxSettingsViewModel`**

In `Snapceipt/Features/Settings/TaxSettingsViewModel.swift`:

(a) Add the preset enum at file scope (above the class):

```swift
/// GST-rate presets for the Tax & GST settings control. (spec §3)
enum GstRatePreset: String, CaseIterable, Identifiable {
    case au, nz, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .au: return "10% (Australia)"
        case .nz: return "15% (New Zealand)"
        case .custom: return "Custom %"
        }
    }
}
```

(b) Add the `api` dependency + new mirror state. Add to the stored deps:

```swift
    @ObservationIgnored private let api: APIClient
```

Add to the published mirrors:

```swift
    private(set) var gstRateBp: Int
    private(set) var businessEmail: String
    private(set) var phone: String
    private(set) var website: String
    private(set) var addressText: String
    private(set) var bankDetails: String
    private(set) var logoR2Key: String?
    private(set) var isUploadingLogo = false
    var logoUploadError: String?
```

(c) Change the init signature + seed the new mirrors:

```swift
    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profile: Profile,
         api: APIClient, defaults: UserDefaults = .standard) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profile = profile
        self.api = api
        self.defaults = defaults
        // …(existing TaxSettings fetch/create + existing mirror seeding)…
        self.gstRateBp = profile.gstRateBp
        self.businessEmail = profile.businessEmail ?? ""
        self.phone = profile.phone ?? ""
        self.website = profile.website ?? ""
        self.addressText = profile.addressText ?? ""
        self.bankDetails = profile.bankDetails ?? ""
        self.logoR2Key = profile.logoR2Key
    }
```

> Keep the existing init body (the `TaxSettings` fetch/create and the existing `abn`/`gstRegistered`/etc. seeding). Only add the `api` assignment + the new mirror seeding lines.

(d) Add the preset derivation + setters (each follows the established mirror→profile→`saveProfile()` pattern; `saveProfile()` already exists):

```swift
    /// The preset the current rate corresponds to (1000→.au, 1500→.nz, else .custom).
    var derivedPreset: GstRatePreset {
        switch gstRateBp {
        case 1000: return .au
        case 1500: return .nz
        default: return .custom
        }
    }
    var gstRatePreset: GstRatePreset { derivedPreset }
    /// Percent string for the custom field (e.g. 1250 → "12.5").
    var gstRatePercentText: String {
        let pct = Double(gstRateBp) / 100.0
        return pct == pct.rounded() ? String(Int(pct)) : String(pct)
    }

    func setGstRateBp(_ bp: Int) {
        let clamped = max(0, min(10_000, bp))   // 0%..100%
        gstRateBp = clamped
        profile.gstRateBp = clamped
        saveProfile()
    }
    func setGstRatePreset(_ preset: GstRatePreset) {
        switch preset {
        case .au: setGstRateBp(1000)
        case .nz: setGstRateBp(1500)
        case .custom: break   // custom is set via setCustomGstPercent
        }
    }
    /// `12.5` → 1250 bp.
    func setCustomGstPercent(_ percent: Double) {
        setGstRateBp(Int((percent * 100).rounded()))
    }

    private func normalize(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    func setBusinessEmail(_ s: String) { businessEmail = s; profile.businessEmail = normalize(s); saveProfile() }
    func setPhone(_ s: String) { phone = s; profile.phone = normalize(s); saveProfile() }
    func setWebsite(_ s: String) { website = s; profile.website = normalize(s); saveProfile() }
    func setAddressText(_ s: String) { addressText = s; profile.addressText = normalize(s); saveProfile() }
    func setBankDetails(_ s: String) { bankDetails = s; profile.bankDetails = normalize(s); saveProfile() }

    /// Reduce → upload → store `logoR2Key`. The key is server-owned (synced pull-only);
    /// we set it locally from the upload response so the preview updates immediately.
    func uploadLogo(_ image: UIImage) async {
        logoUploadError = nil
        isUploadingLogo = true
        defer { isUploadingLogo = false }
        let png = ImageReducer().reduce(image)
        do {
            let r = try await api.uploadProfileLogo(profileId: profile.id, png: png)
            logoR2Key = r.logoR2Key
            profile.logoR2Key = r.logoR2Key
            saveProfile()
        } catch let e as APIError {
            logoUploadError = e.message
        } catch {
            logoUploadError = "Couldn’t upload the logo. Try again."
        }
    }
```

> `ImageReducer().reduce` returns JPEG bytes today; the backend `/profile/logo` accepts `image/png` per the API contract. The reduced bytes are sent as the body with `Content-Type: image/png` from `uploadProfileLogo` — the worker re-encodes/stores them; if the backend strictly requires PNG magic bytes, the implementer should add a PNG re-encode (`image.pngData()`) path. For this plan, send the reducer output (bounded size) — the contract is "image bytes" (spec §5). If a PNG is strictly required, use `image.pngData() ?? ImageReducer().reduce(image)`.

- [ ] **Step 4: Extend `TaxSettingsView`**

In `Snapceipt/Features/Settings/TaxSettingsView.swift`:

(a) Add `import PhotosUI` at the top (next to `import SwiftUI`).

(b) Add the `api` to the View's stored props + pass it to the VM in `.task`:

```swift
    let api: APIClient
```

In `.task`, change the VM construction to pass `api: api`:

```swift
                let model = TaxSettingsViewModel(context: profiles.context, sync: sync,
                                                 userId: profiles.userId, profile: profile, api: api)
```

(c) Add `@State` mirrors + a `PhotosPickerItem` for the new editable text fields (mirroring the `abnText` pattern), and seed them in `.task`:

```swift
    @State private var businessEmailText = ""
    @State private var phoneText = ""
    @State private var websiteText = ""
    @State private var addressTextField = ""
    @State private var bankDetailsText = ""
    @State private var logoItem: PhotosPickerItem?
```

In `.task` seeding block (where `abnText` / `wfhText` are seeded):

```swift
                businessEmailText = model.businessEmail
                phoneText = model.phone
                websiteText = model.website
                addressTextField = model.addressText
                bankDetailsText = model.bankDetails
```

(d) Add a GST-rate control inside the existing `businessIdentity(_:)` `Card` (it is gated on business profiles — the right place). Add after the existing "Registered for GST" toggle + divider, before/after "GST accounting" (place it right after the toggle):

```swift
            divider
            VStack(alignment: .leading, spacing: 8) {
                Text("GST rate").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                Picker("GST rate", selection: Binding(
                    get: { vm.gstRatePreset },
                    set: { vm.setGstRatePreset($0) })) {
                        ForEach(GstRatePreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(AccessibilityID.taxGstRateControl)
                if vm.gstRatePreset == .custom {
                    HStack(spacing: 6) {
                        TextField("12.5", text: Binding(
                            get: { vm.gstRatePercentText },
                            set: { if let pct = Double($0) { vm.setCustomGstPercent(pct) } }))
                            .keyboardType(.decimalPad)
                            .font(.ui(16, .regular))
                            .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier(AccessibilityID.taxGstRateCustom)
                        Text("%").font(.ui(16)).foregroundStyle(Palette.ink2)
                    }
                }
            }
```

(e) Add a "Business details" section + a "Bank details" section. Add new `@ViewBuilder` functions and call them in `body` after `businessIdentity(vm)` (still gated by `vm.showsBusinessIdentity`):

In `body`, where `if vm.showsBusinessIdentity { businessIdentity(vm) }`:

```swift
                            if vm.showsBusinessIdentity {
                                businessIdentity(vm)
                                businessDetails(vm)
                                bankDetails(vm)
                            }
```

Add the builders (mirroring `businessIdentity`'s `groupLabel` + `Card` + `divider` structure):

```swift
    @ViewBuilder private func businessDetails(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Business details")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                labeledField("Business email", placeholder: "you@business.com",
                             text: $businessEmailText, id: AccessibilityID.taxBusinessEmailField,
                             keyboard: .emailAddress) { vm.setBusinessEmail($0) }
                divider
                labeledField("Phone", placeholder: "0400 000 000",
                             text: $phoneText, id: AccessibilityID.taxBusinessPhoneField,
                             keyboard: .phonePad) { vm.setPhone($0) }
                divider
                labeledField("Website", placeholder: "yourbusiness.com",
                             text: $websiteText, id: AccessibilityID.taxBusinessWebsiteField,
                             keyboard: .URL) { vm.setWebsite($0) }
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Address").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                    TextField("Street, suburb, state", text: $addressTextField, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.ui(16, .regular))
                        .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: addressTextField) { _, v in vm.setAddressText(v) }
                        .accessibilityIdentifier(AccessibilityID.taxBusinessAddressField)
                }
                divider
                logoRow(vm)
            }
        }
    }

    @ViewBuilder private func logoRow(_ vm: TaxSettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Logo").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            HStack(spacing: 12) {
                if vm.isUploadingLogo {
                    ProgressView().frame(width: 48, height: 48)
                } else if vm.logoR2Key != nil {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 28))
                        .foregroundStyle(accent.base).frame(width: 48, height: 48)
                        .accessibilityIdentifier(AccessibilityID.taxBusinessLogoPreview)
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(Palette.ink3)
                        .frame(width: 48, height: 48)
                        .background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                }
                PhotosPicker(selection: $logoItem, matching: .images) {
                    Text(vm.logoR2Key == nil ? "Add logo" : "Change logo")
                        .font(.ui(14.5, .semibold)).foregroundStyle(accent.base)
                }
                .accessibilityIdentifier(AccessibilityID.taxBusinessLogoPicker)
            }
            if let err = vm.logoUploadError {
                Text(err).font(.ui(12)).foregroundStyle(Palette.alert)
            }
        }
        .onChange(of: logoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await vm.uploadLogo(image)
                }
                logoItem = nil
            }
        }
    }

    @ViewBuilder private func bankDetails(_ vm: TaxSettingsViewModel) -> some View {
        groupLabel("Bank details")
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Payment details").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
                TextField("BSB + account, PayID, or international details", text: $bankDetailsText, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.ui(16, .regular))
                    .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: bankDetailsText) { _, v in vm.setBankDetails(v) }
                    .accessibilityIdentifier(AccessibilityID.taxBankDetailsField)
            }
        }
    }

    /// A label + single-line text field that commits to the VM on change (mirrors the ABN row).
    @ViewBuilder private func labeledField(_ title: String, placeholder: String,
                                           text: Binding<String>, id: String,
                                           keyboard: UIKeyboardType,
                                           onCommit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .font(.ui(16, .regular))
                .padding(12).background(Palette.paper2, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: text.wrappedValue) { _, v in onCommit(v) }
                .accessibilityIdentifier(id)
        }
    }
```

> Color tokens: `Palette.alert` is already used for the ABN hint (reuse it for `logoUploadError`); the logo-preview tick uses `accent.base` (the `@Environment(\.accent)` already in the View). The logo preview uses a checkmark rather than fetching the R2 image (the key alone confirms upload; rendering the remote logo is not required by the spec for the settings preview).

(f) Update the `TaxSettingsView(` call site to pass `api:`. The only call site is `Snapceipt/App/RootView.swift:371`:
`TaxSettingsView(profiles: profiles, sync: sync, onClose: { router.dismissOverlay() })`
Change it to pass the API client already in scope there (`RootView` holds `captureAPI`, used a few lines above for `EmailInViewModel(..., api: captureAPI, ...)`):
`TaxSettingsView(profiles: profiles, sync: sync, api: captureAPI, onClose: { router.dismissOverlay() })`

- [ ] **Step 5: Add the AccessibilityIDs**

In `Snapceipt/Shared/AccessibilityID.swift`, in the Tax & GST group, ADD:

```swift
    static let taxGstRateControl = "tax.gstRate.control"
    static let taxGstRateCustom = "tax.gstRate.custom"
    static let taxBusinessEmailField = "tax.business.email"
    static let taxBusinessPhoneField = "tax.business.phone"
    static let taxBusinessWebsiteField = "tax.business.website"
    static let taxBusinessAddressField = "tax.business.address"
    static let taxBusinessLogoPicker = "tax.business.logo.picker"
    static let taxBusinessLogoPreview = "tax.business.logo.preview"
    static let taxBankDetailsField = "tax.bank.details"
```

- [ ] **Step 6: Run the test**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/TaxSettingsBusinessFieldsTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 6 tests … passed`.

- [ ] **Step 7: Full build (View compiles + call site passes `api`)**

Run: `xcodebuild build-for-testing -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`. (A failure here usually means the `TaxSettingsView(` call site still omits `api:` — add it.)

- [ ] **Step 8: Commit**

```bash
git add Snapceipt/Features/Settings/TaxSettingsViewModel.swift Snapceipt/Features/Settings/TaxSettingsView.swift Snapceipt/Shared/AccessibilityID.swift Snapceipt/App/RootView.swift SnapceiptTests/TaxSettingsBusinessFieldsTests.swift
git commit -m "feat(settings): GST-rate control + Business/Bank sections + logo upload in Tax & GST

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Remove the duplicate "Review" pill on the Reports BAS card (#4)

Removes the top-right `Text(basLodged ? "Lodged" : "Review")` pill from `ReportsView.basCard`; keeps the bottom "Review ›" CTA and the whole-card tap. (spec §6) Modifies one existing file (no `xcodegen generate`).

**Files:**
- Modify: `Snapceipt/Features/Reports/ReportsView.swift` (`basCard`, lines 107–111)
- Test: `SnapceiptTests/AccessibilityIDQuoteHtmlTests.swift` is unrelated; this UI removal is verified by build + the existing `reportsBasCard` id staying intact. No new unit test (it's a pure view-copy removal — a unit test would assert nothing meaningful).

**Interfaces:** none changed.

- [ ] **Step 1: Remove the pill**

In `Snapceipt/Features/Reports/ReportsView.swift`, replace the header `HStack` (lines 107–111) so the caption stays but the pill + its `Spacer` are gone:

Replace:

```swift
                    HStack {
                        Text("BAS · this quarter").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                        Spacer()
                        Text(basLodged ? "Lodged" : "Review").font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                    }
```

With:

```swift
                    Text("BAS · this quarter").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
```

- [ ] **Step 2: Check for a now-unused `basLodged`**

Run: `grep -n "basLodged" Snapceipt/Features/Reports/ReportsView.swift`
If `basLodged` is now referenced nowhere else in the file, leave its declaration (it may be a passed-in prop consumed by the parent or other cards) — do NOT remove a stored property that the parent still sets, as that changes the call site. Only remove it if it is a `private` computed/local used solely by the deleted line AND the compiler warns it's unused. Expected: either other references exist, or an unused-warning that you resolve by deleting the local declaration.

- [ ] **Step 3: Build to confirm**

Run: `xcodebuild build-for-testing -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (no unused-variable error).

- [ ] **Step 4: Commit**

```bash
git add Snapceipt/Features/Reports/ReportsView.swift
git commit -m "fix(reports): remove duplicate top-right Review/Lodged pill on BAS card (#4)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 11: AccessibilityID stability test + full-suite green

A small guard test that the new id constants exist + have stable string values (the UI-test target asserts on these strings; a typo here silently breaks XCUITest). Then run the full `SnapceiptTests` suite to confirm no regressions across all tasks. Modifies a test file only (no `xcodegen generate`).

**Files:**
- Test: `SnapceiptTests/AccessibilityIDQuoteHtmlTests.swift`

**Interfaces:**
- Consumes: the new `AccessibilityID` constants from Tasks 7 + 9.

- [ ] **Step 1: Write the test**

Create `SnapceiptTests/AccessibilityIDQuoteHtmlTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("AccessibilityID — quote-html + tax-business ids")
struct AccessibilityIDQuoteHtmlTests {
    @Test("ids are stable strings")
    func ids() {
        #expect(AccessibilityID.quoteEditorShareMenu == "quote.editor.shareMenu")
        #expect(AccessibilityID.quoteEditorShareLink == "quote.editor.shareLink")
        #expect(AccessibilityID.quoteEditorGeneratePdf == "quote.editor.generatePdf")
        #expect(AccessibilityID.taxGstRateControl == "tax.gstRate.control")
        #expect(AccessibilityID.taxGstRateCustom == "tax.gstRate.custom")
        #expect(AccessibilityID.taxBusinessEmailField == "tax.business.email")
        #expect(AccessibilityID.taxBusinessPhoneField == "tax.business.phone")
        #expect(AccessibilityID.taxBusinessWebsiteField == "tax.business.website")
        #expect(AccessibilityID.taxBusinessAddressField == "tax.business.address")
        #expect(AccessibilityID.taxBusinessLogoPicker == "tax.business.logo.picker")
        #expect(AccessibilityID.taxBusinessLogoPreview == "tax.business.logo.preview")
        #expect(AccessibilityID.taxBankDetailsField == "tax.bank.details")
    }
}
```

- [ ] **Step 2: Run the test**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/AccessibilityIDQuoteHtmlTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, `Test run with 1 test … passed`.

- [ ] **Step 3: Run the FULL SnapceiptTests suite (regression sweep)**

Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **`. In particular confirm the pre-existing `QuoteTotalsTests`, `GstTreatmentTests`, `QuoteEditorViewModelTests`, `QuoteSyncTests`, `InvoiceSyncTests` all still pass (the default-arg + new-field changes are backward-compatible).

- [ ] **Step 4: Commit**

```bash
git add SnapceiptTests/AccessibilityIDQuoteHtmlTests.swift
git commit -m "test(a11y): stability guards for quote-html + tax-business accessibility ids

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Resolved Ambiguities

1. **`gstRateBp` (spec) vs the existing dormant `TaxSettings.gstRateBps`.** The codebase already has `TaxSettings.gstRateBps` (note the trailing **s**) — a synced `Int` column (default 1000) that is read by NO production code (only the model + its sync mapper reference it). The spec asks for `Profile.gstRateBp` (no `s`), wire key `gstRateBp`, snapshotted onto documents. **Resolution:** follow the spec exactly — add `Profile.gstRateBp` + wire key `gstRateBp`, leave `TaxSettings.gstRateBps` untouched and dormant. Rationale: (a) the spec's §7 wire-key contract is the binding cross-plan contract with the backend plan (`gstRateBp`, not `gstRateBps`), so renaming/consolidating would break that contract; (b) the GST rate is conceptually a profile/branding attribute the spec places on `Profile` and snapshots onto documents, whereas `TaxSettings` is the AU-tax (FY/meals/WFH/mileage) row; (c) the dormant column carries no data anyone reads, so coexistence is harmless. A future cleanup could remove `TaxSettings.gstRateBps`, but that's out of scope here and noted, not done.

2. **Settings GST control lives in the existing "Business" `Card`, not a new top-level section.** The spec (§3/§4) calls for "a GST-rate control" in Tax & GST settings. The existing `businessIdentity(_:)` card (ABN + GST-registered toggle) is the natural, already-business-gated home, so the rate control is placed there; the separate "Business details" + "Bank details" sections are new `groupLabel`+`Card` blocks below it. Rationale: keeps GST identity together and avoids an orphan single-control section; matches the file's existing section grammar.

3. **Logo upload bytes / content type.** `ImageReducer.reduce` returns JPEG today, but the backend route is `POST /profile/logo` accepting "image bytes" (spec §5/§6 inlines it as a data-URI server-side). **Resolution:** reuse `ImageReducer` for size-bounding and send the bytes with `Content-Type: image/png` (the wire contract names PNG), with a documented fallback to `image.pngData()` if the worker strictly validates PNG magic bytes. Rationale: reuses the shipped reducer (spec §4 "reuse the capture `ImageReducing`") while honoring the route's declared content type; the worker re-stores/inlines regardless of source encoding.

4. **"Share PDF" button becomes a Menu offering both "Share link" and "Generate PDF".** The spec (§4/§5) says replace "Generate / Share PDF" with **Share link** *plus* a **Generate PDF** that renders on-device. The existing UI is a single icon button. **Resolution:** turn that icon button into a `Menu` with both actions (link = share the url string; PDF = WKWebView render + share file), preserving the existing button footprint and the primary "Send quote" button. Rationale: surfaces both new affordances without redesigning the send bar; the primary action stays "Send quote".

5. **`generatePdf` keeps its name but changes signature (`api:` → `api:renderer:`).** The spec says "drop `generatePdf`/`GenerateQuotePdfResponse`," meaning drop the *route-backed PDF generation*. **Resolution:** the VM method is repurposed (not deleted) to the on-device renderer flow with a new `renderer:` parameter, and the `GenerateQuotePdfResponse` DTO + `api.generateQuotePdf` protocol method are deleted. Rationale: callers/tests reason about "generate the PDF" as the user-facing capability; reusing the name with the new mechanism is clearer than a parallel name, and the dropped artifacts (the route + DTO) are the ones the spec actually names.

6. **`Profile.addressText` ↔ wire key `address`.** The spec's iOS field list names `addressText` but the §7 wire-key contract names `address`. **Resolution:** model property `addressText` (matches the spec's iOS naming + avoids colliding with any future structured address), encoded/decoded under wire key `address` (the cross-plan contract). This is an intentional name remap, mirroring the existing `Profile.type` ↔ wire `profileType` remap.
