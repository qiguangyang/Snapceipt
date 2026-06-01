# F4 — Loyalty Barcodes — iOS Implementation Plan

> **REQUIRED SUB-SKILL:** Execute this plan with **superpowers:subagent-driven-development**. Each task below is a self-contained, dependency-ordered unit: write the failing test, run it RED, implement (full code shown), run it GREEN, commit. Do not skip the RED step; do not weaken assertions to make a test pass.

**Goal:** Ship a per-profile loyalty/membership-card wallet you pull up at the checkout. Store branded cards and render a real, scannable barcode full-screen (`code128`/`qr`/`pdf417`/`aztec` via CoreImage + a hand-rolled `ean13`/UPC-A CoreGraphics renderer, number-only fallback otherwise), plus scan-to-import from a physical card via `DataScannerViewController`. iOS-only — no backend.

**Architecture:** F4 adds iOS UI + pure helpers only. The `loyalty_cards` D1 table, the `LoyaltyCard` `@Model`, `EntityType.loyaltyCard`, and `LoyaltyCardSyncMapper` already exist and round-trip via the generic `/sync/push`+`/sync/pull` (verified in `Snapceipt/Sync/SyncEntityRegistry.swift`). No new backend routes, no migration, no sync-mapper change. The `LoyaltyCard.init` keeps `barcodeFormat: String?` storage; a Swift enum + computed `format` bridge is *added* (storage stays `String?` for sync symmetry). Three full-screen `Overlay` cases (`.loyalty`, `.loyaltyAdd`, `.loyaltyCard(id:)`) are presented via `ShellView.overlay` and dismissed via `dismissOverlay()`, mirroring `.budgets`/`.budgetEditor`/`.alerts`. A Home "Loyalty Card" quick action (star icon) opens the wallet. Every loyalty query + create is scoped by the active `profileId` (never nil, never by `mode`/`type`). CRUD goes through the existing `SyncEnqueuing.enqueue(op:entityType:entity:)` seam (optimistic local-first, soft-delete tombstones, LWW).

**Tech Stack:** Swift 5.9+/iOS 17, SwiftUI, SwiftData (`@Model`, `FetchDescriptor`, `#Predicate`), Swift Testing (`@Suite`/`@Test`/`#expect`) for unit tests, XCUITest for hermetic UI tests, CoreImage (`CIFilter` barcode generators), CoreGraphics (hand-rolled EAN-13), VisionKit `DataScannerViewController` + `VNBarcodeSymbology`, UIKit `UIScreen.brightness`. Project files are globbed by XcodeGen — run `/opt/homebrew/bin/xcodegen generate` before every `xcodebuild` (and again after adding any new file). `NSCameraUsageDescription` already exists in `Snapceipt/Info.plist` (the capture flow primed it) — no plist change.

---

## File structure

### Created (all under `Snapceipt/Features/Loyalty/` unless noted)

| Path | Responsibility |
| --- | --- |
| `Snapceipt/Features/Loyalty/BarcodeFormat.swift` | `LoyaltyCard.BarcodeFormat` enum (`code128`/`ean13`/`qr`/`aztec`/`pdf417`) + `LoyaltyCard.format` computed bridge over the raw `String?` storage. |
| `Snapceipt/Features/Loyalty/BarcodeRenderer.swift` | Pure renderer: `BarcodeRenderer.image(value:format:scale:)` (CoreImage for `code128`/`qr`/`pdf417`/`aztec`, hand-rolled CoreGraphics EAN-13/UPC-A) + small pure helpers (`ean13CheckDigit`, `ean13Modules`) + `BarcodeFormat(symbology:)` mapping. No SwiftUI/SwiftData; no hidden time/Calendar. |
| `Snapceipt/Features/Loyalty/LoyaltyBrand.swift` | `LoyaltyBrand` struct + the static catalog (9 AU brands + a `Custom` path). |
| `Snapceipt/Features/Loyalty/LoyaltyWalletViewModel.swift` | `@Observable @MainActor`; injected `context/sync/userId/profileId`; `cards`, `reload()` (profile-scoped, sorted by `sortOrder` then `createdAt`), `delete(_:)`, `nextSortOrder`. |
| `Snapceipt/Features/Loyalty/AddLoyaltyViewModel.swift` | `@Observable @MainActor`; form state (`selectedBrand`, custom name/colors, `number`, `scannedFormat`), `brands`, `save()` (create + enqueue upsert). |
| `Snapceipt/Features/Loyalty/ScreenBrightnessBoost.swift` | `ViewModifier` capturing/restoring `UIScreen.main.brightness`. |
| `Snapceipt/Features/Loyalty/LoyaltyBarcodeScanner.swift` | `UIViewControllerRepresentable` over `DataScannerViewController` (barcode symbologies) → coordinator → `onCapture(value:format:)`. |
| `Snapceipt/Features/Loyalty/LoyaltyWalletView.swift` | Wallet list screen (`LbHeader`, brand-gradient tiles + mini barcode, `EmptyArt`, `LbFloatingCTA`). |
| `Snapceipt/Features/Loyalty/AddLoyaltyView.swift` | Add-card screen (`SheetHeader`, Scan CTA, brand search + picker grid + Custom, revealed number field, animated success). |
| `Snapceipt/Features/Loyalty/LoyaltyCardDetailView.swift` | Immersive detail (card gradient bg, rendered barcode panel / number-only fallback, member number, `ScreenBrightnessBoost`, `ShareLink` + Done). |
| `SnapceiptTests/BarcodeRendererTests.swift` | Unit tests for the renderer + format enum + symbology mapping + brand catalog. |
| `SnapceiptTests/LoyaltyViewModelTests.swift` | Unit tests for `LoyaltyWalletViewModel` + `AddLoyaltyViewModel`. |
| `SnapceiptUITests/LoyaltyUITests.swift` | Hermetic seeded UI test of the wallet → detail → manual add → delete flow. |

### Modified

| Path | Change |
| --- | --- |
| `Snapceipt/App/Router.swift` | Add `.loyalty`, `.loyaltyAdd`, `.loyaltyCard(id:)` `Overlay` cases + their `id` strings. |
| `Snapceipt/App/RootView.swift` | Add the Home "Loyalty Card" quick action; render the three loyalty overlays in `ShellView.overlay`; add the new cases to `sheetContent` (EmptyView arm) + the `sheetBinding`/`sheetContent` full-screen exclusion sets. |
| `Snapceipt/Shared/AccessibilityID.swift` | Add the §4.4 ids + `home.quick.loyalty`. |
| `Snapceipt/App/AppLaunch.swift` | Seed ≥2 loyalty cards on the active profile (incl. one `ean13` + one `qr`) under `-uiTestSeed`. |

XcodeGen globs new files automatically; **never `git add` the `.xcodeproj`** (xcodegen-generated + git-ignored).

---

## Conventions for every task

- **Build/test commands** (run from the repo root, absolute paths used by tools):
  - Regenerate the project before building, and again after adding any new file:
    ```
    /opt/homebrew/bin/xcodegen generate
    ```
  - Run a single unit suite (the `-only-testing` selector MUST use the Swift **type** name, never the `@Suite` display string):
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
    ```
  - Run a single UI suite:
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/LoyaltyUITests test
    ```
  - For views with no unit test, gate on a full build + the existing UI suite:
    ```
    xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
    ```
- **SourceKit file-level diagnostics are unreliable here** (no module context). Trust `xcodebuild` output only.
- **Commit each task.** End every commit message with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- **Baselines at planning time:** iOS unit **256**, UI **9** (1 LiveSmoke skip). Each task states the expected new per-suite counts; the final gate confirms the new totals.

---

## Task 1 — `BarcodeFormat` enum + `LoyaltyCard.format` computed bridge

**Files**
- Create: `Snapceipt/Features/Loyalty/BarcodeFormat.swift`
- Create (tests): `SnapceiptTests/BarcodeRendererTests.swift`

**Steps**

1. Write the failing test. Create `SnapceiptTests/BarcodeRendererTests.swift` with the format round-trip suite:
   ```swift
   import Testing
   import Foundation
   @testable import Snapceipt

   @Suite("BarcodeRenderer")
   struct BarcodeRendererTests {

       // MARK: - Task 1: BarcodeFormat enum + LoyaltyCard.format bridge

       @Test("BarcodeFormat raw values match the stored strings")
       func formatRawValues() {
           #expect(LoyaltyCard.BarcodeFormat.code128.rawValue == "code128")
           #expect(LoyaltyCard.BarcodeFormat.ean13.rawValue == "ean13")
           #expect(LoyaltyCard.BarcodeFormat.qr.rawValue == "qr")
           #expect(LoyaltyCard.BarcodeFormat.aztec.rawValue == "aztec")
           #expect(LoyaltyCard.BarcodeFormat.pdf417.rawValue == "pdf417")
           #expect(LoyaltyCard.BarcodeFormat.allCases.count == 5)
       }

       @Test("LoyaltyCard.format reads the raw barcodeFormat string")
       func formatGet() {
           let c = LoyaltyCard(userId: "u1", brand: "B", number: "12345",
                               barcodeFormat: "qr", color1: "#000000", color2: "#FFFFFF")
           #expect(c.format == .qr)
           let bad = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                                 barcodeFormat: "nope", color1: "#000000", color2: "#FFFFFF")
           #expect(bad.format == nil)
           let none = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                                  color1: "#000000", color2: "#FFFFFF")
           #expect(none.format == nil)
       }

       @Test("LoyaltyCard.format writes through to the raw barcodeFormat string")
       func formatSet() {
           let c = LoyaltyCard(userId: "u1", brand: "B", number: "1",
                               color1: "#000000", color2: "#FFFFFF")
           c.format = .ean13
           #expect(c.barcodeFormat == "ean13")
           c.format = nil
           #expect(c.barcodeFormat == nil)
       }
   }
   ```

2. Run it RED (the symbols don't exist yet):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect a compile failure (`LoyaltyCard.BarcodeFormat` unknown).

3. Implement. Create `Snapceipt/Features/Loyalty/BarcodeFormat.swift`:
   ```swift
   import Foundation

   extension LoyaltyCard {
       /// The five supported barcode symbologies. Raw values are the exact strings
       /// stored in `barcodeFormat` (and validated by the D1 CHECK server-side).
       enum BarcodeFormat: String, CaseIterable, Sendable {
           case code128
           case ean13
           case qr
           case aztec
           case pdf417
       }

       /// Typed view over the raw `barcodeFormat` storage. Storage stays `String?`
       /// for sync symmetry; this only bridges read/write to the enum.
       var format: BarcodeFormat? {
           get { barcodeFormat.flatMap(BarcodeFormat.init(rawValue:)) }
           set { barcodeFormat = newValue?.rawValue }
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect the 3 Task-1 tests passing.

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/BarcodeFormat.swift SnapceiptTests/BarcodeRendererTests.swift
   git commit -m "F4: LoyaltyCard.BarcodeFormat enum + format bridge

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = 256 + 3 = **259**.

---

## Task 2 — `BarcodeRenderer` CoreImage path (`code128`/`qr`/`pdf417`/`aztec`)

**Files**
- Create: `Snapceipt/Features/Loyalty/BarcodeRenderer.swift`
- Modify (tests): `SnapceiptTests/BarcodeRendererTests.swift`

**Steps**

1. Write the failing tests. Append to `BarcodeRendererTests` (inside the struct, after the Task-1 tests):
   ```swift
       // MARK: - Task 2: CoreImage generators

       @Test("each CoreImage format renders a non-nil image for a valid value")
       func coreImageNonNil() {
           for f: LoyaltyCard.BarcodeFormat in [.code128, .qr, .pdf417, .aztec] {
               let img = BarcodeRenderer.image(value: "ABC123456", format: f, scale: 4)
               #expect(img != nil, "expected an image for \(f.rawValue)")
               if let img { #expect(img.size.width > 0 && img.size.height > 0) }
           }
       }

       @Test("CoreImage formats return nil for an empty value")
       func coreImageEmptyNil() {
           for f: LoyaltyCard.BarcodeFormat in [.code128, .qr, .pdf417, .aztec] {
               #expect(BarcodeRenderer.image(value: "", format: f, scale: 4) == nil,
                       "expected nil for empty \(f.rawValue)")
           }
       }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect a compile failure (`BarcodeRenderer` unknown).

3. Implement. Create `Snapceipt/Features/Loyalty/BarcodeRenderer.swift` with the CoreImage path + an EAN-13 stub that returns nil for now (filled in Task 3):
   ```swift
   import UIKit
   import CoreImage
   import CoreImage.CIFilterBuiltins

   /// Pure barcode renderer. No SwiftUI/SwiftData, no hidden time/Calendar — every
   /// input is injected, so it is fully unit-testable. Returns a crisp, POS-grade
   /// image for `value` in `format`, or nil when the value is invalid for the format
   /// (the caller then shows a number-only fallback).
   enum BarcodeRenderer {

       /// Foreground/background: near-black `#111` bars on white.
       private static let foreground = CIColor(red: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0)
       private static let background = CIColor(red: 1, green: 1, blue: 1)

       static func image(value: String, format: LoyaltyCard.BarcodeFormat, scale: CGFloat) -> UIImage? {
           guard !value.isEmpty else { return nil }
           switch format {
           case .code128: return coreImage(value: value, generator: "CICode128BarcodeGenerator", scale: scale)
           case .qr:      return coreImage(value: value, generator: "CIQRCodeGenerator", scale: scale)
           case .pdf417:  return coreImage(value: value, generator: "CIPDF417BarcodeGenerator", scale: scale)
           case .aztec:   return coreImage(value: value, generator: "CIAztecCodeGenerator", scale: scale)
           case .ean13:   return ean13(value: value, scale: scale)   // filled in Task 3
           }
       }

       // MARK: - CoreImage

       private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

       /// Generate via a CIFilter, tint #111-on-#fff, then scale with NEAREST-NEIGHBOUR
       /// (integer transform before rasterizing) so bar edges stay hard.
       private static func coreImage(value: String, generator: String, scale: CGFloat) -> UIImage? {
           guard let data = value.data(using: .ascii) ?? value.data(using: .utf8),
                 let filter = CIFilter(name: generator) else { return nil }
           filter.setValue(data, forKey: "inputMessage")
           // Code128 exposes a quiet-zone control; the others include their own quiet zone.
           if generator == "CICode128BarcodeGenerator" {
               filter.setValue(7.0, forKey: "inputQuietSpace")
           }
           guard let output = filter.outputImage else { return nil }

           let tinted = tint(output)
           // Integer scale up first (no interpolation), then rasterize.
           let s = Swift.max(1, scale)
           let scaled = tinted.transformed(by: CGAffineTransform(scaleX: s, y: s))
           guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
           return UIImage(cgImage: cg, scale: 1, orientation: .up)
       }

       /// Map the generator's 1-bit output to #111 bars on a #fff background.
       private static func tint(_ image: CIImage) -> CIImage {
           let f = CIFilter.falseColor()
           f.inputImage = image
           f.color0 = background   // 0 -> white
           f.color1 = foreground   // 1 -> #111
           return f.outputImage ?? image
       }

       // MARK: - EAN-13 (filled in Task 3)

       static func ean13(value: String, scale: CGFloat) -> UIImage? { nil }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect the 2 new tests passing (5 total in the suite).

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/BarcodeRenderer.swift SnapceiptTests/BarcodeRendererTests.swift
   git commit -m "F4: BarcodeRenderer CoreImage path (code128/qr/pdf417/aztec)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **261**.

---

## Task 3 — `BarcodeRenderer` hand-rolled EAN-13 / UPC-A (CoreGraphics)

Tests assert **robust properties**, not a hand-typed 95-bit literal: (a) the mod-10 check digit against the known-valid EAN-13 `5901234123457` (check digit `7`); (b) the encoded module string is length 95, begins/ends with `101` guards and carries the `01010` centre guard; (c) invalid input (wrong length / non-digit / bad checksum) makes `image(...)` return `nil`; UPC-A = 12 digits rendered as EAN-13 with a leading `0`.

**Files**
- Modify: `Snapceipt/Features/Loyalty/BarcodeRenderer.swift`
- Modify (tests): `SnapceiptTests/BarcodeRendererTests.swift`

**Steps**

1. Write the failing tests. Append to `BarcodeRendererTests`:
   ```swift
       // MARK: - Task 3: EAN-13 / UPC-A

       @Test("mod-10 check digit for a known EAN-13 (5901234123457 -> 7)")
       func ean13CheckDigit() {
           // First 12 digits; the 13th (7) is the computed check digit.
           #expect(BarcodeRenderer.ean13CheckDigit("590123412345") == 7)
       }

       @Test("EAN-13 module string is 95 wide with guards and centre guard")
       func ean13ModuleString() {
           let mods = BarcodeRenderer.ean13Modules("5901234123457")
           #expect(mods != nil)
           guard let mods else { return }
           #expect(mods.count == 95)
           #expect(mods.hasPrefix("101"))   // left guard
           #expect(mods.hasSuffix("101"))   // right guard
           // Centre guard 01010 sits at indices 45..<50 (3 + 42 left modules).
           let centre = String(Array(mods)[45..<50])
           #expect(centre == "01010")
       }

       @Test("EAN-13 renders a non-nil image for a valid 13-digit value")
       func ean13ValidImage() {
           #expect(BarcodeRenderer.image(value: "5901234123457", format: .ean13, scale: 3) != nil)
       }

       @Test("UPC-A (12 digits) renders as EAN-13 with a leading zero")
       func upcAImage() {
           // 03600029145 + check 2 -> 12-digit UPC-A "036000291452".
           #expect(BarcodeRenderer.image(value: "036000291452", format: .ean13, scale: 3) != nil)
       }

       @Test("EAN-13 rejects wrong length, non-digit, and bad checksum -> nil")
       func ean13Invalid() {
           #expect(BarcodeRenderer.image(value: "123", format: .ean13, scale: 3) == nil)
           #expect(BarcodeRenderer.image(value: "59012341234A7", format: .ean13, scale: 3) == nil)
           #expect(BarcodeRenderer.image(value: "5901234123458", format: .ean13, scale: 3) == nil) // bad checksum
       }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect a compile failure (`ean13CheckDigit`/`ean13Modules` unknown).

3. Implement. Replace the EAN-13 stub in `BarcodeRenderer.swift`. Remove:
   ```swift
       static func ean13(value: String, scale: CGFloat) -> UIImage? { nil }
   ```
   and add the full EAN-13 section in its place:
   ```swift
       // MARK: - EAN-13 / UPC-A (hand-rolled)

       /// L-code (left, parity even) for digits 0-9 — 7 modules each.
       private static let lCode = [
           "0001101","0011001","0010011","0111101","0100011",
           "0110001","0101111","0111011","0110111","0001011",
       ]
       /// G-code (left, parity odd).
       private static let gCode = [
           "0100111","0110011","0011011","0100001","0011101",
           "0111001","0000101","0010001","0001001","0010111",
       ]
       /// R-code (right) — the complement of L-code.
       private static let rCode = [
           "1110010","1100110","1101100","1000010","1011100",
           "1001110","1010000","1000100","1001000","1110100",
       ]
       /// Parity pattern for the left 6 digits, selected by the first digit.
       private static let parity = [
           "LLLLLL","LLGLGG","LLGGLG","LLGGGL","LGLLGG",
           "LGGLLG","LGGGLL","LGLGLG","LGLGGL","LGGLGL",
       ]

       /// mod-10 check digit for the first 12 digits of an EAN-13 (odd positions ×1,
       /// even positions ×3, from the left, 0-indexed). Returns nil if not 12 digits.
       static func ean13CheckDigit(_ first12: String) -> Int? {
           let d = first12.compactMap { $0.wholeNumberValue }
           guard d.count == 12 else { return nil }
           var sum = 0
           for (i, n) in d.enumerated() { sum += (i % 2 == 0) ? n : n * 3 }
           return (10 - (sum % 10)) % 10
       }

       /// Normalize a raw value to a valid 13-digit EAN-13 string (UPC-A 12 digits get a
       /// leading 0; a 12-digit value is treated as first-12 + computed check). Returns
       /// nil for any non-digit / wrong-length / bad-checksum input.
       static func normalizedEAN13(_ raw: String) -> String? {
           let digits = raw.filter { $0.isNumber }
           guard digits.count == raw.count else { return nil }   // reject non-digit chars
           let value: String
           switch digits.count {
           case 13:
               value = digits
           case 12:
               // Ambiguous: a UPC-A (12) becomes EAN-13 with a leading 0. Validate as
               // a full 13 by prepending 0, then checking the embedded check digit.
               value = "0" + digits
           default:
               return nil
           }
           let first12 = String(value.prefix(12))
           let given = value.last!.wholeNumberValue!
           guard let check = ean13CheckDigit(first12), check == given else { return nil }
           return value
       }

       /// The 95-module bit string (1 = bar) for a valid 13-digit EAN-13 value, or nil.
       static func ean13Modules(_ value: String) -> String? {
           guard let v = normalizedEAN13(value) else { return nil }
           let d = v.compactMap { $0.wholeNumberValue }
           let pat = parity[d[0]]   // first digit picks the L/G pattern for the left 6
           var s = "101"            // left guard
           for i in 1...6 {
               s += (Array(pat)[i - 1] == "L") ? lCode[d[i]] : gCode[d[i]]
           }
           s += "01010"            // centre guard
           for i in 7...12 { s += rCode[d[i]] }
           s += "101"              // right guard
           return s
       }

       /// Draw the EAN-13 modules into a CGContext: fixed module width, #111 on #fff,
       /// with a >=7-module quiet zone each side. No interpolation (we draw exact rects).
       static func ean13(value: String, scale: CGFloat) -> UIImage? {
           guard let mods = ean13Modules(value) else { return nil }
           let module = Swift.max(1, scale)
           let quiet: CGFloat = 7 * module
           let width = quiet * 2 + CGFloat(mods.count) * module
           let height = CGFloat(80) * (module / 2)   // proportional, ~POS aspect
           let size = CGSize(width: width, height: Swift.max(40, height))

           let renderer = UIGraphicsImageRenderer(size: size)
           return renderer.image { ctx in
               let cg = ctx.cgContext
               cg.interpolationQuality = .none
               cg.setFillColor(UIColor.white.cgColor)
               cg.fill(CGRect(origin: .zero, size: size))
               cg.setFillColor(UIColor(red: 0x11/255.0, green: 0x11/255.0, blue: 0x11/255.0, alpha: 1).cgColor)
               var x = quiet
               for ch in mods {
                   if ch == "1" {
                       cg.fill(CGRect(x: x, y: 0, width: module, height: size.height))
                   }
                   x += module
               }
           }
       }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect the 5 new EAN-13 tests passing (10 total in the suite).

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/BarcodeRenderer.swift SnapceiptTests/BarcodeRendererTests.swift
   git commit -m "F4: hand-rolled EAN-13/UPC-A CoreGraphics renderer

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **266** (256 baseline + 10 in `BarcodeRendererTests`).

---

## Task 4 — `VNBarcodeSymbology` → `BarcodeFormat` mapping helper

**Files**
- Modify: `Snapceipt/Features/Loyalty/BarcodeRenderer.swift`
- Modify (tests): `SnapceiptTests/BarcodeRendererTests.swift`

**Steps**

1. Write the failing tests. Append to `BarcodeRendererTests` (Vision is available on the simulator):
   ```swift
       // MARK: - Task 4: VNBarcodeSymbology mapping

       @Test("supported VNBarcodeSymbology values map to BarcodeFormat")
       func symbologyMapping() {
           #expect(LoyaltyCard.BarcodeFormat(symbology: .code128) == .code128)
           #expect(LoyaltyCard.BarcodeFormat(symbology: .ean13) == .ean13)
           #expect(LoyaltyCard.BarcodeFormat(symbology: .qr) == .qr)
           #expect(LoyaltyCard.BarcodeFormat(symbology: .aztec) == .aztec)
           #expect(LoyaltyCard.BarcodeFormat(symbology: .pdf417) == .pdf417)
       }

       @Test("unsupported symbologies map to nil (value still captured)")
       func symbologyUnsupported() {
           #expect(LoyaltyCard.BarcodeFormat(symbology: .ean8) == nil)
           #expect(LoyaltyCard.BarcodeFormat(symbology: .upce) == nil)
       }
   ```
   Add `import Vision` to the test file's imports (top of `BarcodeRendererTests.swift`):
   ```swift
   import Vision
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect a compile failure (`init(symbology:)` unknown).

3. Implement. Add `import Vision` to the existing import block at the **top** of `BarcodeRenderer.swift` (next to `import UIKit` / `import CoreImage`), then append the Vision-mapping extension at the bottom of the file. (The `import Vision` shown in the snippet below is the one you add to the top block — do NOT leave an `import` mid-file.)
   ```swift
   import Vision   // <- add to the top import block, not here

   extension LoyaltyCard.BarcodeFormat {
       /// Map a Vision-recognized symbology to a supported BarcodeFormat. Vision reports
       /// UPC-A as `.ean13` with a leading 0 (the EAN-13 renderer handles that). Any other
       /// symbology (`.upce`, `.ean8`, …) returns nil — the number is still captured,
       /// `barcodeFormat` is left nil, and the detail view shows number-only.
       init?(symbology: VNBarcodeSymbology) {
           switch symbology {
           case .code128: self = .code128
           case .ean13:   self = .ean13
           case .qr:      self = .qr
           case .aztec:   self = .aztec
           case .pdf417:  self = .pdf417
           default:       return nil
           }
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/BarcodeRendererTests test
   ```
   Expect the 2 new tests passing (12 total in the suite).

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/BarcodeRenderer.swift SnapceiptTests/BarcodeRendererTests.swift
   git commit -m "F4: VNBarcodeSymbology -> BarcodeFormat mapping

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **268** (256 baseline + 12 in `BarcodeRendererTests`).

---

## Task 5 — `LoyaltyBrand` static catalog

**Files**
- Create: `Snapceipt/Features/Loyalty/LoyaltyBrand.swift`
- Modify (tests): `SnapceiptTests/BarcodeRendererTests.swift`

**Steps**

1. Write the failing tests. Append a new suite to `BarcodeRendererTests.swift` (top-level, after the closing brace of `BarcodeRendererTests`):
   ```swift
   @Suite("LoyaltyBrand")
   struct LoyaltyBrandTests {
       @Test("catalog has the 9 seed brands and unique keys")
       func uniqueKeys() {
           let keys = LoyaltyBrand.catalog.map(\.key)
           #expect(keys.count == 9)
           #expect(Set(keys).count == keys.count)
           #expect(keys.contains("everydayRewards"))
           #expect(keys.contains("flybuys"))
       }

       @Test("every catalog brand has valid 6-hex colors")
       func validHex() {
           func isHex6(_ s: String) -> Bool {
               guard s.hasPrefix("#") else { return false }
               let body = s.dropFirst()
               return body.count == 6 && UInt32(body, radix: 16) != nil
           }
           for b in LoyaltyBrand.catalog {
               #expect(isHex6(b.color1), "bad color1 for \(b.key)")
               #expect(isHex6(b.color2), "bad color2 for \(b.key)")
               #expect(!b.name.isEmpty)
               #expect(!b.monogram.isEmpty)
           }
       }

       @Test("the custom brand is a distinct neutral path")
       func customBrand() {
           let c = LoyaltyBrand.custom
           #expect(c.key == "custom")
           #expect(LoyaltyBrand.catalog.contains(where: { $0.key == "custom" }) == false)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/LoyaltyBrandTests test
   ```
   Expect a compile failure (`LoyaltyBrand` unknown).

3. Implement. Create `Snapceipt/Features/Loyalty/LoyaltyBrand.swift`:
   ```swift
   import SwiftUI

   /// A static loyalty-brand template. Picking one prefills brand/subBrand/colors on a
   /// new card. `Custom` lets the user type a name (neutral gradient default).
   struct LoyaltyBrand: Identifiable, Equatable {
       let key: String
       let name: String
       let subBrand: String?
       let color1: String   // hex "#RRGGBB"
       let color2: String   // hex "#RRGGBB"
       let monogram: String

       var id: String { key }

       /// SwiftUI colors parsed from the stored hex strings (same convention as ProfilesStore).
       var c1: Color { Color(hex: LoyaltyBrand.hex(color1)) }
       var c2: Color { Color(hex: LoyaltyBrand.hex(color2)) }

       static func hex(_ s: String) -> UInt32 {
           UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
       }

       /// The 9 seed AU brands (spec §4.5).
       static let catalog: [LoyaltyBrand] = [
           LoyaltyBrand(key: "everydayRewards", name: "Everyday Rewards", subBrand: "Woolworths",
                        color1: "#1A8A3C", color2: "#0C5C26", monogram: "ER"),
           LoyaltyBrand(key: "flybuys", name: "flybuys", subBrand: "Coles",
                        color1: "#1457C7", color2: "#0A2F86", monogram: "fb"),
           LoyaltyBrand(key: "myerOne", name: "MYER one", subBrand: nil,
                        color1: "#2C2C2C", color2: "#000000", monogram: "M"),
           LoyaltyBrand(key: "sisterClub", name: "Sister Club", subBrand: nil,
                        color1: "#D8467F", color2: "#A82C5E", monogram: "SC"),
           LoyaltyBrand(key: "qantasFF", name: "Qantas FF", subBrand: nil,
                        color1: "#E40000", color2: "#A30000", monogram: "Q"),
           LoyaltyBrand(key: "velocity", name: "Velocity", subBrand: nil,
                        color1: "#7A1FA2", color2: "#541570", monogram: "V"),
           LoyaltyBrand(key: "kmart", name: "Kmart", subBrand: nil,
                        color1: "#E51937", color2: "#B0122A", monogram: "K"),
           LoyaltyBrand(key: "bws", name: "BWS", subBrand: nil,
                        color1: "#0A7D3E", color2: "#06582B", monogram: "B"),
           LoyaltyBrand(key: "t2", name: "T2 Tea", subBrand: nil,
                        color1: "#1A1A1A", color2: "#000000", monogram: "T2"),
       ]

       /// The Custom path — a neutral dark gradient; name is supplied by the user.
       static let custom = LoyaltyBrand(key: "custom", name: "Custom", subBrand: nil,
                                        color1: "#3A3A3A", color2: "#1A1A1A", monogram: "+")
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/LoyaltyBrandTests test
   ```
   Expect the 3 brand tests passing.

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/LoyaltyBrand.swift SnapceiptTests/BarcodeRendererTests.swift
   git commit -m "F4: LoyaltyBrand static catalog (9 AU brands + Custom)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **271** (256 baseline + 12 in `BarcodeRendererTests` + 3 in `LoyaltyBrandTests`).

---

## Task 6 — `LoyaltyWalletViewModel`

Mirrors `BudgetListViewModel`: `@Observable @MainActor`, injected `context/sync/userId/profileId`, profile-scoped `reload()` sorted by `sortOrder` then `createdAt`, soft-delete + enqueue, `nextSortOrder`.

**Files**
- Create: `Snapceipt/Features/Loyalty/LoyaltyWalletViewModel.swift`
- Create (tests): `SnapceiptTests/LoyaltyViewModelTests.swift`

**Steps**

1. Write the failing tests. Create `SnapceiptTests/LoyaltyViewModelTests.swift`:
   ```swift
   import Testing
   import Foundation
   import SwiftData
   @testable import Snapceipt

   @MainActor
   @Suite("LoyaltyWalletViewModel")
   struct LoyaltyWalletViewModelTests {
       private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           return (ModelContext(container), MockSyncEngine())
       }

       private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> LoyaltyWalletViewModel {
           LoyaltyWalletViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
       }

       private func insertCard(_ ctx: ModelContext, profileId: String, sortOrder: Int,
                               createdAt: Int = Epoch.nowMs()) {
           ctx.insert(LoyaltyCard(userId: "u1", profileId: profileId, brand: "B-\(sortOrder)",
                                  number: "123", color1: "#000000", color2: "#FFFFFF",
                                  sortOrder: sortOrder, createdAt: createdAt))
       }

       @Test("reload returns only the active profile's non-deleted cards, sorted")
       func reloadScopedSorted() throws {
           let (ctx, sync) = try makeFixture()
           insertCard(ctx, profileId: "p1", sortOrder: 1)
           insertCard(ctx, profileId: "p1", sortOrder: 0)
           insertCard(ctx, profileId: "p2", sortOrder: 0)   // other profile — excluded
           try ctx.save()
           let v = vm(ctx, sync)
           #expect(v.cards.count == 2)
           #expect(v.cards.allSatisfy { $0.profileId == "p1" })
           #expect(v.cards[0].sortOrder == 0)   // sorted by sortOrder asc
           #expect(v.cards[1].sortOrder == 1)
       }

       @Test("delete soft-deletes (excluded from reload) and enqueues a delete")
       func deleteSoft() throws {
           let (ctx, sync) = try makeFixture()
           insertCard(ctx, profileId: "p1", sortOrder: 0)
           try ctx.save()
           let v = vm(ctx, sync)
           let card = v.cards[0]
           v.delete(card)
           #expect(v.cards.isEmpty)
           #expect(card.deletedAt != nil)
           #expect(sync.calls.last?.op == "delete")
           #expect(sync.calls.last?.entityType == .loyaltyCard)
       }

       @Test("nextSortOrder is max existing + 1 for the active profile")
       func nextSortOrder() throws {
           let (ctx, sync) = try makeFixture()
           insertCard(ctx, profileId: "p1", sortOrder: 2)
           insertCard(ctx, profileId: "p1", sortOrder: 5)
           insertCard(ctx, profileId: "p2", sortOrder: 9)   // other profile — ignored
           try ctx.save()
           let v = vm(ctx, sync)
           #expect(v.nextSortOrder() == 6)
       }

       @Test("nextSortOrder is 0 for an empty wallet")
       func nextSortOrderEmpty() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           #expect(v.nextSortOrder() == 0)
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/LoyaltyWalletViewModelTests test
   ```
   Expect a compile failure (`LoyaltyWalletViewModel` unknown).

3. Implement. Create `Snapceipt/Features/Loyalty/LoyaltyWalletViewModel.swift`:
   ```swift
   import Foundation
   import SwiftData
   import Observation

   /// Drives the loyalty wallet. Loads the active profile's live cards (sorted by
   /// sortOrder then createdAt), soft-deletes through the sync seam. `@MainActor`;
   /// deps injected for tests. Mirrors BudgetListViewModel.
   @Observable
   @MainActor
   final class LoyaltyWalletViewModel {
       @ObservationIgnored private let context: ModelContext
       @ObservationIgnored private let sync: any SyncEnqueuing
       @ObservationIgnored private let userId: String
       @ObservationIgnored let profileId: String

       /// Active profile's live loyalty cards.
       private(set) var cards: [LoyaltyCard] = []

       init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
           self.context = context
           self.sync = sync
           self.userId = userId
           self.profileId = profileId
           reload()
       }

       func reload() {
           let pid = profileId
           let d = FetchDescriptor<LoyaltyCard>(
               predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
               sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
           cards = (try? context.fetch(d)) ?? []
       }

       /// Soft-delete (set deletedAt) + enqueue a delete.
       func delete(_ card: LoyaltyCard) {
           card.deletedAt = Epoch.nowMs()
           card.updatedAt = Epoch.nowMs()
           try? context.save()
           reload()
           sync.enqueue(op: "delete", entityType: .loyaltyCard, entity: card)
       }

       /// New card sortOrder = (max existing sortOrder for the profile) + 1, else 0.
       func nextSortOrder() -> Int {
           (cards.map(\.sortOrder).max().map { $0 + 1 }) ?? 0
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/LoyaltyWalletViewModelTests test
   ```
   Expect the 4 tests passing.

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/LoyaltyWalletViewModel.swift SnapceiptTests/LoyaltyViewModelTests.swift
   git commit -m "F4: LoyaltyWalletViewModel (profile-scoped reload + delete)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **275** (256 baseline + 12 + 3 + 4 in `LoyaltyWalletViewModelTests`).

---

## Task 7 — `AddLoyaltyViewModel`

Form state + brands + `save()` (create `LoyaltyCard` with `profileId` = active, brand/subBrand/color1/color2 from the picked brand, `number`, `barcodeFormat`) + enqueue upsert. `nextSortOrder` is supplied at call time so the VM stays decoupled from the wallet list.

**Files**
- Create: `Snapceipt/Features/Loyalty/AddLoyaltyViewModel.swift`
- Modify (tests): `SnapceiptTests/LoyaltyViewModelTests.swift`

**Steps**

1. Write the failing tests. Append a new suite to `SnapceiptTests/LoyaltyViewModelTests.swift` (top-level, after `LoyaltyWalletViewModelTests`):
   ```swift
   @MainActor
   @Suite("AddLoyaltyViewModel")
   struct AddLoyaltyViewModelTests {
       private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
           let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
           return (ModelContext(container), MockSyncEngine())
       }

       private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> AddLoyaltyViewModel {
           AddLoyaltyViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
       }

       @Test("brands exposes the catalog plus the custom path")
       func brandsExposed() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           #expect(v.brands.count == LoyaltyBrand.catalog.count + 1)
           #expect(v.brands.last?.key == "custom")
       }

       @Test("not savable until a brand is selected")
       func canSave() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           #expect(v.canSave == false)
           v.selectedBrand = LoyaltyBrand.catalog.first
           #expect(v.canSave == true)
       }

       @Test("save creates a card scoped to the active profile with brand fields + enqueues upsert")
       func saveCreates() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           let brand = LoyaltyBrand.catalog.first { $0.key == "everydayRewards" }!
           v.selectedBrand = brand
           v.number = "9352999000000"
           v.scannedFormat = .ean13
           let saved = v.save(sortOrder: 3)
           #expect(saved != nil)
           let rows = try ctx.fetch(FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.deletedAt == nil }))
           #expect(rows.count == 1)
           let row = rows[0]
           #expect(row.profileId == "p1")
           #expect(row.brand == "Everyday Rewards")
           #expect(row.subBrand == "Woolworths")
           #expect(row.color1 == "#1A8A3C")
           #expect(row.color2 == "#0C5C26")
           #expect(row.number == "9352999000000")
           #expect(row.barcodeFormat == "ean13")
           #expect(row.sortOrder == 3)
           #expect(sync.calls.count == 1)
           #expect(sync.calls[0].op == "upsert")
           #expect(sync.calls[0].entityType == .loyaltyCard)
       }

       @Test("custom brand uses the typed name + neutral colors")
       func saveCustom() throws {
           let (ctx, sync) = try makeFixture()
           let v = vm(ctx, sync)
           v.selectedBrand = LoyaltyBrand.custom
           v.customName = "Local Cafe"
           v.number = "AB-2299"
           let saved = v.save(sortOrder: 0)
           #expect(saved != nil)
           let row = try ctx.fetch(FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.deletedAt == nil }))[0]
           #expect(row.brand == "Local Cafe")
           #expect(row.subBrand == nil)
           #expect(row.barcodeFormat == nil)   // no scanned format
       }
   }
   ```

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AddLoyaltyViewModelTests test
   ```
   Expect a compile failure (`AddLoyaltyViewModel` unknown).

3. Implement. Create `Snapceipt/Features/Loyalty/AddLoyaltyViewModel.swift`:
   ```swift
   import Foundation
   import SwiftData
   import Observation

   /// Drives the add-card form. Brand pick (catalog + Custom) prefills brand/subBrand/
   /// colors; scan prefills number + format. `save(sortOrder:)` creates the card scoped
   /// to the active profile and enqueues an upsert. `@MainActor`; deps injected for tests.
   @Observable
   @MainActor
   final class AddLoyaltyViewModel {
       @ObservationIgnored private let context: ModelContext
       @ObservationIgnored private let sync: any SyncEnqueuing
       @ObservationIgnored private let userId: String
       @ObservationIgnored let profileId: String

       /// Catalog brands + the Custom path, in pick order.
       let brands: [LoyaltyBrand] = LoyaltyBrand.catalog + [LoyaltyBrand.custom]

       var selectedBrand: LoyaltyBrand?
       var customName: String = ""
       var number: String = ""
       var scannedFormat: LoyaltyCard.BarcodeFormat?
       var search: String = ""

       init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
           self.context = context
           self.sync = sync
           self.userId = userId
           self.profileId = profileId
       }

       /// Catalog filtered by the search text (Custom always shown).
       var filteredBrands: [LoyaltyBrand] {
           let q = search.trimmingCharacters(in: .whitespaces).lowercased()
           guard !q.isEmpty else { return brands }
           return brands.filter { $0.key == "custom" || $0.name.lowercased().contains(q) }
       }

       /// Savable once a brand is chosen (Custom also requires a non-empty name).
       var canSave: Bool {
           guard let b = selectedBrand else { return false }
           if b.key == "custom" { return !customName.trimmingCharacters(in: .whitespaces).isEmpty }
           return true
       }

       /// Create the card (profileId = active) + enqueue an upsert. Returns the new row,
       /// or nil if not savable.
       @discardableResult
       func save(sortOrder: Int) -> LoyaltyCard? {
           guard canSave, let b = selectedBrand else { return nil }
           let isCustom = b.key == "custom"
           let card = LoyaltyCard(
               userId: userId,
               profileId: profileId,
               brand: isCustom ? customName.trimmingCharacters(in: .whitespaces) : b.name,
               subBrand: isCustom ? nil : b.subBrand,
               number: number.trimmingCharacters(in: .whitespaces),
               barcodeFormat: scannedFormat?.rawValue,
               color1: b.color1,
               color2: b.color2,
               sortOrder: sortOrder)
           context.insert(card)
           try? context.save()
           sync.enqueue(op: "upsert", entityType: .loyaltyCard, entity: card)
           return card
       }
   }
   ```

4. Run it GREEN:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/AddLoyaltyViewModelTests test
   ```
   Expect the 4 tests passing.

5. Commit:
   ```
   git add Snapceipt/Features/Loyalty/AddLoyaltyViewModel.swift SnapceiptTests/LoyaltyViewModelTests.swift
   git commit -m "F4: AddLoyaltyViewModel (brand prefill + save + enqueue)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite count after this task:** `SnapceiptTests` = **279** (256 baseline + 12 + 3 + 4 + 4 in `AddLoyaltyViewModelTests`).

---

## Task 8 — `AccessibilityID` additions

**Files**
- Modify: `Snapceipt/Shared/AccessibilityID.swift`

No unit test (a pure constant list). Gate on a full build.

**Steps**

1. Implement. Add the §4.4 ids. Append after the `profileRowBudgets` line, before the closing `}` of `enum AccessibilityID`:
   ```swift

       // Home quick action (F4)
       static let homeQuickLoyalty = "home.quick.loyalty"

       // Loyalty (F4)
       static let loyaltyWalletScreen = "loyalty.wallet.screen"
       static let loyaltyCardRowPrefix = "loyalty.card.row."     // + card.id
       static let loyaltyWalletAdd = "loyalty.wallet.add"
       static let loyaltyAddScreen = "loyalty.add.screen"
       static let loyaltyAddScan = "loyalty.add.scan"
       static let loyaltyAddBrandPrefix = "loyalty.add.brand."   // + brand.key
       static let loyaltyAddNumber = "loyalty.add.number"
       static let loyaltyAddSave = "loyalty.add.save"
       static let loyaltyDetailScreen = "loyalty.detail.screen"
       static let loyaltyDetailBarcode = "loyalty.detail.barcode"
       static let loyaltyDetailDone = "loyalty.detail.done"
   ```

2. Run the build (this file compiles into both targets):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/Shared/AccessibilityID.swift
   git commit -m "F4: accessibility ids for loyalty + home quick action

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 9 — `ScreenBrightnessBoost` ViewModifier

Build-only (system-level brightness; not unit/UI asserted).

**Files**
- Create: `Snapceipt/Features/Loyalty/ScreenBrightnessBoost.swift`

**Steps**

1. Implement. Create `Snapceipt/Features/Loyalty/ScreenBrightnessBoost.swift`:
   ```swift
   import SwiftUI
   import UIKit

   /// Maxes screen brightness on appear (so a barcode scans at the POS) and restores
   /// the captured value on disappear. Applied to the loyalty card detail screen only.
   struct ScreenBrightnessBoost: ViewModifier {
       @State private var saved: CGFloat?

       func body(content: Content) -> some View {
           content
               .onAppear {
                   if saved == nil { saved = UIScreen.main.brightness }
                   UIScreen.main.brightness = 1.0
               }
               .onDisappear {
                   if let saved { UIScreen.main.brightness = saved }
               }
       }
   }

   extension View {
       /// Boost screen brightness to max while this view is visible.
       func screenBrightnessBoost() -> some View { modifier(ScreenBrightnessBoost()) }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/Features/Loyalty/ScreenBrightnessBoost.swift
   git commit -m "F4: ScreenBrightnessBoost view modifier

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 10 — `LoyaltyBarcodeScanner` (DataScannerViewController representable)

Build-only (no simulator camera). `DataScannerViewController` is iOS 16+; the app targets iOS 17 so it is available. If unavailable / permission denied, the host dismisses back to manual entry (no crash).

**Files**
- Create: `Snapceipt/Features/Loyalty/LoyaltyBarcodeScanner.swift`

**Steps**

1. Implement. Create `Snapceipt/Features/Loyalty/LoyaltyBarcodeScanner.swift`:
   ```swift
   import SwiftUI
   import VisionKit
   import Vision

   /// Wraps `DataScannerViewController` to scan a single loyalty barcode. On a recognized
   /// barcode it calls `onCapture(value:format:)` (format nil for unsupported symbologies —
   /// the value is still captured). The host presents this from the Add screen's Scan CTA;
   /// when the scanner is unavailable / permission denied, the host shows manual entry.
   struct LoyaltyBarcodeScanner: UIViewControllerRepresentable {
       let onCapture: (_ value: String, _ format: LoyaltyCard.BarcodeFormat?) -> Void

       /// Whether the device + permission support live scanning.
       static var isAvailable: Bool {
           DataScannerViewController.isSupported && DataScannerViewController.isAvailable
       }

       func makeUIViewController(context: Context) -> DataScannerViewController {
           let vc = DataScannerViewController(
               recognizedDataTypes: [.barcode(symbologies: [.code128, .ean13, .qr, .aztec, .pdf417])],
               qualityLevel: .balanced,
               recognizesMultipleItems: false,
               isHighFrameRateTrackingEnabled: false,
               isPinchToZoomEnabled: true,
               isGuidanceEnabled: true,
               isHighlightingEnabled: true)
           vc.delegate = context.coordinator
           try? vc.startScanning()
           return vc
       }

       func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

       func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

       final class Coordinator: NSObject, DataScannerViewControllerDelegate {
           let onCapture: (_ value: String, _ format: LoyaltyCard.BarcodeFormat?) -> Void
           private var didCapture = false
           init(onCapture: @escaping (String, LoyaltyCard.BarcodeFormat?) -> Void) {
               self.onCapture = onCapture
           }

           func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                            allItems: [RecognizedItem]) {
               handle(addedItems)
           }

           func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
               handle([item])
           }

           private func handle(_ items: [RecognizedItem]) {
               guard !didCapture else { return }
               for item in items {
                   if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                       didCapture = true
                       let format = LoyaltyCard.BarcodeFormat(symbology: barcode.observation.symbology)
                       onCapture(value, format)
                       return
                   }
               }
           }
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`. The symbology accessor `barcode.observation.symbology` is **verified against the SDK** in this repo: `RecognizedItem.Barcode.observation` is typed `Vision.VNBarcodeObservation` (VisionKit `.swiftinterface`), and `VNBarcodeObservation.symbology` is a `VNBarcodeSymbology` (`Vision/VNObservation.h`). Do NOT change the public `onCapture` mapping API. If a future SDK ever renamed the accessor, the only allowed change is the single `barcode.observation.symbology` expression — keep the `LoyaltyCard.BarcodeFormat(symbology:)` mapping and the closure signature intact.

3. Commit:
   ```
   git add Snapceipt/Features/Loyalty/LoyaltyBarcodeScanner.swift
   git commit -m "F4: LoyaltyBarcodeScanner (DataScannerViewController representable)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 11 — Router overlay cases + keep RootView compiling

Add the three full-screen `Overlay` cases and their id strings. RootView must keep compiling: add the new cases to `sheetContent` (EmptyView arm) + the `sheetBinding`/`sheetContent` full-screen exclusion sets, exactly mirroring `.budgets`/`.budgetEditor`/`.alerts`. (The actual overlay *rendering* in `ShellView.overlay` lands in Task 15, after the views exist.)

**Files**
- Modify: `Snapceipt/App/Router.swift`
- Modify: `Snapceipt/App/RootView.swift`

No unit test (the Router exposes no new testable helper here). Gate on a full build + the existing UI suite.

**Steps**

1. Implement the Router cases. In `Snapceipt/App/Router.swift`, add the three cases to the `Overlay` enum after `case alerts`:
   ```swift
       case alerts
       case notificationSettings
       case loyalty
       case loyaltyAdd
       case loyaltyCard(id: String)
   ```
   And add their `id` strings to the `var id` switch (after the `notificationSettings` arm):
   ```swift
           case .notificationSettings: return "notificationSettings"
           case .loyalty: return "loyalty"
           case .loyaltyAdd: return "loyaltyAdd"
           case .loyaltyCard(let id): return "loyaltyCard-\(id)"
   ```

2. Keep RootView compiling. In `Snapceipt/App/RootView.swift`:

   a. Add the new cases to the `sheetBinding` getter's full-screen `switch` (so they are never presented as a sheet). Change:
   ```swift
                   case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings:
                       return nil
   ```
   to:
   ```swift
                   case .capture, .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                        .loyalty, .loyaltyAdd, .loyaltyCard:
                       return nil
   ```

   b. Add the non-associated-value loyalty ids to the `sheetBinding` setter's `fullScreen` Set, and exclude the associated-value `.loyaltyCard` by prefix (mirroring `.budgetEditor`). Change:
   ```swift
               let fullScreen: Set<String> = [Overlay.capture.id, Overlay.mileage.id, Overlay.wfh.id,
                                              Overlay.budgets.id, Overlay.alerts.id,
                                              Overlay.notificationSettings.id]
               if newValue == nil, let cur = router.overlay,
                  !fullScreen.contains(cur.id), !cur.id.hasPrefix("budgetEditor") {
   ```
   to:
   ```swift
               let fullScreen: Set<String> = [Overlay.capture.id, Overlay.mileage.id, Overlay.wfh.id,
                                              Overlay.budgets.id, Overlay.alerts.id,
                                              Overlay.notificationSettings.id,
                                              Overlay.loyalty.id, Overlay.loyaltyAdd.id]
               if newValue == nil, let cur = router.overlay,
                  !fullScreen.contains(cur.id),
                  !cur.id.hasPrefix("budgetEditor"), !cur.id.hasPrefix("loyaltyCard") {
   ```

   c. Add the new cases to the `sheetContent(for:)` EmptyView arm. Change:
   ```swift
           case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings:
               EmptyView()  // handled by the full-screen overlays
   ```
   to:
   ```swift
           case .mileage, .wfh, .budgets, .budgetEditor, .alerts, .notificationSettings,
                .loyalty, .loyaltyAdd, .loyaltyCard:
               EmptyView()  // handled by the full-screen overlays
   ```

3. Build + run the existing UI suite (no behavior change yet, just exhaustive-switch compilation):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/BudgetsUITests test
   ```
   Expect `BUILD SUCCEEDED` and BudgetsUITests green.

4. Commit:
   ```
   git add Snapceipt/App/Router.swift Snapceipt/App/RootView.swift
   git commit -m "F4: Router loyalty overlay cases + RootView exhaustive arms

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 12 — `LoyaltyWalletView`

`LbHeader`, branded card tiles (gradient `color1→color2`, brand/subBrand, `pointsLabel`, member number, mini barcode ~40pt via `BarcodeRenderer` or a stripes fallback), `EmptyArt` empty state, `LbFloatingCTA`. Build-only here (covered by the UI test in Task 17).

**Files**
- Create: `Snapceipt/Features/Loyalty/LoyaltyWalletView.swift`

**Steps**

1. Implement. Create `Snapceipt/Features/Loyalty/LoyaltyWalletView.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Full-screen loyalty wallet: LbHeader, brand-gradient card tiles with a mini
   /// barcode, member number + points; tap -> detail; LbFloatingCTA + EmptyArt.
   /// Re-skins the header `+` / CTA to the active profile accent.
   struct LoyaltyWalletView: View {
       let context: ModelContext
       let sync: any SyncEnqueuing
       let userId: String
       let profileId: String
       let onClose: () -> Void
       let onAdd: () -> Void
       let onOpenCard: (String) -> Void

       @Environment(\.accent) private var accent
       @State private var vm: LoyaltyWalletViewModel?

       var body: some View {
           ZStack(alignment: .bottom) {
               Palette.cream.ignoresSafeArea()
               VStack(spacing: 0) {
                   LbHeader(title: "Loyalty cards", onClose: onClose, onAdd: onAdd)
                   if let vm {
                       if vm.cards.isEmpty {
                           Spacer()
                           EmptyArt()
                           Text("No cards yet").font(.ui(15)).foregroundStyle(Palette.ink3)
                               .padding(.top, 6)
                           Spacer()
                       } else {
                           ScrollView {
                               Text("Tap a card to show its barcode at the checkout")
                                   .font(.ui(13)).foregroundStyle(Palette.ink2)
                                   .frame(maxWidth: .infinity, alignment: .leading)
                                   .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
                               LazyVStack(spacing: 14) {
                                   ForEach(vm.cards) { card in
                                       Button { onOpenCard(card.id) } label: { tile(card) }
                                           .buttonStyle(.plain)
                                           .accessibilityIdentifier(AccessibilityID.loyaltyCardRowPrefix + card.id)
                                   }
                               }
                               .padding(.horizontal, 18)
                               .padding(.bottom, 110)
                           }
                       }
                   } else { Color.clear }
               }
               LbFloatingCTA(title: "Add a card", a11yId: AccessibilityID.loyaltyWalletAdd, action: onAdd)
           }
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.loyaltyWalletScreen)
           .transition(.opacity)
           .task {
               vm = LoyaltyWalletViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
           }
       }

       @ViewBuilder private func tile(_ card: LoyaltyCard) -> some View {
           let c1 = Color(hex: LoyaltyBrand.hex(card.color1))
           let c2 = Color(hex: LoyaltyBrand.hex(card.color2))
           VStack(alignment: .leading, spacing: 12) {
               HStack(alignment: .top) {
                   VStack(alignment: .leading, spacing: 2) {
                       Text(card.brand).font(.ui(16, .bold)).foregroundStyle(.white)
                       if let sub = card.subBrand {
                           Text(sub).font(.ui(12, .semibold)).foregroundStyle(.white.opacity(0.85))
                       }
                   }
                   Spacer()
                   if let label = card.pointsLabel {
                       Text(label).font(.ui(12, .semibold)).foregroundStyle(.white)
                           .padding(.vertical, 4).padding(.horizontal, 10)
                           .background(Color.white.opacity(0.2), in: Capsule())
                   }
               }
               miniBarcode(card)
                   .frame(height: 40)
                   .frame(maxWidth: .infinity)
                   .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
               Text(card.number).font(.ui(13, .semibold)).monospacedDigit()
                   .foregroundStyle(.white.opacity(0.95))
                   .lineLimit(1)
           }
           .padding(16)
           .background(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
           .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
           .shadow(color: c2.opacity(0.4), radius: 12, x: 0, y: 10)
       }

       /// A small rendered barcode (or evenly-spaced stripes when rendering fails).
       @ViewBuilder private func miniBarcode(_ card: LoyaltyCard) -> some View {
           if let f = card.format, let img = BarcodeRenderer.image(value: card.number, format: f, scale: 2) {
               Image(uiImage: img)
                   .interpolation(.none)
                   .resizable()
                   .aspectRatio(contentMode: .fit)
                   .padding(.horizontal, 8).padding(.vertical, 4)
           } else {
               HStack(spacing: 2) {
                   ForEach(0..<28, id: \.self) { i in
                       Rectangle().fill(Palette.ink.opacity(i % 3 == 0 ? 0.9 : 0.45))
                           .frame(width: i % 4 == 0 ? 3 : 1.5)
                   }
               }
               .frame(maxWidth: .infinity)
               .padding(.horizontal, 8)
           }
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/Features/Loyalty/LoyaltyWalletView.swift
   git commit -m "F4: LoyaltyWalletView (branded tiles + mini barcode + empty state)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 13 — `AddLoyaltyView`

`SheetHeader`, dark Scan CTA presenting the scanner, brand search + picker grid + Custom, revealed numeric number field (prefilled if scanned), "Add to wallet" disabled-until-brand, animated success → `onSaved()`.

**Files**
- Create: `Snapceipt/Features/Loyalty/AddLoyaltyView.swift`

**Steps**

1. Implement. Create `Snapceipt/Features/Loyalty/AddLoyaltyView.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Full-screen add-loyalty-card overlay. Scan CTA presents the live scanner (prefills
   /// number + format); a searchable brand grid (catalog + Custom) reveals the number
   /// field; Add-to-wallet is disabled until a brand is chosen. Save -> create + enqueue
   /// -> animated success -> onSaved (back to the wallet).
   struct AddLoyaltyView: View {
       let context: ModelContext
       let sync: any SyncEnqueuing
       let userId: String
       let profileId: String
       let onClose: () -> Void
       let onSaved: () -> Void

       @Environment(\.accent) private var accent
       @State private var vm: AddLoyaltyViewModel?
       @State private var showScanner = false
       @State private var saved = false

       private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

       var body: some View {
           ZStack(alignment: .bottom) {
               Palette.cream.ignoresSafeArea()
               VStack(spacing: 0) {
                   SheetHeader(title: "Add a card", onClose: onClose)
                   if let vm { content(vm) } else { Color.clear }
               }
               if let vm { saveBar(vm) }
               if saved { successOverlay }
           }
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.loyaltyAddScreen)
           .transition(.opacity)
           .task { if vm == nil { vm = AddLoyaltyViewModel(context: context, sync: sync, userId: userId, profileId: profileId) } }
           .sheet(isPresented: $showScanner) {
               if LoyaltyBarcodeScanner.isAvailable {
                   LoyaltyBarcodeScanner { value, format in
                       vm?.number = value
                       vm?.scannedFormat = format
                       showScanner = false
                   }
                   .ignoresSafeArea()
               } else {
                   // No camera (e.g. simulator) -> dismiss back to manual entry, no crash.
                   Color.clear.onAppear { showScanner = false }
               }
           }
       }

       @ViewBuilder private func content(_ vm: AddLoyaltyViewModel) -> some View {
           ScrollView {
               VStack(alignment: .leading, spacing: 16) {
                   scanButton
                   TextField("Search brands", text: Binding(get: { vm.search }, set: { vm.search = $0 }))
                       .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                   LazyVGrid(columns: columns, spacing: 12) {
                       ForEach(vm.filteredBrands) { brand in
                           brandTile(brand, selected: vm.selectedBrand?.key == brand.key) {
                               vm.selectedBrand = brand
                           }
                       }
                   }
                   if vm.selectedBrand?.key == "custom" {
                       field("Brand name", text: Binding(get: { vm.customName }, set: { vm.customName = $0 }))
                   }
                   if vm.selectedBrand != nil {
                       numberField(vm)
                   }
               }
               .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 120)
           }
       }

       private var scanButton: some View {
           Button { showScanner = true } label: {
               HStack(spacing: 8) {
                   Icon(name: "camera", size: 18, color: .white)
                   Text("Scan card barcode").font(.ui(15, .semibold)).foregroundStyle(.white)
               }
               .frame(maxWidth: .infinity, minHeight: 50)
               .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
           }
           .buttonStyle(.plain)
           .accessibilityIdentifier(AccessibilityID.loyaltyAddScan)
       }

       @ViewBuilder private func brandTile(_ brand: LoyaltyBrand, selected: Bool, action: @escaping () -> Void) -> some View {
           Button(action: action) {
               VStack(spacing: 6) {
                   ZStack {
                       RoundedRectangle(cornerRadius: 12, style: .continuous)
                           .fill(LinearGradient(colors: [brand.c1, brand.c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                       Text(brand.monogram).font(.ui(18, .bold)).foregroundStyle(.white)
                   }
                   .frame(height: 54)
                   Text(brand.name).font(.ui(11.5, .semibold)).foregroundStyle(Palette.ink2)
                       .lineLimit(1)
               }
               .padding(6)
               .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
               .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                   .strokeBorder(selected ? accent.base : Palette.line2, lineWidth: selected ? 2 : 1))
           }
           .buttonStyle(.plain)
           .accessibilityIdentifier(AccessibilityID.loyaltyAddBrandPrefix + brand.key)
       }

       @ViewBuilder private func numberField(_ vm: AddLoyaltyViewModel) -> some View {
           VStack(alignment: .leading, spacing: 4) {
               Text("Member number").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
               TextField("Number", text: Binding(get: { vm.number }, set: { vm.number = $0 }))
                   .keyboardType(.numbersAndPunctuation)
                   .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
                   .accessibilityIdentifier(AccessibilityID.loyaltyAddNumber)
           }
       }

       private func field(_ title: String, text: Binding<String>) -> some View {
           VStack(alignment: .leading, spacing: 4) {
               Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
               TextField(title, text: text)
                   .padding(12).background(Palette.paper, in: RoundedRectangle(cornerRadius: 12))
           }
       }

       @ViewBuilder private func saveBar(_ vm: AddLoyaltyViewModel) -> some View {
           Button {
               // sortOrder = end of the current wallet for this profile.
               let wallet = LoyaltyWalletViewModel(context: context, sync: sync, userId: userId, profileId: profileId)
               if vm.save(sortOrder: wallet.nextSortOrder()) != nil {
                   withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { saved = true }
                   DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onSaved() }
               }
           } label: {
               Text("Add to wallet").font(.ui(16, .semibold)).foregroundStyle(.white)
                   .frame(maxWidth: .infinity, minHeight: 52)
                   .background(vm.canSave ? accent.base : Palette.ink3,
                               in: RoundedRectangle(cornerRadius: 16, style: .continuous))
           }
           .buttonStyle(.plain)
           .disabled(!vm.canSave)
           .padding(.horizontal, 18).padding(.bottom, 26)
           .accessibilityIdentifier(AccessibilityID.loyaltyAddSave)
       }

       private var successOverlay: some View {
           ZStack {
               Palette.cream.opacity(0.96).ignoresSafeArea()
               VStack(spacing: 14) {
                   ZStack {
                       Circle().fill(Palette.income).frame(width: 72, height: 72)
                       Icon(name: "check", size: 34, color: .white, lineWidth: 3)
                   }
                   Text("Card added!").font(.display(20, .bold)).foregroundStyle(Palette.ink)
               }
           }
           .transition(.opacity)
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/Features/Loyalty/AddLoyaltyView.swift
   git commit -m "F4: AddLoyaltyView (scan CTA + brand grid + number + success)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 14 — `LoyaltyCardDetailView`

Immersive full-screen using the card's own `color1→color2` gradient (NOT the profile accent); rendered barcode panel (`loyaltyDetailBarcode`) or number-only fallback; member number (tabular-nums); `ScreenBrightnessBoost`; footer `ShareLink` (of the member number) + Done (`loyaltyDetailDone`).

**Files**
- Create: `Snapceipt/Features/Loyalty/LoyaltyCardDetailView.swift`

**Steps**

1. Implement. Create `Snapceipt/Features/Loyalty/LoyaltyCardDetailView.swift`:
   ```swift
   import SwiftUI
   import SwiftData

   /// Immersive loyalty-card detail: the card's own gradient fills the screen, a white
   /// panel shows the rendered barcode (or a number-only fallback), member number, a
   /// brightness boost for scanning, and Share (member number) + Done. The card is
   /// fetched by id; if missing, the view dismisses.
   struct LoyaltyCardDetailView: View {
       let context: ModelContext
       let cardId: String
       let onClose: () -> Void

       @State private var card: LoyaltyCard?

       var body: some View {
           ZStack {
               if let card {
                   let c1 = Color(hex: LoyaltyBrand.hex(card.color1))
                   let c2 = Color(hex: LoyaltyBrand.hex(card.color2))
                   LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)
                       .ignoresSafeArea()
                   VStack(spacing: 18) {
                       header(card)
                       Spacer()
                       barcodePanel(card)
                       Text(card.number).font(.display(18, .bold)).monospacedDigit()
                           .kerning(1.5).foregroundStyle(.white)
                       Text("Screen brightness boosted for scanning")
                           .font(.ui(12)).foregroundStyle(.white.opacity(0.8))
                       Spacer()
                       footer(card)
                   }
                   .padding(.horizontal, 24).padding(.vertical, 30)
               } else {
                   Palette.cream.ignoresSafeArea()
               }
           }
           .accessibilityElement(children: .contain)
           .accessibilityIdentifier(AccessibilityID.loyaltyDetailScreen)
           .transition(.opacity)
           .screenBrightnessBoost()
           .task { load() }
       }

       private func header(_ card: LoyaltyCard) -> some View {
           VStack(spacing: 2) {
               Text(card.brand).font(.display(24, .bold)).foregroundStyle(.white)
               if let sub = card.subBrand {
                   Text(sub).font(.ui(13, .semibold)).foregroundStyle(.white.opacity(0.85))
               }
           }
           .padding(.top, 30)
       }

       @ViewBuilder private func barcodePanel(_ card: LoyaltyCard) -> some View {
           ZStack {
               RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white)
               if let f = card.format, let img = BarcodeRenderer.image(value: card.number, format: f, scale: 6) {
                   Image(uiImage: img)
                       .interpolation(.none)
                       .resizable()
                       .aspectRatio(contentMode: .fit)
                       .padding(20)
               } else {
                   // Number-only fallback (proprietary / unsupported / invalid).
                   Text(card.number).font(.display(22, .bold)).monospacedDigit()
                       .foregroundStyle(Palette.ink).padding(24)
               }
           }
           .frame(maxWidth: 320)
           .frame(height: 160)
           .accessibilityIdentifier(AccessibilityID.loyaltyDetailBarcode)
       }

       private func footer(_ card: LoyaltyCard) -> some View {
           HStack(spacing: 12) {
               ShareLink(item: card.number) {
                   HStack(spacing: 6) {
                       Icon(name: "arrowRight", size: 16, color: .white)
                       Text("Share").font(.ui(15, .semibold)).foregroundStyle(.white)
                   }
                   .frame(maxWidth: .infinity, minHeight: 48)
                   .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
               }
               Button(action: onClose) {
                   Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                       .frame(maxWidth: .infinity, minHeight: 48)
                       .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
               }
               .buttonStyle(.plain)
               .accessibilityIdentifier(AccessibilityID.loyaltyDetailDone)
           }
       }

       private func load() {
           let id = cardId
           var d = FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil })
           d.fetchLimit = 1
           card = (try? context.fetch(d))?.first
       }
   }
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/Features/Loyalty/LoyaltyCardDetailView.swift
   git commit -m "F4: LoyaltyCardDetailView (immersive barcode + brightness + share)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 15 — RootView wiring: Home quick action + the three overlays

Add the Home "Loyalty Card" quick action (icon `star`, id `home.quick.loyalty`) presenting `.loyalty`; render the three loyalty overlays in `ShellView.overlay` with `.environment(\.accent, accent)` + `.transition(.opacity)`. Confirm `BUILD SUCCEEDED` and the existing UI suite stays green (shell.home / profile.switcher unaffected).

**Files**
- Modify: `Snapceipt/App/RootView.swift`

**Steps**

1. Add the Home quick action. The current `homeStub` lays out Mileage + WFH in a single `HStack` of two. Add a third tile below them (a one-tile row keeps the layout legible). In `homeStub`, after the existing quick-action `HStack` block (the one ending `.padding(.horizontal, 18).padding(.top, 14)`), insert:
   ```swift
                   HStack(spacing: 12) {
                       quickAction(title: "Loyalty Card", icon: "star", id: AccessibilityID.homeQuickLoyalty,
                                   accent: accent) { router.present(.loyalty) }
                   }
                   .padding(.horizontal, 18).padding(.top, 12)
   ```

2. Render the three overlays. After the existing `.overlay { if router.overlay == .notificationSettings { … } }` block in `ShellView.body`, add three new overlays:
   ```swift
           .overlay {
               if router.overlay == .loyalty {
                   LoyaltyWalletView(context: profiles.context, sync: sync, userId: profiles.userId,
                                     profileId: profiles.activeProfileId,
                                     onClose: { router.dismissOverlay() },
                                     onAdd: { router.present(.loyaltyAdd) },
                                     onOpenCard: { router.present(.loyaltyCard(id: $0)) })
                       .environment(\.accent, accent).transition(.opacity)
               }
           }
           .overlay {
               if router.overlay == .loyaltyAdd {
                   AddLoyaltyView(context: profiles.context, sync: sync, userId: profiles.userId,
                                  profileId: profiles.activeProfileId,
                                  onClose: { router.dismissOverlay() },
                                  onSaved: { router.present(.loyalty) })
                       .environment(\.accent, accent).transition(.opacity)
               }
           }
           .overlay {
               if case let .loyaltyCard(id) = router.overlay {
                   LoyaltyCardDetailView(context: profiles.context, cardId: id,
                                         onClose: { router.dismissOverlay() })
                       .environment(\.accent, accent).transition(.opacity)
               }
           }
   ```
   Notes: the Add screen's success routes to `.loyalty` (back to the wallet) via `onSaved`; the wallet tile tap routes to `.loyaltyCard(id:)`; the detail Done dismisses to Home. All three are already excluded from `sheetBinding` (Task 11), so the only presenter is `ShellView.overlay`.

3. Build + run the affected existing UI suites (confirm Home + shell unaffected):
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/BudgetsUITests test
   ```
   Expect `BUILD SUCCEEDED` and BudgetsUITests green.

4. Commit:
   ```
   git add Snapceipt/App/RootView.swift
   git commit -m "F4: wire Home Loyalty quick action + render the 3 loyalty overlays

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 16 — Seed loyalty cards in `AppLaunch.applySeedIfNeeded`

Seed ≥2 cards on the active profile (p1) incl. one `ean13` + one `qr`, for the UI test. Build-only.

**Files**
- Modify: `Snapceipt/App/AppLaunch.swift`

**Steps**

1. Implement. In `applySeedIfNeeded(authStore:context:)`, just before the final `try? context.save()`, add the loyalty seed:
   ```swift
           // F4: seed loyalty cards on p1 (active under -uiTestSeed): one EAN-13 + one QR.
           context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                      brand: "Everyday Rewards", subBrand: "Woolworths",
                                      number: "5901234123457", barcodeFormat: "ean13",
                                      pointsLabel: "1,240 pts",
                                      color1: "#1A8A3C", color2: "#0C5C26", sortOrder: 0))
           context.insert(LoyaltyCard(userId: DevAccount.userId, profileId: p1.id,
                                      brand: "Qantas FF", subBrand: nil,
                                      number: "QF1234567", barcodeFormat: "qr",
                                      pointsLabel: nil,
                                      color1: "#E40000", color2: "#A30000", sortOrder: 1))
   ```

2. Build:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build
   ```
   Expect `BUILD SUCCEEDED`.

3. Commit:
   ```
   git add Snapceipt/App/AppLaunch.swift
   git commit -m "F4: seed loyalty cards (ean13 + qr) for the UI test

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** unchanged (279 / 9).

---

## Task 17 — Hermetic UI test `LoyaltyUITests`

Mirror `BudgetsUITests` + `UITestCase/launchSeeded`: Home loyalty quick action → wallet shows seeded cards → tap → detail shows `loyalty.detail.barcode` → back → manual add (pick brand → number → save → success → new card in wallet) → delete. Assert the scan CTA exists but drive the MANUAL path (no simulator camera). Use the F3 a11y-container handling (`app.descendants(matching: .any)[id]`) so child ids resolve.

**Files**
- Create: `SnapceiptUITests/LoyaltyUITests.swift`

**Steps**

1. Write the test. Create `SnapceiptUITests/LoyaltyUITests.swift`:
   ```swift
   import XCTest

   /// Hermetic loyalty wallet flow: seeded shell + stub API (no network, no camera).
   /// Home quick action -> wallet shows seeded cards -> tap -> detail barcode -> back ->
   /// manual add (pick brand -> number -> save -> success -> new card) -> delete a card.
   /// The Scan CTA presence is asserted; the live scan is manual device QA (no simulator
   /// camera), so this drives the MANUAL add path only.
   final class LoyaltyUITests: UITestCase {
       func testWalletDetailManualAddAndDelete() {
           launchSeeded()   // signed-in, business profile p1 active, seeded loyalty cards

           // Home loyalty quick action -> wallet.
           let quick = app.buttons[AccessibilityID.homeQuickLoyalty].firstMatch
           XCTAssertTrue(quick.waitForExistence(timeout: 10), "Loyalty quick action missing on Home")
           quick.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 5),
                         "Loyalty wallet did not appear")

           // Seeded cards render (>=1 row).
           let firstCard = app.descendants(matching: .any).matching(NSPredicate(
               format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix)).firstMatch
           XCTAssertTrue(firstCard.waitForExistence(timeout: 5), "No seeded loyalty card rendered")

           // Tap a card -> detail shows the barcode element.
           firstCard.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailScreen].waitForExistence(timeout: 5),
                         "Loyalty detail did not appear")
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyDetailBarcode].waitForExistence(timeout: 5),
                         "Detail barcode element missing")
           // Back to the wallet.
           app.buttons[AccessibilityID.loyaltyDetailDone].firstMatch.tap()
           // Done dismisses to Home; re-open the wallet for the add flow.
           XCTAssertTrue(quick.waitForExistence(timeout: 5), "Did not return to Home")
           quick.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 5),
                         "Wallet did not reappear")

           // Add a card via the floating CTA -> add screen.
           app.buttons[AccessibilityID.loyaltyWalletAdd].firstMatch.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyAddScreen].waitForExistence(timeout: 5),
                         "Add screen did not appear")
           // The Scan CTA must exist (manual QA drives the live scan).
           XCTAssertTrue(app.buttons[AccessibilityID.loyaltyAddScan].firstMatch.waitForExistence(timeout: 5),
                         "Scan CTA missing")
           // Pick a brand (flybuys).
           let brand = app.buttons[AccessibilityID.loyaltyAddBrandPrefix + "flybuys"].firstMatch
           XCTAssertTrue(brand.waitForExistence(timeout: 5), "flybuys brand tile missing")
           brand.tap()
           // Type a member number (revealed after brand pick).
           let number = app.textFields[AccessibilityID.loyaltyAddNumber]
           XCTAssertTrue(number.waitForExistence(timeout: 5), "Number field missing")
           number.tap(); number.typeText("6011000990139424")
           // The keyboard covers the bottom-pinned Save bar. Dismiss it by tapping the
           // always-on-screen header title "Add a card" (same pattern as BudgetsUITests
           // tapping "Period"), then Save.
           app.staticTexts["Add a card"].firstMatch.tap()
           // Save -> success -> back to the wallet.
           let save = app.buttons[AccessibilityID.loyaltyAddSave]
           XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button missing")
           save.tap()
           XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.loyaltyWalletScreen].waitForExistence(timeout: 8),
                         "Did not return to wallet after save")

           // Delete: the v1 wallet (§6) renders tappable tiles with NO swipe/long-press
           // delete affordance, so there is no UI delete to drive here. Soft-delete +
           // enqueue("delete") is fully covered by LoyaltyWalletViewModelTests.deleteSoft
           // (unit). This UI test therefore proves the manual-add CRUD path end-to-end and
           // confirms at least one card row still renders after the add.
           let anyCard = app.descendants(matching: .any).matching(NSPredicate(
               format: "identifier BEGINSWITH %@", AccessibilityID.loyaltyCardRowPrefix)).firstMatch
           XCTAssertTrue(anyCard.waitForExistence(timeout: 5), "No loyalty card row after add")
       }
   }
   ```
   Note: delete is fully covered by `LoyaltyWalletViewModelTests.deleteSoft` (unit). If a delete affordance is added to the wallet UI later (swipe / context menu), extend this test to drive it; for v1 the UI test asserts the wallet still renders rows after the manual add.

2. Run it RED:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/LoyaltyUITests test
   ```
   It should fail only if a wiring bug exists; if everything from Tasks 12–16 is correct it may pass first run. If it fails, debug with `superpowers:systematic-debugging` (do NOT weaken assertions). Common gotchas: the keyboard covering Save (tap a neutral static text like the "Search brands" placeholder area or `loyalty.add.screen` chrome to dismiss before tapping Save), and a11y-container child resolution (always use `app.descendants(matching: .any)[id]` for screen ids).

3. Run it GREEN:
   ```
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/LoyaltyUITests test
   ```
   Expect the suite passing.

4. Commit:
   ```
   git add SnapceiptUITests/LoyaltyUITests.swift
   git commit -m "F4: hermetic LoyaltyUITests (wallet -> detail -> manual add)

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   ```

**Expected suite counts after this task:** `SnapceiptUITests` = 9 + 1 = **10** (1 LiveSmoke skip).

---

## Task 18 — Full-suite green gate

**Files**
- None (verification only).

**Steps**

1. Regenerate + run both full suites:
   ```
   /opt/homebrew/bin/xcodegen generate
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests test
   xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests test
   ```
2. Confirm totals:
   - `SnapceiptTests` = **279** (256 baseline + 12 in `BarcodeRendererTests` + 3 in `LoyaltyBrandTests` + 4 in `LoyaltyWalletViewModelTests` + 4 in `AddLoyaltyViewModelTests` = 256 + 23 = 279).
   - `SnapceiptUITests` = **10** (9 baseline + `LoyaltyUITests`, with the 1 LiveSmoke skip).
3. If any suite is red, fix the implementation (use `superpowers:systematic-debugging`); do not weaken assertions.
4. No new commit needed unless a fix was applied; if so, commit it with the standard trailer.

**Expected final suite counts:** `SnapceiptTests` **279**, `SnapceiptUITests` **10** (1 skip).

---

## Correctness reminders baked into this plan

- `BarcodeRenderer` is **pure** — no SwiftUI/SwiftData, no hidden `Date()`/`Calendar.current`; all inputs (`value`, `format`, `scale`) injected. EAN-13 logic is split into testable pure helpers (`ean13CheckDigit`, `ean13Modules`, `normalizedEAN13`) so the test asserts robust properties, not a hand-typed 95-bit literal.
- Every loyalty **query + create is scoped by the active `profileId`** (never nil, never by `mode`/`type`): `LoyaltyWalletViewModel.reload`/`nextSortOrder` filter by `profileId`; `AddLoyaltyViewModel.save` always sets `profileId = profileId`; the detail view fetches by `id` only after the wallet (already scoped) handed it that id.
- `LoyaltyCard.init` keeps **required `color1`/`color2`** and `barcodeFormat: String?`. The plan only ADDS the computed `format` bridge; storage stays `String?`.
- The Home `quickAction(title:icon:id:accent:action:)` call matches the RootView signature exactly (`star` icon, `home.quick.loyalty` id).
- New overlays are added to **both** `sheetContent` (EmptyView arm) **and** the `sheetBinding` exclusion sets (non-associated ids in the `Set`, `.loyaltyCard` via `hasPrefix("loyaltyCard")`), exactly mirroring `.budgetEditor`.
- `ShareLink` shares the **member number string** (`card.number`).
- `DataScannerViewController` is iOS 16+; the app targets iOS 17, so it is available. The scanner host degrades to manual entry when `LoyaltyBarcodeScanner.isAvailable` is false (e.g. the simulator), with no crash.
