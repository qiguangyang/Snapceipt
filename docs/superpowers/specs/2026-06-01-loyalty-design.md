# F4 — Loyalty Barcodes — Design

**Status:** Approved (brainstorm complete 2026-06-01) → writing-plans.
**Feature:** F4 in the remaining-features roadmap (`docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md`). Builds on F1 Logbooks, F2 Reports, F3 Budgets+push (all shipped & green on `foundation`/`main`).
**Goal:** A per-profile loyalty/membership-card wallet you pull up at the checkout — store branded cards and render a **real, scannable** barcode full-screen, plus scan-to-import from a physical card.

§4 is the **authoritative cross-unit contract**. F4 is **iOS-only** — no backend work.

---

## 1. Scope & non-goals

**In scope (v1, "real" per project memory):**
- A loyalty wallet reached from a new **Home "Loyalty Card" quick action** (star icon), opening three full-screen overlays: **wallet list → add card → immersive card detail**.
- **Real barcode rendering** for all five model symbologies — `code128`, `qr`, `pdf417`, `aztec` (native CoreImage) + `ean13`/UPC-A (a hand-rolled CoreGraphics renderer), with a number-only fallback.
- **Scan-to-import** via `DataScannerViewController` (Vision barcodes) — captures the barcode value + symbology and prefills the add form; manual brand-pick + number entry is the always-available path.
- **Screen-brightness boost** on the detail screen (max on appear, restored on disappear).
- Per-profile scoping, local-first CRUD through the existing sync seam, designed `EmptyArt` first-run state.

**Non-goals / deferred (v1.1+):**
- Share as image/PassKit pass (v1 Share = `ShareLink` of the member number only).
- "Auto-match loyalty points to receipts" (mentioned in the prototype hint — out of scope for F4).
- Drag-to-reorder the wallet (order by `sortOrder` then `createdAt`; new cards append).
- A backend brand catalog / "300+ brands" source (v1 = a static in-app brand list + a Custom brand).
- App-layer at-rest encryption of the member number (stored plain like all other synced domain data — a low-sensitivity reference, not a secret).

---

## 2. Architecture & navigation

F4 adds iOS UI only. The `loyalty_cards` D1 table, the `LoyaltyCard` `@Model`, `EntityType.loyaltyCard`, and `LoyaltyCardSyncMapper` already exist and round-trip via the generic `/sync/push`+`/sync/pull` (verified in `Snapceipt/Sync/SyncEntityRegistry.swift`). No new backend routes, no migration, no sync-mapper change.

**Router** (`Snapceipt/App/Router.swift`) gains three `Overlay` cases (all full-screen, presented via `ShellView.overlay`, dismissed via `dismissOverlay()`):
- `.loyalty` — the wallet.
- `.loyaltyAdd` — the add-card screen.
- `.loyaltyCard(id: String)` — the immersive detail for a specific card (associated value = card id, mirroring `.budgetEditor(id:)`).

**Home** (`Snapceipt/App/RootView.swift`, `homeStub`) gains a third quick action beside Mileage + WFH:
- `quickAction(title: "Loyalty Card", icon: "star", id: AccessibilityID.homeQuickLoyalty, accent: accent) { router.present(.loyalty) }`.

**Navigation flow:** Home → `.loyalty`; wallet `+`/CTA → `.loyaltyAdd`; wallet tile tap → `.loyaltyCard(id:)`; add success → back to `.loyalty`; all back buttons → `dismissOverlay()`.

**Reused infrastructure (no new primitives):** `LbHeader(title:onClose:onAdd:)` and `LbFloatingCTA(title:a11yId:action:)` (`Snapceipt/Features/Logbooks/LogbookChrome.swift`); the shared `SheetHeader(title:onClose:)` (defined in `Snapceipt/Features/Budgets/BudgetEditorView.swift`, back button + centered title, no `+`); `Card`, `IconCircle`, `Icon`, `EmptyArt`, `ProgressBar`; `Palette`/`AccentPalette`/`Radius`; `fmt`; the `@Observable @MainActor` + init-injected (`context`, `sync`, `userId`, `profileId`) view-model pattern; `SyncEnqueuing.enqueue`; the `.accessibilityElement(children: .contain)` container pattern (the F3 fix). The camera permission is already primed in onboarding (`PermissionKind.camera`) — no new prompt.

---

## 3. Data model & scoping

The `LoyaltyCard` `@Model` (`Snapceipt/Model/Entities/LoyaltyCard.swift`) is unchanged. Fields: `id`, `userId`, `profileId: String?`, `brand`, `subBrand: String?`, `number`, `barcodeFormat: String?`, `pointsLabel: String?`, `color1`, `color2` (both required hex), `sortOrder: Int` + sync envelope (`createdAt/updatedAt/deletedAt/rev/lastEditedDeviceId`). Init labels are as in the model file; `color1`/`color2` are **required**.

- **Per-profile scoping (CRITICAL rule):** every wallet query filters by the active `profileId`:
  `FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }, sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])`. Create always sets `profileId` = active profile (never nil). This matches budgets/logbooks and the scope-by-`profileId` invariant.
- **Typed format without touching storage:** add a Swift enum + computed bridge in a small `LoyaltyCard` extension (storage stays the raw `String?` for sync symmetry; the D1 `CHECK` enforces validity server-side):
  ```swift
  enum BarcodeFormat: String, CaseIterable { case code128, ean13, qr, aztec, pdf417 }
  extension LoyaltyCard {
      var format: BarcodeFormat? {
          get { barcodeFormat.flatMap(BarcodeFormat.init(rawValue:)) }
          set { barcodeFormat = newValue?.rawValue }
      }
  }
  ```
- **Ordering:** new card `sortOrder = (max existing sortOrder for the profile) + 1`.
- **CRUD via the sync seam:** create/update → `context.insert`/mutate + `context.save()` + `sync.enqueue(op: "upsert", entityType: .loyaltyCard, entity:)`; delete → set `deletedAt`/`updatedAt` + `save()` + `sync.enqueue(op: "delete", entityType: .loyaltyCard, entity:)`. Optimistic local-first; soft-delete tombstones; LWW. No new sync code.

---

## 4. Authoritative contract (single source of truth)

### 4.1 BarcodeRenderer (pure)
```swift
enum BarcodeRenderer {
    /// Returns a crisp, POS-grade barcode image for `value` in `format`, or nil when the
    /// value is invalid for the format / the format is unsupported (caller shows number-only).
    static func image(value: String, format: LoyaltyCard.BarcodeFormat, scale: CGFloat) -> UIImage?
}
```
- **Coverage & method:**
  - `code128`, `qr`, `pdf417`, `aztec` → CoreImage `CIFilter` generators (`CICode128BarcodeGenerator`, `CIQRCodeGenerator`, `CIPDF417BarcodeGenerator`, `CIAztecCodeGenerator`). Render `CIImage`, scale with **nearest-neighbor** (no interpolation), tint `#111` on `#fff`, include the generator's quiet zone (Code128 uses `quietSpace`).
  - `ean13` → a hand-rolled CoreGraphics renderer (also covers **UPC-A** = a 12-digit value rendered as EAN-13 with a leading `0`). Algorithm: normalize digits; validate/complete the mod-10 checksum; first digit selects the L/G parity table for the left 6; encode left guard `101`, left 6, center guard `01010`, right 6 (R-code), right guard `101`; draw modules into a `CGContext` with a fixed module width + ≥7-module quiet zone on each side, `#111` on `#fff`.
- **Validation → fallback (`nil`):** `ean13` requires 13 digits (or 12 for UPC-A) with a valid checksum; non-digit or wrong-length → `nil`. CoreImage formats: `nil` if the filter returns no image. Caller (detail view) renders number-only on `nil`.

### 4.2 Scan symbology mapping
`DataScannerViewController` recognized barcode → `(payloadStringValue, VNBarcodeSymbology)`. Map to `BarcodeFormat`:
`.code128 → .code128`, `.ean13 → .ean13` (Vision reports UPC-A as EAN-13 with a leading `0`, which the EAN-13 renderer handles), `.qr → .qr`, `.aztec → .aztec`, `.pdf417 → .pdf417`; any other symbology (e.g. `.upce`, `.ean8`) → `nil` — the number is still captured, format left nil → number-only display. Scan prefills `number` + `barcodeFormat`; **brand/colors are always chosen in the picker** (scan captures the code, not the brand).

### 4.3 Router & screens contract
- `Overlay` adds `.loyalty`, `.loyaltyAdd`, `.loyaltyCard(id: String)`; `id` strings: `"loyalty"`, `"loyaltyAdd"`, `"loyaltyCard-<id>"`. All three are full-screen (excluded from `sheetBinding`, rendered in `ShellView.overlay`, `.transition(.opacity)`, `.environment(\.accent, accent)`).
- Views (all under `Snapceipt/Features/Loyalty/`): `LoyaltyWalletView`, `AddLoyaltyView`, `LoyaltyCardDetailView`. Each is an `.accessibilityElement(children: .contain)` container carrying its screen id.

### 4.4 Accessibility IDs (added to `Snapceipt/Shared/AccessibilityID.swift`)
`homeQuickLoyalty = "home.quick.loyalty"`, `loyaltyWalletScreen = "loyalty.wallet.screen"`, `loyaltyCardRowPrefix = "loyalty.card.row."` (+ card id), `loyaltyWalletAdd = "loyalty.wallet.add"`, `loyaltyAddScreen = "loyalty.add.screen"`, `loyaltyAddScan = "loyalty.add.scan"`, `loyaltyAddBrandPrefix = "loyalty.add.brand."` (+ brand key), `loyaltyAddNumber = "loyalty.add.number"`, `loyaltyAddSave = "loyalty.add.save"`, `loyaltyDetailScreen = "loyalty.detail.screen"`, `loyaltyDetailBarcode = "loyalty.detail.barcode"`, `loyaltyDetailDone = "loyalty.detail.done"`.

### 4.5 Brand catalog (static)
`struct LoyaltyBrand { let key, name: String; let subBrand: String?; let color1, color2, monogram: String }`, a hardcoded array of the 9 AU brands plus a `Custom` path (user enters name; default neutral gradient or a color pick). Seed brands (key / name / subBrand / color1 / color2 / monogram):
- `everydayRewards` / "Everyday Rewards" / "Woolworths" / `#1A8A3C` / `#0C5C26` / "ER"
- `flybuys` / "flybuys" / "Coles" / `#1457C7` / `#0A2F86` / "fb"
- `myerOne` / "MYER one" / nil / `#2C2C2C` / `#000000` / "M"
- `sisterClub` / "Sister Club" / nil / `#D8467F` / `#A82C5E` / "SC"
- `qantasFF` / "Qantas FF" / nil / `#E40000` / `#A30000` / "Q"
- `velocity` / "Velocity" / nil / `#7A1FA2` / `#541570` / "V"
- `kmart` / "Kmart" / nil / `#E51937` / `#B0122A` / "K"
- `bws` / "BWS" / nil / `#0A7D3E` / `#06582B` / "B"
- `t2` / "T2 Tea" / nil / `#1A1A1A` / `#000000` / "T2"
(Note: where the prototype gave only `color1`, `color2` is a darker derivative; refine in the plan if desired.)

### 4.6 Scoping invariant
All loyalty queries + creates are scoped by the active `profileId` (never nil, never by `mode`/`type`). A business profile and a personal profile each keep their own wallet.

---

## 5. Barcode rendering & scanning (detail)

- **CoreImage:** one helper per filter; always disable interpolation when scaling (`CIContext` → `CGImage` → draw into a context with `interpolationQuality = .none`, or transform the CIImage by an integer scale before rasterizing). High contrast, no anti-aliasing on bar edges.
- **EAN-13 (hand-rolled):** deterministic and **unit-testable** — encode a known number and assert the exact module bit-string + computed checksum. Keep the renderer free of SwiftUI/SwiftData so it tests in isolation.
- **Scanner:** `LoyaltyBarcodeScanner: UIViewControllerRepresentable` wrapping `DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [...])], qualityLevel: .balanced, ...)` with a coordinator delegate → `onCapture(value:format:)`. Presented from the Add screen's "Scan" CTA. If the scanner is unavailable / permission denied → dismiss back to manual entry (no crash). Not exercised on the simulator (no camera) — manual device QA.
- **Brightness boost:** `ScreenBrightnessBoost` `ViewModifier` — `@State private var saved` captures `UIScreen.main.brightness` in `onAppear`, sets `1.0`; restores `saved` in `onDisappear`. Applied to `LoyaltyCardDetailView` only.

---

## 6. Screens

- **`LoyaltyWalletView` (`.loyalty`):** `LbHeader("Loyalty cards", onClose: dismiss, onAdd: → .loyaltyAdd)`; intro line "Tap a card to show its barcode at the checkout"; a scroll of brand-gradient card tiles (gradient `color1→color2`, brand/subBrand, `pointsLabel`, member number, a mini barcode ~40pt via `BarcodeRenderer` or stripes-fallback) tap → `.loyaltyCard(id:)`; `LbFloatingCTA("Add a card", a11yId: loyaltyWalletAdd)`; `EmptyArt` + "Add a card" when empty. Re-skins to the active profile accent (header `+`, CTA).
- **`AddLoyaltyView` (`.loyaltyAdd`):** `SheetHeader("Add a card")`; a dark **"Scan card barcode"** CTA (`loyaltyAddScan`) presenting `LoyaltyBarcodeScanner`; a brand **search field** + **picker grid** (9 brand tiles with monogram on brand color + a **Custom** tile; tiles carry `loyaltyAddBrandPrefix + key`); selecting a brand reveals the numeric **number field** (`loyaltyAddNumber`), prefilled if scanned; **"Add to wallet"** (`loyaltyAddSave`) disabled until a brand is chosen → `AddLoyaltyViewModel.save()` (create with `profileId` = active, brand/subBrand/color1/color2 from the picked brand, `number`, `barcodeFormat`) + enqueue → animated **success** (income-green `#1F9D6B` badge + check + "Card added!" + Done) → `dismissOverlay()` back to wallet.
- **`LoyaltyCardDetailView` (`.loyaltyCard(id:)`):** immersive full-screen using the **card's own** `color1→color2` linear gradient (NOT the profile accent); brand/subBrand title; a large white panel (`Radius` ~20, maxWidth ~320) with the **rendered barcode** (`loyaltyDetailBarcode`, ~120pt) or a number-only fallback block; member number (tabular-nums, letter-spacing); "Screen brightness boosted for scanning" note + `ScreenBrightnessBoost`; footer **Share** (`ShareLink` of the member number) + **Done** (`loyaltyDetailDone`).

---

## 7. View-models & file structure

New, under `Snapceipt/Features/Loyalty/`:
- `BarcodeFormat`/`LoyaltyCard.format` extension — `LoyaltyCard+Format.swift` (or in the renderer file).
- `BarcodeRenderer.swift` — pure renderer (§4.1).
- `LoyaltyBrand.swift` — static catalog (§4.5).
- `LoyaltyBarcodeScanner.swift` — `DataScannerViewController` representable + coordinator.
- `ScreenBrightnessBoost.swift` — view modifier.
- `LoyaltyWalletViewModel.swift` — `@Observable @MainActor`, injected `context/sync/userId/profileId`; `cards`, `reload()`, `delete(_:)`, `nextSortOrder`.
- `AddLoyaltyViewModel.swift` — form state (`selectedBrand`, custom name/colors, `number`, `scannedFormat`), `brands`, `save()`.
- `LoyaltyWalletView.swift`, `AddLoyaltyView.swift`, `LoyaltyCardDetailView.swift`.

Modified: `Snapceipt/App/Router.swift` (Overlay cases), `Snapceipt/App/RootView.swift` (Home quick action + overlay wiring), `Snapceipt/Shared/AccessibilityID.swift` (§4.4). XcodeGen globs new files automatically.

---

## 8. Error handling

- Camera permission denied / scanner unavailable → manual entry (scanner dismisses, no crash).
- Scanned barcode unsupported/unreadable → capture the value if present, leave `barcodeFormat` nil → number-only display.
- Barcode generation fails (invalid value for format) → number-only fallback; the card still opens.
- Empty wallet → `EmptyArt` first-run state.
- Saves are optimistic local-first; sync failures ride the existing outbox/retry — no bespoke UI.

---

## 9. Testing

- **Unit (Swift Testing):**
  - `BarcodeRenderer`: EAN-13 encoding vs known module patterns; mod-10 checksum (valid + invalid → `nil`); UPC-A leading-zero; each CoreImage format returns a non-nil image for valid input; unsupported/invalid → `nil`.
  - `VNBarcodeSymbology → BarcodeFormat` mapping.
  - `LoyaltyWalletViewModel`: create/delete, **profile-scoping** (cards for the active profile only), enqueue ops — in-memory `ModelContainer` + `MockSyncEngine`.
  - `AddLoyaltyViewModel.save`: brand prefill (brand/subBrand/colors), scanned format, enqueue upsert.
  - `LoyaltyBrand` catalog integrity (unique keys, valid hex).
- **UI (hermetic XCUITest, seeded):** seed ≥2 cards on the active profile (incl. one `ean13` + one `qr`). Home "Loyalty Card" quick action → wallet renders seeded cards → tap → detail shows the `loyaltyDetailBarcode` element → back → **manual add** (pick a brand → type number → save → success → new card in wallet) → delete a card. The scan CTA presence is asserted; the live scan is **manual device QA** (no simulator camera). Brightness not asserted (system-level).
- **Manual device QA:** real POS scan acceptance for rendered Code128/EAN-13/QR barcodes; the live `DataScannerViewController` scan-to-import.

---

## 10. Decisions log (brainstorm 2026-06-01)

1. **Barcode display coverage:** Full coverage — CoreImage for Code128/QR/PDF417/Aztec + a hand-rolled CoreGraphics EAN-13/UPC renderer; **no third-party dependency**; number-only fallback for invalid/proprietary.
2. **Add-card flow:** Scan-to-import (`DataScannerViewController` / Vision) **and** manual brand-pick + number.
3. **Scoping:** **Per-profile** (scope-by-`profileId`, like every other entity).
4. **Entry point:** A **Home "Loyalty Card" quick action** (star) → full-screen `.loyalty` overlay, matching the design-ref (`home.jsx`).
