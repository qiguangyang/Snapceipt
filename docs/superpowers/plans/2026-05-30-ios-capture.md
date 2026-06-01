# Receipt Capture (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship Plan B of the receipt-capture feature — the iOS side of snap → on-device OCR → AI extraction → review/edit → save a `Transaction` (+`LineItem`s) that syncs, plus a size-reduced receipt-image upload to R2. AUD-only. The full designed 4-stage flow (Camera → Scan → Review → Saved), an on-device heuristic fallback when extraction is unavailable, two offline queues (image upload + re-extract reconciler), and a hermetic camera-less XCUITest.

**Architecture:** Smart backend / thin client. All extraction logic lives in `POST /extract` (Plan A). The iOS client owns: lifting the VisionKit/Vision capture primitives out of root `ReceiptScanner.swift`; an `ImageReducer`; the `APIClient.extract` + `APIClient.uploadImage` network calls; an `@Observable @MainActor CaptureViewModel` stage machine with injected dependencies; the pure `ExtractedReceipt → Transaction(+LineItem)` mapping; a local-only `PendingReceipt @Model`; a `ReceiptUploadQueue`; a `PendingExtractionReconciler`; the 4 SwiftUI steps + `CaptureFlow`; and the `RootView` Snap-tab wiring with a `-uiTestStub` canned-image seam. SwiftUI + SwiftData + Observation, local-first, mirroring the existing foundation patterns.

**Tech Stack:** Swift 5.10, iOS 17+, SwiftUI, SwiftData, Observation; Vision + VisionKit; Swift Testing (`import Testing`); XCUITest; XcodeGen (`project.yml`) → `Snapceipt.xcodeproj`; build/test via `xcodebuild ... -destination "platform=iOS Simulator,name=iPhone 16"`.

**Spec:** `docs/superpowers/specs/2026-05-30-receipt-capture-extraction-design.md` (§5, §6, §7, §8, §9 AUTHORITATIVE, §11, §12, §13). Reuses root `ReceiptScanner.swift` (lifted, then deleted). Backend contract this app calls: §9 of the spec + Plan A (`POST /extract`, `POST /images`).

---

## Canonical Contracts

**These shapes/names are authoritative (spec §9). Every task reconciles to them; where a task body disagrees, this section wins.**

### Routes called (root-mounted, no `/v1`)
- `POST /extract` — auth; JSON body. Request: `{ ocrText (req), source ("scan"|"email_in", req), defaultCurrency? ("AUD"), locale? ("en-AU"), capturedAt? ("YYYY-MM-DD"), requestId? }`. iOS always sends `defaultCurrency:"AUD"`, `locale:"en-AU"`, and a generated `requestId`.
- `POST /images` — auth; raw `image/jpeg` body; **all metadata as URL query params**: `transactionId?`, `pageIndex` (default 0, omitted by iOS), `width?`, `height?`, `ocrText?` (omitted by iOS in v1). iOS sends `transactionId`, `width`, `height`.

### `/extract` response (all amounts are DOLLARS on the wire)
```jsonc
{
  "requestId": "...",
  "receipt": {
    "merchant": "The Grounds",
    "date": "2026-05-28",            // YYYY-MM-DD
    "currencyCode": "AUD",
    "total": 42.50,                  // number (DOLLARS), >= 0
    "gst": 3.86,                     // number|null; non-null whenever total>0
    "category": "meals",             // EXACTLY one of the 9 keys; Codable key is `category`
    "deductible": 50,                // 0..100 | null
    "lineItems": [ { "name": "Flat White x2", "price": 9.00 } ],
    "confidence": 0.98,              // 0..1
    "needsReview": false
  },
  "meta": { "model": "deepseek-chat", "source": "scan", "latencyMs": 812, "attempts": 1, "stub": false }
}
```

### `/images` response
```jsonc
{ "imageKey": "u/{userId}/{uuid}.jpg", "getUrl": "/images/u/{userId}/{uuid}.jpg", "byteSize": 124213 }
```

### Field-mapping table (wire → iOS draft `ExtractedReceipt` → entity `Transaction`/`LineItem`)
| wire (`response.receipt`) | iOS draft (`ExtractedReceipt`) | entity |
|---|---|---|
| `merchant` | `merchant` | `Transaction.merchant` |
| `date` (YYYY-MM-DD) | `date: String` | `Transaction.txnDate` |
| `total` (dollars ≥0) | `total: Decimal` | `amountCents = round(total*100)`, **negated unless `categoryKey=="income"`** |
| `gst` (dollars, non-null iff total>0) | `gst: Decimal?` | `gstCents = gst==nil ? nil : round(gst*100)` |
| `category` (1 of 9 keys; Codable key **`category`**) | `categoryKey: String` | `Transaction.catKey` |
| `deductible` (0..100\|null) | `deductible: Int?` | `Transaction.deductiblePct` (1:1, null→null) |
| `lineItems[].name`/`.price` | `lineItems: [(name,price)]` | `LineItem.name` / `priceCents=round(price*100)`, `sortOrder=index`, `quantity=1` |
| `confidence` / `needsReview` | same | (not persisted; drive badge/banner) |
| — | `paymentMethod: String?` | `Transaction.paymentMethod` |
| — | `taxLabel: String?` | `Transaction.taxLabel` |
| — | `extractionStatus: String` ("done"\|"pending") | `Transaction.extractionStatus` |

### Pinned rules
- **9 category keys** (`CategoryKey` raw values = `Snapceipt/Model/Categories.swift` `CATS`): `meals, groceries, fuel, software, office, home, health, travel, income`. `income` is the only positive-amount key.
- **Sign:** `total >= 0` always; `amountCents = round(total*100)` then negate unless `categoryKey == "income"`.
- **GST nullability:** `gst == nil → gstCents = nil`; otherwise `gstCents = round(gst*100)`. On a 200 the server guarantees `gst` non-null whenever `total>0` (§9). The **offline heuristic path also honors this**: `HeuristicParser.parse` (Task 1) retains the `else if result.total > 0 { result.tax = roundedGST(result.total) }` branch, so a heuristic draft with `total>0` and no explicit GST line still carries `gst = round(total/11)` (only `total == 0` yields `gst = nil`). Do not remove that branch.
- **`mode`:** `Transaction.mode ∈ {"personal","business"}` (lowercase, from the active `Profile.type`). Scope every txn by `userId` + `profileId` (never by `mode`).
- **needsReview/badge:** server forces `needsReview=true` on low confidence; the offline-heuristic path forces `needsReview=true`. The confidence badge `min(Int((confidence*100).rounded()), 99)` shows **iff `!needsReview`**.
- **Image reducer:** longest edge ≤ **2000 px** (preserve aspect); JPEG quality 0.6 then step **0.5 → 0.4 → 0.3** until `byteCount ≤ 1_500_000` or floor 0.3.
- **`PendingReceipt`** is a **local-only `@Model`** registered in `SnapceiptSchema.models`, **NOT `Syncable`**, **no `EntityType` case**, **NEVER passed to `sync.enqueue`**.

### `APIClient` additions (ALL FIVE conformers must gain both methods or it won't compile)
Signatures (on the protocol):
```swift
func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse
func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage
```
Conformers: `LiveAPIClient` (real POSTs), `StubAPIClient` (`Snapceipt/Sync/StubAPIClient.swift`), `MockAPIClient` (`SnapceiptTests/Mocks/MockAPIClient.swift`, scriptable), `PreviewAPIClient` (`Snapceipt/Features/Auth/SignInView.swift`), and the `RootView.swift` preview reuses `PreviewAPIClient` (no separate conformer).

### Build order
1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13. Tasks 1–3 add isolated files; Task 4 touches the network layer + all five conformers; Tasks 5–9 build domain logic; Tasks 10–13 wire UI + shell + UI test.

### Shared command snippets
- **Regenerate the project after adding files** (XcodeGen globs `Snapceipt/` so new files are picked up, but the `.xcodeproj` must be regenerated):
  ```
  xcodegen generate
  ```
- **Build + test** (used as the per-task gate):
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/<SuiteName> 2>&1 | tail -40
  ```
- **Commit trailer** (every commit):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```

---

## Tasks

### Task 1: Lift the capture primitives (DocumentScannerView + OCR + HeuristicParser) into Capture/Scanner, retuned to AUD; delete root ReceiptScanner.swift

Lift the three reusable pieces out of root `ReceiptScanner.swift` into `Snapceipt/Features/Capture/Scanner/`, dropping the file's `@Model Receipt`/`@Model LineItem` (they collide with the app entities) and the `ReceiptScanFlow`/`ReceiptReviewForm` (wrong models, no design system). Retune OCR languages to `["en-US","en-GB"]` and the `HeuristicParser` to AUD + AU GST (`tax = total/11` when no GST line). Delete the root file.

**Files**
- Create: `Snapceipt/Features/Capture/Scanner/DocumentScannerView.swift`
- Create: `Snapceipt/Features/Capture/Scanner/OCR.swift`
- Create: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift`
- Delete: `ReceiptScanner.swift` (repo root)
- Test: `SnapceiptTests/HeuristicParserTests.swift`

- [ ] **Step 1: Write the failing HeuristicParser test (AUD + AU GST)**

  Create `SnapceiptTests/HeuristicParserTests.swift`:
  ```swift
  import Testing
  @testable import Snapceipt

  struct HeuristicParserTests {
      private func lines(_ texts: [String]) -> [RecognizedLine] {
          texts.map { RecognizedLine(text: $0, confidence: 0.9, boundingBox: .zero) }
      }

      @Test("parses merchant, the total line amount, and an explicit GST line")
      func parsesTotalAndGST() {
          let p = HeuristicParser.parse(lines([
              "THE GROUNDS", "28/05/2026",
              "Flat White x2  9.00", "Big Brekkie 24.00",
              "GST 3.86", "TOTAL 42.50",
          ]))
          #expect(p.merchant == "THE GROUNDS")
          #expect(p.total == Decimal(string: "42.50"))
          #expect(p.tax == Decimal(string: "3.86"))
          #expect(p.currencyCode == "AUD")
      }

      @Test("ignores subtotal and prefers the TOTAL line")
      func ignoresSubtotal() {
          let p = HeuristicParser.parse(lines([
              "CAFE", "SUBTOTAL 100.00", "TOTAL 38.61",
          ]))
          #expect(p.total == Decimal(string: "38.61"))
      }

      @Test("infers AU GST as total/11 when no GST line is present")
      func infersGSTWhenMissing() {
          let p = HeuristicParser.parse(lines([
              "WOOLWORTHS", "TOTAL 22.00",
          ]))
          #expect(p.total == Decimal(string: "22.00"))
          // 22.00 / 11 = 2.00
          #expect(p.tax == Decimal(string: "2.00"))
      }

      @Test("defaults currency to AUD with no symbol")
      func defaultsAUD() {
          let p = HeuristicParser.parse(lines(["SHOP", "TOTAL 5.00"]))
          #expect(p.currencyCode == "AUD")
      }
  }
  ```

- [ ] **Step 2: Run it — expect a compile failure (types don't exist yet)**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/HeuristicParserTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'HeuristicParser'/'RecognizedLine' in scope" (root `ReceiptScanner.swift` is at the repo root and NOT in the `Snapceipt/` source glob, so its types are not in the app module).

- [ ] **Step 3: Create `DocumentScannerView.swift` (lifted as-is)**
  ```swift
  import SwiftUI
  import VisionKit

  /// VisionKit document camera (edge detect + dewarp + native shutter/flash).
  /// `onComplete` delivers the captured pages, an empty array on cancel, or an error.
  struct DocumentScannerView: UIViewControllerRepresentable {
      let onComplete: (Result<[UIImage], Error>) -> Void

      func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
          let vc = VNDocumentCameraViewController()
          vc.delegate = context.coordinator
          return vc
      }
      func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
      func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

      final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
          let onComplete: (Result<[UIImage], Error>) -> Void
          init(onComplete: @escaping (Result<[UIImage], Error>) -> Void) { self.onComplete = onComplete }

          func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                            didFinishWith scan: VNDocumentCameraScan) {
              let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
              onComplete(.success(pages))
          }
          func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
              onComplete(.success([]))  // user cancelled
          }
          func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                            didFailWithError error: Error) {
              onComplete(.failure(error))
          }
      }
  }
  ```

- [ ] **Step 4: Create `OCR.swift` (languages retuned to `["en-US","en-GB"]`)**
  ```swift
  import UIKit
  import Vision

  /// One recognized line of text with its geometry. `boundingBox` is normalized
  /// [0,1] with origin at BOTTOM-LEFT (Vision convention).
  struct RecognizedLine: Identifiable {
      let id = UUID()
      let text: String
      let confidence: Float
      let boundingBox: CGRect
  }

  /// On-device text recognition (the engine behind Live Text). AUD receipts are
  /// English; Vision has no `en-AU` tag, so we request `["en-US","en-GB"]`.
  enum OCR {
      enum Failure: Error { case noCGImage }

      static func recognize(in image: UIImage,
                            languages: [String] = ["en-US", "en-GB"]) async throws -> [RecognizedLine] {
          guard let cgImage = image.cgImage else { throw Failure.noCGImage }

          return try await withCheckedThrowingContinuation { continuation in
              let request = VNRecognizeTextRequest { request, error in
                  if let error { continuation.resume(throwing: error); return }
                  let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                  let lines: [RecognizedLine] = observations.compactMap { obs in
                      guard let best = obs.topCandidates(1).first else { return nil }
                      return RecognizedLine(text: best.string,
                                            confidence: best.confidence,
                                            boundingBox: obs.boundingBox)
                  }
                  continuation.resume(returning: lines)
              }
              request.recognitionLevel = .accurate
              request.usesLanguageCorrection = true
              request.recognitionLanguages = languages

              let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
              do { try handler.perform([request]) }
              catch { continuation.resume(throwing: error) }
          }
      }
  }
  ```

- [ ] **Step 5: Create `HeuristicParser.swift` (retuned to AUD + AU GST inference)**
  ```swift
  import Foundation

  /// Offline heuristic parse of OCR lines: merchant / date / total / GST.
  /// Used for the offline fallback when `/extract` is unavailable. AUD + AU GST.
  struct ParsedReceipt {
      var merchant: String = ""
      var date: Date = .now
      var total: Decimal = 0
      var tax: Decimal?
      var currencyCode: String = "AUD"
      var lineItems: [(name: String, price: Decimal)] = []
  }

  enum HeuristicParser {

      private static let amountRegex = try! NSRegularExpression(
          pattern: #"(-?\d{1,3}(?:[ ,]\d{3})*(?:[.,]\d{2}))"#)

      static func parse(_ lines: [RecognizedLine]) -> ParsedReceipt {
          var result = ParsedReceipt()
          let texts = lines.map { $0.text }
          let joined = texts.joined(separator: "\n")

          // Merchant: first line with >=3 letters that isn't web/email noise.
          result.merchant = texts.first(where: { line in
              let letters = line.filter { $0.isLetter }.count
              return letters >= 3 && !line.contains("www") && !line.contains("@")
          }) ?? texts.first ?? ""

          // Date: NSDataDetector across the joined text.
          if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
              let range = NSRange(joined.startIndex..., in: joined)
              if let match = detector.firstMatch(in: joined, range: range), let d = match.date {
                  result.date = d
              }
          }

          // Currency: AUD by default; keep symbol sniff only to disambiguate non-AUD.
          if joined.contains("¥") || joined.contains("￥") { result.currencyCode = "CNY" }
          else if joined.contains("£") { result.currencyCode = "GBP" }
          else if joined.contains("€") { result.currencyCode = "EUR" }
          else { result.currencyCode = "AUD" }

          func amounts(in s: String) -> [Decimal] {
              let r = NSRange(s.startIndex..., in: s)
              return amountRegex.matches(in: s, range: r).compactMap {
                  guard let rng = Range($0.range, in: s) else { return nil }
                  let cleaned = String(s[rng])
                  return Decimal(string: normalizeDecimal(cleaned))
              }
          }

          // Total: prefer a "total" (not "subtotal") line; else the largest amount.
          let totalLine = texts.first { line in
              let l = line.lowercased()
              return l.contains("total") && !l.contains("subtotal") && !l.contains("sub total")
          }
          if let totalLine, let maxAmt = amounts(in: totalLine).max() {
              result.total = maxAmt
          } else {
              result.total = texts.flatMap(amounts).max() ?? 0
          }

          // GST: explicit gst/tax/vat line if present, else AU inference total/11.
          if let taxLine = texts.first(where: { line in
                  ["gst", "tax", "vat"].contains { kw in line.lowercased().contains(kw) }
              }),
             let taxVal = amounts(in: taxLine).max() {
              result.tax = taxVal
          } else if result.total > 0 {
              result.tax = roundedGST(result.total)
          }

          return result
      }

      /// AU 10% GST is 1/11 of a GST-inclusive total, rounded to cents.
      private static func roundedGST(_ total: Decimal) -> Decimal {
          var raw = total / 11
          var rounded = Decimal()
          NSDecimalRound(&rounded, &raw, 2, .plain)
          return rounded
      }

      /// Normalize "1.234.56" / "1,234.56" / "1234,56" → "1234.56".
      private static func normalizeDecimal(_ s: String) -> String {
          var str = s.replacingOccurrences(of: " ", with: "")
          if let lastSep = str.lastIndex(where: { $0 == "." || $0 == "," }) {
              let intPart = str[..<lastSep].filter { $0.isNumber }
              let fracPart = str[str.index(after: lastSep)...].filter { $0.isNumber }
              str = intPart + "." + fracPart
          }
          return str
      }
  }
  ```

- [ ] **Step 6: Delete the root file**
  ```
  rm /Users/yangqi/Documents/github/Snapceipt/ReceiptScanner.swift
  ```

- [ ] **Step 7: Run the test — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/HeuristicParserTests 2>&1 | tail -30
  ```
  Expected: **PASS** (4 tests).

- [ ] **Step 8: Commit**
  ```
  git add -A && git commit -m "iOS capture: lift Scanner primitives (DocumentScannerView/OCR/HeuristicParser) into Capture/Scanner, retune to AUD; delete root ReceiptScanner.swift

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 2: ImageReducer (≤2000px, JPEG 0.6→0.5→0.4→0.3 until ≤1_500_000 bytes)

A pure-ish image reducer with a protocol seam (`ImageReducing`) so the view-model can inject it in tests. Downscale longest edge ≤ 2000 px (preserve aspect), then step JPEG quality down until bytes ≤ 1_500_000 or the 0.3 floor.

**Files**
- Create: `Snapceipt/Features/Capture/ImageReducer.swift`
- Test: `SnapceiptTests/ImageReducerTests.swift`

- [ ] **Step 1: Write the failing test on a synthesized known image**

  Create `SnapceiptTests/ImageReducerTests.swift`:
  ```swift
  import Testing
  import UIKit
  @testable import Snapceipt

  struct ImageReducerTests {
      /// A solid-color image of a given size. Noisy detail would only inflate bytes;
      /// a large dimension guarantees the downscale branch runs.
      private func image(width: CGFloat, height: CGFloat) -> UIImage {
          let size = CGSize(width: width, height: height)
          let renderer = UIGraphicsImageRenderer(size: size)
          return renderer.image { ctx in
              UIColor.systemTeal.setFill()
              ctx.fill(CGRect(origin: .zero, size: size))
          }
      }

      @Test("downscales the longest edge to <= 2000px and bounds bytes to <= 1_500_000")
      func reducesDimensionsAndBytes() {
          let reducer = ImageReducer()
          let big = image(width: 4032, height: 3024)
          let data = reducer.reduce(big)
          #expect(!data.isEmpty)
          #expect(data.count <= 1_500_000)
          let out = UIImage(data: data)!
          #expect(max(out.size.width, out.size.height) <= 2000)
          // Aspect preserved (4:3 within rounding).
          #expect(abs(out.size.width / out.size.height - 4032.0 / 3024.0) < 0.02)
      }

      @Test("a small image is not upscaled")
      func smallImageUnchangedDimensions() {
          let reducer = ImageReducer()
          let small = image(width: 800, height: 600)
          let out = UIImage(data: reducer.reduce(small))!
          #expect(max(out.size.width, out.size.height) <= 800)
      }
  }
  ```

- [ ] **Step 2: Run it — expect compile failure**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ImageReducerTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'ImageReducer' in scope".

- [ ] **Step 3: Implement `ImageReducer.swift`**
  ```swift
  import UIKit

  /// Seam over the receipt-image size reducer so the view-model is unit-testable.
  protocol ImageReducing {
      /// Downscale + recompress to a bounded JPEG. Pure (no I/O).
      func reduce(_ image: UIImage) -> Data
  }

  /// Bounds receipt uploads on-device: longest edge <= 2000 px (aspect preserved),
  /// then JPEG quality 0.6 stepping 0.5/0.4/0.3 until bytes <= 1_500_000 or the floor.
  struct ImageReducer: ImageReducing {
      private let maxEdge: CGFloat = 2000
      private let maxBytes = 1_500_000
      private let qualitySteps: [CGFloat] = [0.6, 0.5, 0.4, 0.3]

      func reduce(_ image: UIImage) -> Data {
          let scaled = downscaled(image)
          var data = scaled.jpegData(compressionQuality: qualitySteps[0]) ?? Data()
          for q in qualitySteps {
              guard let d = scaled.jpegData(compressionQuality: q) else { continue }
              data = d
              if d.count <= maxBytes { break }
          }
          return data
      }

      /// Scale so the longest edge is <= maxEdge; never upscale.
      private func downscaled(_ image: UIImage) -> UIImage {
          let w = image.size.width, h = image.size.height
          let longest = max(w, h)
          guard longest > maxEdge else { return image }
          let factor = maxEdge / longest
          let target = CGSize(width: (w * factor).rounded(), height: (h * factor).rounded())
          let format = UIGraphicsImageRendererFormat.default()
          format.scale = 1
          let renderer = UIGraphicsImageRenderer(size: target, format: format)
          return renderer.image { _ in
              image.draw(in: CGRect(origin: .zero, size: target))
          }
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ImageReducerTests 2>&1 | tail -30
  ```
  Expected: **PASS** (2 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: ImageReducer (<=2000px, JPEG 0.6->0.3 until <=1.5MB) + unit test

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 3: ExtractedReceipt draft + ExtractionResponse/UploadedImage Codables (Codable `category` → `categoryKey`)

The editable draft struct the Review screen binds to, plus the two Codable wire types. The `receipt.category` JSON key decodes into `ExtractedReceipt.categoryKey`. `ExtractedReceipt` is built two ways: from an `ExtractionResponse` (success) and from a `ParsedReceipt` (heuristic fallback) — both convenience inits live here.

> **Decimal decoding note:** the wire amounts (`total`, `gst`, `lineItems[].price`) are DOLLARS and decode into Swift `Decimal` via `JSONDecoder` (Double-bridged). They are not displayed at sub-cent precision and are immediately converted to integer cents by `ReceiptMapper.cents` (Task 6) via `NSDecimalRound(..., 0, .plain)`, so any Double→Decimal float artifact (e.g. `42.50000000000001`) is rounded away. Receipt amounts are small (cents-precision within the receipt range), so the bridging is lossless in practice; the `== Decimal(string: "42.50")` assertions hold. No custom `nonConformingFloatDecodingStrategy` is needed for v1.

**Files**
- Create: `Snapceipt/Features/Capture/ExtractedReceipt.swift`
- Test: `SnapceiptTests/ExtractionResponseTests.swift`

- [ ] **Step 1: Write the failing decode + init tests**

  Create `SnapceiptTests/ExtractionResponseTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  struct ExtractionResponseTests {
      private func decode(_ s: String) throws -> ExtractionResponse {
          try JSONDecoder().decode(ExtractionResponse.self, from: Data(s.utf8))
      }

      @Test("decodes the /extract response and maps category -> categoryKey")
      func decodesResponse() throws {
          let resp = try decode("""
          {"requestId":"r1",
           "receipt":{"merchant":"The Grounds","date":"2026-05-28","currencyCode":"AUD",
             "total":42.50,"gst":3.86,"category":"meals","deductible":50,
             "lineItems":[{"name":"Flat White x2","price":9.00},{"name":"Big Brekkie","price":24.00}],
             "confidence":0.98,"needsReview":false},
           "meta":{"model":"deepseek-chat","source":"scan","latencyMs":812,"attempts":1,"stub":false}}
          """)
          #expect(resp.requestId == "r1")
          #expect(resp.receipt.merchant == "The Grounds")
          #expect(resp.receipt.categoryKey == "meals")
          #expect(resp.receipt.total == Decimal(string: "42.50"))
          #expect(resp.receipt.gst == Decimal(string: "3.86"))
          #expect(resp.receipt.deductible == 50)
          #expect(resp.receipt.lineItems.count == 2)
          #expect(resp.receipt.lineItems[0].name == "Flat White x2")
          #expect(resp.receipt.lineItems[0].price == Decimal(string: "9.00"))
          #expect(resp.meta.stub == false)
      }

      @Test("decodes a null gst")
      func decodesNullGST() throws {
          let resp = try decode("""
          {"requestId":"r2",
           "receipt":{"merchant":"Payout","date":"2026-05-01","currencyCode":"AUD",
             "total":0,"gst":null,"category":"income","deductible":null,
             "lineItems":[],"confidence":0.9,"needsReview":false},
           "meta":{"model":"stub","source":"scan","latencyMs":1,"attempts":1,"stub":true}}
          """)
          #expect(resp.receipt.gst == nil)
          #expect(resp.receipt.deductible == nil)
      }

      @Test("builds an editable draft from a successful response (status done)")
      func draftFromResponse() throws {
          let resp = try decode("""
          {"requestId":"r1",
           "receipt":{"merchant":"Cafe","date":"2026-05-28","currencyCode":"AUD",
             "total":10.00,"gst":0.91,"category":"meals","deductible":50,
             "lineItems":[{"name":"Latte","price":5.00}],"confidence":0.95,"needsReview":false},
           "meta":{"model":"deepseek-chat","source":"scan","latencyMs":5,"attempts":1,"stub":false}}
          """)
          let draft = ExtractedReceipt(response: resp)
          #expect(draft.merchant == "Cafe")
          #expect(draft.categoryKey == "meals")
          #expect(draft.extractionStatus == "done")
          #expect(draft.needsReview == false)
          #expect(draft.lineItems.count == 1)
      }

      @Test("builds an editable draft from a heuristic ParsedReceipt (status pending, needsReview)")
      func draftFromParsed() {
          var parsed = ParsedReceipt()
          parsed.merchant = "Woolworths"
          parsed.total = Decimal(string: "22.00")!
          parsed.tax = Decimal(string: "2.00")!
          let draft = ExtractedReceipt(parsed: parsed, capturedAt: "2026-05-30")
          #expect(draft.merchant == "Woolworths")
          #expect(draft.total == Decimal(string: "22.00"))
          #expect(draft.gst == Decimal(string: "2.00"))
          #expect(draft.categoryKey == "office")   // fallback default category
          #expect(draft.deductible == 100)         // fallback default deductible
          #expect(draft.extractionStatus == "pending")
          #expect(draft.needsReview == true)
          #expect(draft.date == "2026-05-30")
      }
  }
  ```

- [ ] **Step 2: Run — expect compile failure**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ExtractionResponseTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'ExtractionResponse'/'ExtractedReceipt' in scope".

- [ ] **Step 3: Implement `ExtractedReceipt.swift`**
  ```swift
  import Foundation

  // MARK: - Wire types

  /// Decoded `/extract` response (§9). All amounts are DOLLARS on the wire.
  struct ExtractionResponse: Decodable {
      let requestId: String
      let receipt: ExtractedReceipt
      let meta: ExtractionMeta
  }

  /// `/extract` `meta` block.
  struct ExtractionMeta: Decodable {
      let model: String
      let source: String
      let latencyMs: Int
      let attempts: Int
      let stub: Bool
  }

  /// Decoded `/images` response (§9). `imageKey` is the full R2 key; `getUrl` is
  /// "/images/" + imageKey.
  struct UploadedImage: Decodable {
      let imageKey: String
      let getUrl: String
      let byteSize: Int
  }

  /// One extracted line item (dollars on the wire).
  struct ExtractedLineItem: Decodable {
      let name: String
      let price: Decimal
  }

  // MARK: - Editable draft

  /// The Review-screen draft: mirrors the wire `receipt` plus Review-editable extras
  /// (`paymentMethod`, `taxLabel`) and the local `extractionStatus`. Decodable so the
  /// response's nested `receipt` object decodes straight into it (Codable key
  /// `category` -> `categoryKey`).
  struct ExtractedReceipt: Decodable {
      var merchant: String
      var date: String                 // "YYYY-MM-DD"
      var total: Decimal               // dollars, >= 0
      var gst: Decimal?                // dollars; nil only when total == 0
      var categoryKey: String          // one of the 9 CategoryKey raw values
      var deductible: Int?             // 0..100 | nil
      var lineItems: [LineItemDraft]
      var confidence: Double
      var needsReview: Bool

      // Review-editable extras (not on the wire).
      var paymentMethod: String? = nil
      var taxLabel: String? = nil
      // Local extraction state ("done" | "pending" | "failed").
      var extractionStatus: String = "done"

      /// Plain editable line item (name + dollar price).
      struct LineItemDraft: Equatable {
          var name: String
          var price: Decimal
      }

      private enum CodingKeys: String, CodingKey {
          case merchant, date, total, gst
          case categoryKey = "category"
          case deductible, lineItems, confidence, needsReview
      }

      init(from decoder: Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          merchant = try c.decode(String.self, forKey: .merchant)
          date = try c.decode(String.self, forKey: .date)
          total = try c.decode(Decimal.self, forKey: .total)
          gst = try c.decodeIfPresent(Decimal.self, forKey: .gst)
          categoryKey = try c.decode(String.self, forKey: .categoryKey)
          deductible = try c.decodeIfPresent(Int.self, forKey: .deductible)
          let wireItems = try c.decode([ExtractedLineItem].self, forKey: .lineItems)
          lineItems = wireItems.map { LineItemDraft(name: $0.name, price: $0.price) }
          confidence = try c.decode(Double.self, forKey: .confidence)
          needsReview = try c.decode(Bool.self, forKey: .needsReview)
          // extras default; not present on the wire.
      }

      /// Memberwise (used by the two convenience builders + tests).
      init(merchant: String, date: String, total: Decimal, gst: Decimal?,
           categoryKey: String, deductible: Int?, lineItems: [LineItemDraft],
           confidence: Double, needsReview: Bool,
           paymentMethod: String? = nil, taxLabel: String? = nil,
           extractionStatus: String = "done") {
          self.merchant = merchant; self.date = date; self.total = total; self.gst = gst
          self.categoryKey = categoryKey; self.deductible = deductible
          self.lineItems = lineItems; self.confidence = confidence; self.needsReview = needsReview
          self.paymentMethod = paymentMethod; self.taxLabel = taxLabel
          self.extractionStatus = extractionStatus
      }
  }

  extension ExtractedReceipt {
      /// Build the draft from a successful `/extract` response. Status "done".
      init(response: ExtractionResponse) {
          self = response.receipt
          self.extractionStatus = "done"
      }

      /// Build the draft from the on-device heuristic fallback. Status "pending",
      /// `needsReview = true`, low confidence; category/deductible default to the
      /// server fallback defaults ("office"/100). `date` falls back to `capturedAt`.
      init(parsed: ParsedReceipt, capturedAt: String) {
          let iso = ExtractedReceipt.ymd(from: parsed.date) ?? capturedAt
          self.init(
              merchant: parsed.merchant,
              date: iso,
              total: parsed.total,
              gst: parsed.tax,
              categoryKey: "office",
              deductible: 100,
              lineItems: parsed.lineItems.map { LineItemDraft(name: $0.name, price: $0.price) },
              confidence: 0.4,
              needsReview: true,
              extractionStatus: "pending"
          )
      }

      /// "YYYY-MM-DD" in UTC for a `Date`.
      static func ymd(from date: Date) -> String? {
          let f = DateFormatter()
          f.calendar = Calendar(identifier: .gregorian)
          f.locale = Locale(identifier: "en_US_POSIX")
          f.timeZone = TimeZone(identifier: "UTC")
          f.dateFormat = "yyyy-MM-dd"
          return f.string(from: date)
      }

      /// The confidence badge value, shown only when `!needsReview`.
      var confidenceBadge: Int { min(Int((confidence * 100).rounded()), 99) }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ExtractionResponseTests 2>&1 | tail -30
  ```
  Expected: **PASS** (4 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: ExtractedReceipt draft + ExtractionResponse/UploadedImage Codables (category->categoryKey)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 4: APIClient.extract + uploadImage on the protocol + all 5 conformers + APIClientTests over MockURLProtocol

Add the two methods to the `APIClient` protocol and `LiveAPIClient` (the real POSTs), then add them to the other four conformers so the app still compiles: `StubAPIClient`, `MockAPIClient`, `PreviewAPIClient`. `LiveAPIClient.extract` POSTs `/extract` hard-coding `defaultCurrency:"AUD"`, `locale:"en-AU"`, and a generated `requestId`; `uploadImage` POSTs raw JPEG to `/images` with query params. The existing private `perform(...)` helper returns `Data`, so both methods can reuse the request plumbing — but `uploadImage` needs a raw-body variant, so add a small `performRawJPEG(...)` alongside `perform`.

**Files**
- Modify: `Snapceipt/Sync/APIClient.swift`
- Modify: `Snapceipt/Sync/StubAPIClient.swift`
- Modify: `Snapceipt/Features/Auth/SignInView.swift` (`PreviewAPIClient`)
- Modify: `SnapceiptTests/Mocks/MockAPIClient.swift`
- Test: `SnapceiptTests/APIClientTests.swift` (extend the existing suite)

- [ ] **Step 1: Add failing tests to `APIClientTests.swift`**

  Append these tests inside the existing `struct APIClientTests { ... }` (before its closing brace):
  ```swift
      @Test("extract POSTs /extract with AUD/en-AU + a requestId and decodes the receipt")
      func extractPostsAndDecodes() async throws {
          let (client, _) = makeClient()
          MockURLProtocol.setHandler { _ in
              (200, ["Content-Type": "application/json"], self.json("""
              {"requestId":"srv-1",
               "receipt":{"merchant":"The Grounds","date":"2026-05-28","currencyCode":"AUD",
                 "total":42.50,"gst":3.86,"category":"meals","deductible":50,
                 "lineItems":[{"name":"Flat White","price":9.00}],"confidence":0.98,"needsReview":false},
               "meta":{"model":"deepseek-chat","source":"scan","latencyMs":5,"attempts":1,"stub":false}}
              """))
          }
          let resp = try await client.extract(ocrText: "THE GROUNDS\nTOTAL 42.50",
                                              source: "scan", capturedAt: "2026-05-28")
          #expect(resp.receipt.categoryKey == "meals")
          #expect(resp.receipt.total == Decimal(string: "42.50"))
          #expect(MockURLProtocol.lastRequest?.url?.path == "/extract")
          #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
          let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
          let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
          #expect(obj?["ocrText"] as? String == "THE GROUNDS\nTOTAL 42.50")
          #expect(obj?["source"] as? String == "scan")
          #expect(obj?["defaultCurrency"] as? String == "AUD")
          #expect(obj?["locale"] as? String == "en-AU")
          #expect(obj?["capturedAt"] as? String == "2026-05-28")
          #expect((obj?["requestId"] as? String)?.isEmpty == false)
      }

      @Test("uploadImage POSTs raw JPEG to /images with transactionId/width/height query params")
      func uploadImagePostsRawJPEG() async throws {
          let (client, _) = makeClient()
          MockURLProtocol.setHandler { _ in
              (200, ["Content-Type": "application/json"], self.json("""
              {"imageKey":"u/u1/abc.jpg","getUrl":"/images/u/u1/abc.jpg","byteSize":1234}
              """))
          }
          let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
          let out = try await client.uploadImage(jpeg: jpeg, transactionId: "t1", width: 1200, height: 1600)
          #expect(out.imageKey == "u/u1/abc.jpg")
          #expect(out.getUrl == "/images/u/u1/abc.jpg")
          #expect(out.byteSize == 1234)
          let req = MockURLProtocol.lastRequest
          #expect(req?.url?.path == "/images")
          #expect(req?.httpMethod == "POST")
          #expect(req?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
          let q = req?.url?.query ?? ""
          #expect(q.contains("transactionId=t1"))
          #expect(q.contains("width=1200"))
          #expect(q.contains("height=1600"))
          let sent = req?.httpBodyData() ?? Data()
          #expect(sent == jpeg)
      }
  ```

- [ ] **Step 2: Run — expect FAIL (protocol lacks the methods)**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/APIClientTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "value of type 'LiveAPIClient' has no member 'extract'/'uploadImage'".

- [ ] **Step 3: Add the two methods to the `APIClient` protocol**

  In `Snapceipt/Sync/APIClient.swift`, add to the `protocol APIClient { ... }` body (after `syncPull`):
  ```swift
      func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse
      func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage
  ```

- [ ] **Step 4: Implement both on `LiveAPIClient`**

  In `LiveAPIClient`, add the request body type + methods in the `// MARK: APIClient` section (after `syncPull`):
  ```swift
      func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
          // Use the fully-qualified `Snapceipt.ID.uuidv7()` to match the spelling the
          // model inits already use (Transaction/LineItem/OutboxMutation defaults); `ID`
          // is unambiguous in APIClient.swift (no local `ID` shadow), so this also reads
          // consistently with Task 5's `Snapceipt.ID.uuidv7()`.
          let body = ExtractBody(ocrText: ocrText, source: source,
                                 defaultCurrency: "AUD", locale: "en-AU",
                                 capturedAt: capturedAt, requestId: Snapceipt.ID.uuidv7())
          return try await send("POST", "/extract", body: body, authenticated: true)
      }

      func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
          var items = [URLQueryItem(name: "width", value: String(width)),
                       URLQueryItem(name: "height", value: String(height))]
          if let transactionId { items.append(URLQueryItem(name: "transactionId", value: transactionId)) }
          let data = try await performRawJPEG("/images", query: items, jpeg: jpeg)
          do { return try decoder.decode(UploadedImage.self, from: data) }
          catch { throw APIError.decoding }
      }
  ```

  And add the request-body struct near the other body structs (the file already has `NoBody` at the bottom — add this in `DTOs.swift`-style; placing it in `APIClient.swift` is fine since it is request-only):
  ```swift
  /// POST /extract request body. iOS hard-codes AUD/en-AU and always sends a requestId.
  private struct ExtractBody: Encodable {
      let ocrText: String
      let source: String            // "scan" | "email_in"
      let defaultCurrency: String   // "AUD"
      let locale: String            // "en-AU"
      let capturedAt: String?       // "YYYY-MM-DD"
      let requestId: String
  }
  ```

  And add the raw-JPEG request helper alongside `perform(...)` (after `dataResponse(for:)` or near `perform`):
  ```swift
      /// POST a raw `image/jpeg` body (no JSON encoding); refresh-on-401 like `perform`.
      private func performRawJPEG(_ path: String, query: [URLQueryItem], jpeg: Data) async throws -> Data {
          func makeImageRequest() throws -> URLRequest {
              var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false)
              if !query.isEmpty { components?.queryItems = query }
              guard let url = components?.url else { throw APIError.transport }
              var request = URLRequest(url: url)
              request.httpMethod = "POST"
              request.setValue("application/json", forHTTPHeaderField: "Accept")
              request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
              request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
              if let bearer = auth.bearer() {
                  request.setValue(bearer, forHTTPHeaderField: "Authorization")
              }
              request.httpBody = jpeg
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

  > Note: `send`'s generic body inference needs a concrete type — `ExtractBody` is `Encodable`, so `send("POST", "/extract", body: body, ...)` resolves. The existing `send` overload already has a default `query: []`.

- [ ] **Step 5: Add both to `StubAPIClient` (canned)**

  > **Stub-divergence note (intentional):** the iOS `StubAPIClient.extract` below is an independent canned response (`meals` / confidence `0.92` / `needsReview:false`) and **intentionally differs** from the BACKEND stub (`office` / `0.9`, the deterministic heuristic in Plan A). The simulator never reaches the worker — `StubAPIClient` short-circuits the network — so this is not a wire break. Both keep `needsReview:false` so the confidence badge is shown and the Task 13 XCUITest can assert it.

  In `Snapceipt/Sync/StubAPIClient.swift`, add inside the class (before the closing brace), after `syncPull`:
  ```swift
      func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
          let json = """
          {"requestId":"stub-1",
           "receipt":{"merchant":"The Grounds","date":"\(capturedAt ?? "2026-05-28")","currencyCode":"AUD",
             "total":42.50,"gst":3.86,"category":"meals","deductible":50,
             "lineItems":[{"name":"Flat White x2","price":9.00},{"name":"Big Brekkie","price":24.00}],
             "confidence":0.92,"needsReview":false},
           "meta":{"model":"stub","source":"\(source)","latencyMs":1,"attempts":1,"stub":true}}
          """
          return try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
      }
      func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
          UploadedImage(imageKey: "u/\(DevAccount.userId)/stub.jpg",
                        getUrl: "/images/u/\(DevAccount.userId)/stub.jpg",
                        byteSize: jpeg.count)
      }
  ```

- [ ] **Step 6: Add both to `PreviewAPIClient`**

  In `Snapceipt/Features/Auth/SignInView.swift`, add inside `final class PreviewAPIClient` (after `syncPull`):
  ```swift
      func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
          let json = """
          {"requestId":"preview",
           "receipt":{"merchant":"Preview Cafe","date":"2026-05-28","currencyCode":"AUD",
             "total":12.00,"gst":1.09,"category":"meals","deductible":50,
             "lineItems":[],"confidence":0.9,"needsReview":false},
           "meta":{"model":"preview","source":"scan","latencyMs":1,"attempts":1,"stub":true}}
          """
          return try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
      }
      func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
          UploadedImage(imageKey: "u/u/preview.jpg", getUrl: "/images/u/u/preview.jpg", byteSize: jpeg.count)
      }
  ```

- [ ] **Step 7: Add both to `MockAPIClient` (scriptable, recorded)**

  In `SnapceiptTests/Mocks/MockAPIClient.swift`, add the handler properties (in the `// MARK: Sync scripting` block or a new MARK), the recorded calls, and the methods:
  ```swift
      // MARK: Capture scripting

      var extractHandler: ((_ ocrText: String, _ source: String, _ capturedAt: String?) async throws -> ExtractionResponse)?
      var uploadImageHandler: ((_ jpeg: Data, _ transactionId: String?, _ width: Int, _ height: Int) async throws -> UploadedImage)?

      private(set) var extractCalls: [(ocrText: String, source: String, capturedAt: String?)] = []
      private(set) var uploadCalls: [(transactionId: String?, width: Int, height: Int, byteCount: Int)] = []
  ```
  And the conforming methods (after `syncPull`):
  ```swift
      func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
          extractCalls.append((ocrText, source, capturedAt))
          guard let h = extractHandler else { throw MockAPIClientError.unscripted }
          return try await h(ocrText, source, capturedAt)
      }

      func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
          uploadCalls.append((transactionId, width, height, jpeg.count))
          guard let h = uploadImageHandler else { throw MockAPIClientError.unscripted }
          return try await h(jpeg, transactionId, width, height)
      }
  ```

- [ ] **Step 8: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/APIClientTests 2>&1 | tail -30
  ```
  Expected: **PASS** (the prior suite + the 2 new tests).

- [ ] **Step 9: Commit**
  ```
  git add -A && git commit -m "iOS capture: APIClient.extract + uploadImage on protocol + all 5 conformers + APIClientTests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 5: PendingReceipt local-only @Model + register in SnapceiptSchema (NOT Syncable, no EntityType)

A local-only artifact tracking the reduced JPEG + OCR text per saved scan, used by the upload queue and the re-extract reconciler. It is **not** `Syncable`, has **no** `EntityType` case, and is **never** enqueued — only registered in the SwiftData schema.

**Files**
- Create: `Snapceipt/Features/Capture/PendingReceipt.swift`
- Modify: `Snapceipt/Model/ModelContainer+Snapceipt.swift` (register in `SnapceiptSchema.models` + doc comment)
- Test: `SnapceiptTests/PendingReceiptModelTests.swift`

- [ ] **Step 1: Write the failing model + registration test**

  Create `SnapceiptTests/PendingReceiptModelTests.swift`:
  ```swift
  import Testing
  import SwiftData
  @testable import Snapceipt

  @MainActor
  struct PendingReceiptModelTests {
      @Test("PendingReceipt persists in the app container and round-trips")
      func persistsInAppContainer() throws {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          let ctx = ModelContext(container)
          let pr = PendingReceipt(transactionId: "t1", ocrText: "TOTAL 5.00",
                                  imageLocalPath: "/tmp/x.jpg", width: 1000, height: 1400)
          ctx.insert(pr)
          try ctx.save()
          let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
          #expect(rows.count == 1)
          #expect(rows[0].transactionId == "t1")
          #expect(rows[0].uploadState == "pending")
          #expect(rows[0].uploadAttempts == 0)
          #expect(rows[0].extractionAttempts == 0)
      }

      @Test("PendingReceipt is registered in the schema")
      func isRegistered() {
          // `SnapceiptSchema.models` is `[any PersistentModel.Type]`; existential
          // metatypes have no `==`, so compare identities via ObjectIdentifier.
          #expect(SnapceiptSchema.models.contains { ObjectIdentifier($0) == ObjectIdentifier(PendingReceipt.self) })
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/PendingReceiptModelTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'PendingReceipt' in scope".

- [ ] **Step 3: Create `PendingReceipt.swift`**
  ```swift
  import Foundation
  import SwiftData

  /// Local-only artifact for a saved scan. NOT a `Syncable` (no `EntityType`, never
  /// enqueued) — it only drives the image-upload queue + the re-extract reconciler,
  /// then is deleted once both finish. Registered in `SnapceiptSchema.models`.
  @Model
  final class PendingReceipt {
      @Attribute(.unique) var id: String
      /// The parent transaction this receipt belongs to.
      var transactionId: String
      /// OCR dump, kept so the reconciler can re-call `/extract` for a pending txn.
      var ocrText: String
      /// Absolute path of the reduced JPEG under Application Support (deleted on done).
      var imageLocalPath: String
      var width: Int
      var height: Int
      /// "pending" | "done" | "failed".
      var uploadState: String
      var uploadAttempts: Int
      var extractionAttempts: Int
      var createdAt: Int

      init(id: String = Snapceipt.ID.uuidv7(),
           transactionId: String,
           ocrText: String,
           imageLocalPath: String,
           width: Int,
           height: Int,
           uploadState: String = "pending",
           uploadAttempts: Int = 0,
           extractionAttempts: Int = 0,
           createdAt: Int = Epoch.nowMs()) {
          self.id = id
          self.transactionId = transactionId
          self.ocrText = ocrText
          self.imageLocalPath = imageLocalPath
          self.width = width
          self.height = height
          self.uploadState = uploadState
          self.uploadAttempts = uploadAttempts
          self.extractionAttempts = extractionAttempts
          self.createdAt = createdAt
      }
  }
  ```

- [ ] **Step 4: Register it in the schema**

  In `Snapceipt/Model/ModelContainer+Snapceipt.swift`, update the doc comment and add the model. Change:
  ```swift
  /// The full Snapceipt SwiftData schema: the 12 syncable domain models + the
  /// offline OutboxMutation queue.
  ```
  to:
  ```swift
  /// The full Snapceipt SwiftData schema: the 12 syncable domain models, the
  /// offline OutboxMutation queue, and the local-only PendingReceipt artifact.
  ```
  and add `PendingReceipt.self,` to the `models` array (after `OutboxMutation.self,`):
  ```swift
          OutboxMutation.self,
          PendingReceipt.self,
  ```

- [ ] **Step 5: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/PendingReceiptModelTests 2>&1 | tail -30
  ```
  Expected: **PASS** (2 tests).

- [ ] **Step 6: Commit**
  ```
  git add -A && git commit -m "iOS capture: local-only PendingReceipt @Model + register in SnapceiptSchema

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 6: Pure ExtractedReceipt → Transaction(+LineItem) mapping

A pure, unit-tested mapper from the (possibly edited) draft to a `Transaction` + its `LineItem`s. Sign by income, dollars→cents, gst nil→nil, mode lowercase, taxLabel/paymentMethod passthrough, line-item cents/sortOrder/quantity. Kept pure (no `ModelContext`) so it is trivially testable; the view-model inserts the returned objects.

**Files**
- Create: `Snapceipt/Features/Capture/ReceiptMapper.swift`
- Test: `SnapceiptTests/ReceiptMapperTests.swift`

- [ ] **Step 1: Write the failing mapping test**

  Create `SnapceiptTests/ReceiptMapperTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import Snapceipt

  struct ReceiptMapperTests {
      private func draft(categoryKey: String, total: String, gst: String?,
                         deductible: Int?, items: [(String, String)] = []) -> ExtractedReceipt {
          ExtractedReceipt(
              merchant: "The Grounds", date: "2026-05-28",
              total: Decimal(string: total)!,
              gst: gst.map { Decimal(string: $0)! },
              categoryKey: categoryKey, deductible: deductible,
              lineItems: items.map { .init(name: $0.0, price: Decimal(string: $0.1)!) },
              confidence: 0.95, needsReview: false,
              paymentMethod: "Visip •••• 4242", taxLabel: "GST",
              extractionStatus: "done")
      }

      @Test("expense category negates amountCents; cents rounded from dollars")
      func expenseNegated() {
          let (txn, _) = ReceiptMapper.map(
              draft(categoryKey: "meals", total: "42.50", gst: "3.86", deductible: 50),
              mode: "personal", profileId: "p1", userId: "u1")
          #expect(txn.amountCents == -4250)
          #expect(txn.catKey == "meals")
          #expect(txn.gstCents == 386)
          #expect(txn.deductiblePct == 50)
          #expect(txn.currency == "AUD")
          #expect(txn.txnDate == "2026-05-28")
          #expect(txn.merchant == "The Grounds")
          #expect(txn.mode == "personal")
          #expect(txn.taxLabel == "GST")
          #expect(txn.paymentMethod == "Visip •••• 4242")
          #expect(txn.isAi == true)
          #expect(txn.source == "scan")
          #expect(txn.extractionStatus == "done")
          #expect(txn.profileId == "p1")
          #expect(txn.userId == "u1")
      }

      @Test("income category keeps a positive amountCents")
      func incomePositive() {
          let (txn, _) = ReceiptMapper.map(
              draft(categoryKey: "income", total: "1200.00", gst: nil, deductible: nil),
              mode: "business", profileId: "p2", userId: "u1")
          #expect(txn.amountCents == 120000)
          #expect(txn.gstCents == nil)         // nil gst -> nil gstCents
          #expect(txn.deductiblePct == nil)
          #expect(txn.mode == "business")
      }

      @Test("line items map to cents, sortOrder=index, quantity=1, child userId; transactionId=parent")
      func lineItemsMapped() {
          let (txn, items) = ReceiptMapper.map(
              draft(categoryKey: "meals", total: "33.00", gst: "3.00", deductible: 50,
                    items: [("Flat White x2", "9.00"), ("Big Brekkie", "24.00")]),
              mode: "personal", profileId: "p1", userId: "u9")
          #expect(items.count == 2)
          #expect(items[0].name == "Flat White x2")
          #expect(items[0].priceCents == 900)
          #expect(items[0].sortOrder == 0)
          #expect(items[0].quantity == 1)
          #expect(items[0].userId == "u9")
          #expect(items[0].profileId == nil)
          #expect(items[0].transactionId == txn.id)
          #expect(items[1].priceCents == 2400)
          #expect(items[1].sortOrder == 1)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ReceiptMapperTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'ReceiptMapper' in scope".

- [ ] **Step 3: Implement `ReceiptMapper.swift`**
  ```swift
  import Foundation

  /// Pure mapping from the editable draft to a `Transaction` + its `LineItem`s.
  /// No `ModelContext` — the caller inserts + enqueues. Sign by income, dollars→cents,
  /// gst nil→nil, mode lowercase passthrough, line-item cents/sortOrder/quantity.
  enum ReceiptMapper {
      static func map(_ draft: ExtractedReceipt,
                      mode: String, profileId: String, userId: String) -> (Transaction, [LineItem]) {
          let magnitude = cents(draft.total)
          // total >= 0 always; expense negative, income positive.
          let signed = draft.categoryKey == CategoryKey.income.rawValue ? magnitude : -magnitude

          let txn = Transaction(
              userId: userId,
              profileId: profileId,
              merchant: draft.merchant,
              catKey: draft.categoryKey,
              amountCents: signed,
              currency: "AUD",
              txnDate: draft.date,
              mode: mode,
              taxLabel: draft.taxLabel,
              deductiblePct: draft.deductible,
              paymentMethod: draft.paymentMethod,
              isAi: true,
              gstCents: draft.gst.map(cents),
              source: "scan",
              extractionStatus: draft.extractionStatus
          )

          let items = draft.lineItems.enumerated().map { index, li in
              LineItem(
                  userId: userId,
                  transactionId: txn.id,
                  name: li.name,
                  priceCents: cents(li.price),
                  quantity: 1,
                  sortOrder: index
              )
          }
          return (txn, items)
      }

      /// Dollars → cents with round-half-up (matches the backend
      /// `Math.round(n*100)/100` on a non-negative dollar amount; `total >= 0` always,
      /// so the sign-asymmetry of `.plain` vs `Math.round` is never hit).
      static func cents(_ dollars: Decimal) -> Int {
          var scaled = dollars * 100
          var rounded = Decimal()
          NSDecimalRound(&rounded, &scaled, 0, .plain)
          return NSDecimalNumber(decimal: rounded).intValue
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ReceiptMapperTests 2>&1 | tail -30
  ```
  Expected: **PASS** (3 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: pure ExtractedReceipt -> Transaction(+LineItem) mapping + tests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 7: CaptureViewModel stage machine (injected image source + extract/fallback + save)

The `@Observable @MainActor` stage machine: `enum CaptureStage { case camera, scanning, review, saved }`, holding the captured `UIImage`, `rawText`, the editable `ExtractedReceipt` draft, `errorMessage`, live `confidence`/`needsReview`. Injected deps: `APIClient`, `ImageReducing`, `SyncEnqueuing`, `ProfilesStore`, `ModelContext`. Drives `onScanned(image:)` (OCR → scanning → `extract()`), `extract()` (success → map draft / failure → heuristic fallback `pending`+`needsReview`), and `save()` (insert txn+lineItems, enqueue, create `PendingReceipt` with the reduced JPEG written under Application Support).

**Files**
- Create: `Snapceipt/Features/Capture/CaptureViewModel.swift`
- Test: `SnapceiptTests/CaptureViewModelTests.swift`

- [ ] **Step 1: Write the failing view-model tests (MockAPIClient + MockSyncEngine spy)**

  Create `SnapceiptTests/CaptureViewModelTests.swift`:
  ```swift
  import Testing
  import SwiftData
  import UIKit
  @testable import Snapceipt

  @MainActor
  struct CaptureViewModelTests {

      /// Spy enqueuer (mirrors the one used by ProfilesStore tests).
      final class SpySync: SyncEnqueuing {
          struct Call { let op: String; let entityType: EntityType; let entityId: String }
          private(set) var calls: [Call] = []
          func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
              calls.append(Call(op: op, entityType: entityType, entityId: entity.id))
          }
      }

      /// Pass-through reducer so tests don't depend on JPEG sizing.
      struct PassReducer: ImageReducing {
          func reduce(_ image: UIImage) -> Data { Data([0xFF, 0xD8, 0xFF]) }
      }

      private func image() -> UIImage {
          UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
              UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
          }
      }

      private func fixture(extractHandler: ((String, String, String?) async throws -> ExtractionResponse)?)
          throws -> (CaptureViewModel, MockAPIClient, SpySync, ModelContext) {
          UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          let ctx = ModelContext(container)
          let profile = Profile(userId: "u1", name: "Me", type: "personal",
                                accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
          ctx.insert(profile); try ctx.save()
          let storeSync = SpySync()
          let store = ProfilesStore(context: ctx, sync: storeSync, userId: "u1")
          store.setActive(profile.id)
          let api = MockAPIClient()
          api.extractHandler = extractHandler
          let vmSync = SpySync()
          let vm = CaptureViewModel(api: api, reducer: PassReducer(), sync: vmSync,
                                    profiles: store, context: ctx, userId: "u1")
          return (vm, api, vmSync, ctx)
      }

      private func okResponse(merchant: String = "Cafe") -> ExtractionResponse {
          let json = """
          {"requestId":"r","receipt":{"merchant":"\(merchant)","date":"2026-05-28","currencyCode":"AUD",
            "total":10.00,"gst":0.91,"category":"meals","deductible":50,
            "lineItems":[{"name":"Latte","price":5.00}],"confidence":0.95,"needsReview":false},
           "meta":{"model":"x","source":"scan","latencyMs":1,"attempts":1,"stub":false}}
          """
          return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
      }

      @Test("onScanned -> scanning -> review with the extracted draft on success")
      func successPath() async throws {
          let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse() }
          await vm.onScanned(image: image(), rawText: "CAFE\nTOTAL 10.00")
          #expect(vm.stage == .review)
          #expect(vm.draft?.merchant == "Cafe")
          #expect(vm.draft?.extractionStatus == "done")
          #expect(vm.draft?.needsReview == false)
      }

      @Test("extract failure -> heuristic fallback draft, pending + needsReview, still reaches review")
      func failurePathFallsBack() async throws {
          struct Boom: Error {}
          let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
          await vm.onScanned(image: image(), rawText: "WOOLWORTHS\nTOTAL 22.00")
          #expect(vm.stage == .review)
          #expect(vm.draft?.extractionStatus == "pending")
          #expect(vm.draft?.needsReview == true)
          #expect(vm.draft?.total == Decimal(string: "22.00"))
      }

      @Test("save inserts the txn + line items, enqueues each, creates a PendingReceipt, -> saved")
      func saveInsertsAndEnqueues() async throws {
          let (vm, _, sync, ctx) = try fixture { _, _, _ in self.okResponse() }
          await vm.onScanned(image: image(), rawText: "CAFE\nTOTAL 10.00")
          vm.save()
          #expect(vm.stage == .saved)
          let txns = try ctx.fetch(FetchDescriptor<Transaction>())
          #expect(txns.count == 1)
          #expect(txns[0].source == "scan")
          // The canned stub is category "meals" (not income), so the VM→mapper path
          // must persist a NEGATIVE amount. Locks the sign through save().
          #expect(txns[0].amountCents < 0)
          let items = try ctx.fetch(FetchDescriptor<LineItem>())
          #expect(items.count == 1)
          // one upsert for the txn + one per line item
          #expect(sync.calls.filter { $0.entityType == .transaction }.count == 1)
          #expect(sync.calls.filter { $0.entityType == .lineItem }.count == 1)
          let pending = try ctx.fetch(FetchDescriptor<PendingReceipt>())
          #expect(pending.count == 1)
          #expect(pending[0].transactionId == txns[0].id)
          #expect(pending[0].ocrText == "CAFE\nTOTAL 10.00")
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'CaptureViewModel' in scope".

- [ ] **Step 3: Implement `CaptureViewModel.swift`**
  ```swift
  import Foundation
  import SwiftData
  import UIKit
  import Observation

  /// The 4-stage capture flow state.
  enum CaptureStage: Equatable { case camera, scanning, review, saved }

  /// Drives snap → OCR → extract → review → save. `@MainActor`; all deps injected as
  /// protocols so it is unit-testable with mocks. Never dead-ends offline: a failed
  /// `/extract` falls back to the on-device `HeuristicParser`.
  @Observable
  @MainActor
  final class CaptureViewModel {
      private(set) var stage: CaptureStage = .camera
      var draft: ExtractedReceipt?
      private(set) var capturedImage: UIImage?
      private(set) var rawText: String = ""
      var errorMessage: String?

      /// Live banner/badge state mirrored from the draft for the Scan/Review steps.
      var confidence: Double { draft?.confidence ?? 0 }
      var needsReview: Bool { draft?.needsReview ?? true }

      @ObservationIgnored private let api: APIClient
      @ObservationIgnored private let reducer: ImageReducing
      @ObservationIgnored private let sync: any SyncEnqueuing
      @ObservationIgnored private let profiles: ProfilesStore
      @ObservationIgnored private let context: ModelContext
      @ObservationIgnored private let userId: String

      init(api: APIClient, reducer: ImageReducing, sync: any SyncEnqueuing,
           profiles: ProfilesStore, context: ModelContext, userId: String) {
          self.api = api
          self.reducer = reducer
          self.sync = sync
          self.profiles = profiles
          self.context = context
          self.userId = userId
      }

      // MARK: Capture

      /// Called with the captured page (image + already-run OCR text). Moves to
      /// `.scanning` and kicks off extraction.
      func onScanned(image: UIImage, rawText: String) async {
          self.capturedImage = image
          self.rawText = rawText
          self.stage = .scanning
          await extract()
      }

      /// Calls `/extract`; on success maps the response, on failure falls back to the
      /// on-device heuristic. Either way it ends at `.review`.
      func extract() async {
          let capturedAt = ExtractedReceipt.ymd(from: Date())
          do {
              let resp = try await api.extract(ocrText: rawText, source: "scan", capturedAt: capturedAt)
              draft = ExtractedReceipt(response: resp)
          } catch {
              let parsed = HeuristicParser.parse(rawText.split(separator: "\n").map {
                  RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
              })
              draft = ExtractedReceipt(parsed: parsed, capturedAt: capturedAt ?? "")
          }
          stage = .review
      }

      // MARK: Save

      /// Persist the (possibly edited) draft: insert the txn + line items, enqueue each
      /// for sync, and create a local-only `PendingReceipt` (writing the reduced JPEG to
      /// Application Support). Guards on an active profile.
      func save() {
          guard let draft else { return }
          guard let profile = profiles.activeProfile else {
              errorMessage = "Select a profile before saving."
              return
          }
          let (txn, items) = ReceiptMapper.map(
              draft, mode: profile.type, profileId: profile.id, userId: userId)

          context.insert(txn)
          sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
          for item in items {
              context.insert(item)
              sync.enqueue(op: "upsert", entityType: .lineItem, entity: item)
          }

          let (path, width, height) = persistReducedImage(for: txn.id)
          let pending = PendingReceipt(
              transactionId: txn.id, ocrText: rawText,
              imageLocalPath: path, width: width, height: height)
          context.insert(pending)
          try? context.save()

          stage = .saved
      }

      /// Reduce + write the captured JPEG under Application Support; return its path
      /// and pixel dimensions. Returns an empty path if there is no image.
      private func persistReducedImage(for transactionId: String) -> (path: String, width: Int, height: Int) {
          guard let image = capturedImage else { return ("", 0, 0) }
          let data = reducer.reduce(image)
          let dims = UIImage(data: data) ?? image
          let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("receipts", isDirectory: true)
          try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let url = dir.appendingPathComponent("\(transactionId).jpg")
          try? data.write(to: url, options: .atomic)
          return (url.path, Int(dims.size.width), Int(dims.size.height))
      }

      // MARK: Flow control

      /// Reset to the camera for "Snap another".
      func reset() {
          draft = nil; capturedImage = nil; rawText = ""; errorMessage = nil
          stage = .camera
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/CaptureViewModelTests 2>&1 | tail -30
  ```
  Expected: **PASS** (3 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: CaptureViewModel stage machine (extract/fallback/save) + tests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 8: ReceiptUploadQueue (drains PendingReceipt on reachability, gates on txn-applied)

Drains `PendingReceipt` rows with `uploadState=="pending"`, uploading each **only after the parent transaction's outbox mutation has been applied** (i.e. there is no pending/inflight `OutboxMutation` for that `transactionId` — meaning the server row exists). On success → `uploadState="done"` + delete the local JPEG. After `maxUploadAttempts` (3) → `uploadState="failed"`.

**Files**
- Create: `Snapceipt/Features/Capture/ReceiptUploadQueue.swift`
- Test: `SnapceiptTests/ReceiptUploadQueueTests.swift`

- [ ] **Step 1: Write the failing queue tests**

  Create `SnapceiptTests/ReceiptUploadQueueTests.swift`:
  ```swift
  import Testing
  import SwiftData
  import Foundation
  @testable import Snapceipt

  @MainActor
  struct ReceiptUploadQueueTests {
      private func tempJPEG() throws -> String {
          let url = FileManager.default.temporaryDirectory
              .appendingPathComponent("\(UUID().uuidString).jpg")
          try Data([0xFF, 0xD8, 0xFF]).write(to: url)
          return url.path
      }

      private func fixture() throws -> (ModelContext, MockAPIClient) {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return (ModelContext(container), MockAPIClient())
      }

      @Test("uploads a pending receipt whose txn has no outstanding outbox mutation; marks done + deletes file")
      func uploadsWhenTxnApplied() async throws {
          let (ctx, api) = try fixture()
          let path = try tempJPEG()
          let pr = PendingReceipt(transactionId: "t1", ocrText: "x", imageLocalPath: path,
                                  width: 100, height: 140)
          ctx.insert(pr); try ctx.save()
          api.uploadImageHandler = { _, txnId, w, h in
              #expect(txnId == "t1"); #expect(w == 100); #expect(h == 140)
              return UploadedImage(imageKey: "u/u1/a.jpg", getUrl: "/images/u/u1/a.jpg", byteSize: 3)
          }
          let queue = ReceiptUploadQueue(api: api, context: ctx)
          await queue.drain()
          let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
          #expect(rows[0].uploadState == "done")
          #expect(api.uploadCalls.count == 1)
          #expect(!FileManager.default.fileExists(atPath: path))
      }

      @Test("skips a receipt whose txn still has a pending outbox mutation")
      func skipsWhenTxnNotApplied() async throws {
          let (ctx, api) = try fixture()
          let pr = PendingReceipt(transactionId: "t2", ocrText: "x", imageLocalPath: try tempJPEG(),
                                  width: 1, height: 1)
          let mutation = OutboxMutation(entityType: "transaction", entityId: "t2", op: "upsert",
                                        payloadJSON: "{}", status: "pending")
          ctx.insert(pr); ctx.insert(mutation); try ctx.save()
          let queue = ReceiptUploadQueue(api: api, context: ctx)
          await queue.drain()
          #expect(api.uploadCalls.isEmpty)
          let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
          #expect(rows[0].uploadState == "pending")
      }

      @Test("after maxUploadAttempts failures the receipt is marked failed")
      func failsAfterMaxAttempts() async throws {
          struct Boom: Error {}
          let (ctx, api) = try fixture()
          let pr = PendingReceipt(transactionId: "t3", ocrText: "x", imageLocalPath: try tempJPEG(),
                                  width: 1, height: 1, uploadAttempts: 2)
          ctx.insert(pr); try ctx.save()
          api.uploadImageHandler = { _, _, _, _ in throw Boom() }
          let queue = ReceiptUploadQueue(api: api, context: ctx)
          await queue.drain()
          let rows = try ctx.fetch(FetchDescriptor<PendingReceipt>())
          #expect(rows[0].uploadState == "failed")
          #expect(rows[0].uploadAttempts == 3)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ReceiptUploadQueueTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'ReceiptUploadQueue' in scope".

- [ ] **Step 3: Implement `ReceiptUploadQueue.swift`**
  ```swift
  import Foundation
  import SwiftData

  /// Drains `PendingReceipt` image uploads on reconnect/foreground. Gates each upload
  /// on the parent transaction's outbox mutation being applied (no pending/inflight
  /// `OutboxMutation` for that id), so the server row exists before the image links.
  /// On success: `uploadState="done"` + delete the local JPEG. After 3 attempts:
  /// `uploadState="failed"`.
  @MainActor
  final class ReceiptUploadQueue {
      private let api: APIClient
      private let context: ModelContext
      private let maxUploadAttempts = 3

      init(api: APIClient, context: ModelContext) {
          self.api = api
          self.context = context
      }

      /// Process all `pending` receipts whose parent txn has been applied.
      func drain() async {
          let descriptor = FetchDescriptor<PendingReceipt>(
              predicate: #Predicate { $0.uploadState == "pending" },
              sortBy: [SortDescriptor(\.createdAt)]
          )
          let pending = (try? context.fetch(descriptor)) ?? []
          for receipt in pending {
              guard txnApplied(receipt.transactionId) else { continue }
              await upload(receipt)
          }
      }

      /// True when there is no pending/inflight outbox mutation for the txn id.
      private func txnApplied(_ transactionId: String) -> Bool {
          let descriptor = FetchDescriptor<OutboxMutation>(
              predicate: #Predicate {
                  $0.entityId == transactionId
                  && ($0.status == "pending" || $0.status == "inflight")
              }
          )
          return ((try? context.fetchCount(descriptor)) ?? 0) == 0
      }

      private func upload(_ receipt: PendingReceipt) async {
          guard let jpeg = FileManager.default.contents(atPath: receipt.imageLocalPath) else {
              // The file is gone — nothing to upload; mark done so it gets cleaned up.
              receipt.uploadState = "done"
              try? context.save()
              return
          }
          receipt.uploadAttempts += 1
          do {
              _ = try await api.uploadImage(jpeg: jpeg, transactionId: receipt.transactionId,
                                            width: receipt.width, height: receipt.height)
              receipt.uploadState = "done"
              try? FileManager.default.removeItem(atPath: receipt.imageLocalPath)
          } catch {
              if receipt.uploadAttempts >= maxUploadAttempts {
                  receipt.uploadState = "failed"
              }
          }
          try? context.save()
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/ReceiptUploadQueueTests 2>&1 | tail -30
  ```
  Expected: **PASS** (3 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: ReceiptUploadQueue (gates on txn-applied, bounded retries) + tests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 9: PendingExtractionReconciler (pending → done, bounded → failed)

Finds `Transaction`s with `source=="scan" && extractionStatus=="pending"` whose `PendingReceipt.ocrText` is available; when online, re-calls `/extract`, updates `catKey/gstCents/deductiblePct/isAi`, sets `extractionStatus="done"`, and re-enqueues the upsert. After `maxExtractionAttempts` (3) → `extractionStatus="failed"` (stop). Processes ≤N per pass.

**Files**
- Create: `Snapceipt/Features/Capture/PendingExtractionReconciler.swift`
- Test: `SnapceiptTests/PendingExtractionReconcilerTests.swift`

- [ ] **Step 1: Write the failing reconciler tests**

  Create `SnapceiptTests/PendingExtractionReconcilerTests.swift`:
  ```swift
  import Testing
  import SwiftData
  import Foundation
  @testable import Snapceipt

  @MainActor
  struct PendingExtractionReconcilerTests {
      final class SpySync: SyncEnqueuing {
          private(set) var enqueuedTxnIds: [String] = []
          func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
              if entityType == .transaction { enqueuedTxnIds.append(entity.id) }
          }
      }

      private func fixture() throws -> (ModelContext, MockAPIClient, SpySync) {
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          return (ModelContext(container), MockAPIClient(), SpySync())
      }

      private func okResponse(category: String, gst: String, deductible: Int) -> ExtractionResponse {
          let json = """
          {"requestId":"r","receipt":{"merchant":"M","date":"2026-05-28","currencyCode":"AUD",
            "total":20.00,"gst":\(gst),"category":"\(category)","deductible":\(deductible),
            "lineItems":[],"confidence":0.95,"needsReview":false},
           "meta":{"model":"x","source":"scan","latencyMs":1,"attempts":1,"stub":false}}
          """
          return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
      }

      private func seedPending(_ ctx: ModelContext) throws -> Transaction {
          let txn = Transaction(userId: "u1", profileId: "p1", catKey: "office",
                                amountCents: -2000, txnDate: "2026-05-28",
                                source: "scan", extractionStatus: "pending")
          let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                  imageLocalPath: "/tmp/x.jpg", width: 1, height: 1)
          ctx.insert(txn); ctx.insert(pr); try ctx.save()
          return txn
      }

      @Test("a pending scan re-extracts, updates fields, marks done, re-enqueues the upsert")
      func reExtractsToDone() async throws {
          let (ctx, api, sync) = try fixture()
          let txn = try seedPending(ctx)
          api.extractHandler = { _, _, _ in self.okResponse(category: "meals", gst: "1.82", deductible: 50) }
          let r = PendingExtractionReconciler(api: api, context: ctx, sync: sync)
          await r.reconcile()
          let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
          #expect(updated.extractionStatus == "done")
          #expect(updated.catKey == "meals")
          #expect(updated.gstCents == 182)
          #expect(updated.deductiblePct == 50)
          #expect(updated.isAi == true)
          #expect(sync.enqueuedTxnIds == [txn.id])
      }

      @Test("after maxExtractionAttempts the scan is marked failed and not re-enqueued")
      func boundedToFailed() async throws {
          struct Boom: Error {}
          let (ctx, api, sync) = try fixture()
          let txn = Transaction(userId: "u1", profileId: "p1", catKey: "office",
                                amountCents: -2000, txnDate: "2026-05-28",
                                source: "scan", extractionStatus: "pending")
          let pr = PendingReceipt(transactionId: txn.id, ocrText: "M\nTOTAL 20.00",
                                  imageLocalPath: "/tmp/x.jpg", width: 1, height: 1, extractionAttempts: 2)
          ctx.insert(txn); ctx.insert(pr); try ctx.save()
          api.extractHandler = { _, _, _ in throw Boom() }
          let r = PendingExtractionReconciler(api: api, context: ctx, sync: sync)
          await r.reconcile()
          let updated = try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.id == txn.id }!
          #expect(updated.extractionStatus == "failed")
          #expect(sync.enqueuedTxnIds.isEmpty)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/PendingExtractionReconcilerTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'PendingExtractionReconciler' in scope".

- [ ] **Step 3: Implement `PendingExtractionReconciler.swift`**
  ```swift
  import Foundation
  import SwiftData
  import os

  /// Upgrades transactions saved via the offline heuristic fallback. Finds scan txns
  /// stuck at `extractionStatus=="pending"` with an available OCR text, re-calls
  /// `/extract`, updates the derived fields, marks them `done`, and re-enqueues the
  /// upsert. After 3 attempts a txn is marked `failed` and dropped. Bounded per pass.
  @MainActor
  final class PendingExtractionReconciler {
      private let api: APIClient
      private let context: ModelContext
      private let sync: any SyncEnqueuing
      private let maxExtractionAttempts = 3
      private let maxPerPass = 5
      private let log = Logger(subsystem: "app.snapceipt", category: "reconciler")

      init(api: APIClient, context: ModelContext, sync: any SyncEnqueuing) {
          self.api = api
          self.context = context
          self.sync = sync
      }

      func reconcile() async {
          let descriptor = FetchDescriptor<Transaction>(
              predicate: #Predicate {
                  $0.source == "scan" && $0.extractionStatus == "pending"
              },
              sortBy: [SortDescriptor(\.createdAt)]
          )
          let pendingTxns = (try? context.fetch(descriptor)) ?? []
          if pendingTxns.count > maxPerPass {
              log.info("reconciler capped: \(pendingTxns.count) pending, processing \(self.maxPerPass)")
          }
          for txn in pendingTxns.prefix(maxPerPass) {
              guard let receipt = pendingReceipt(for: txn.id) else { continue }
              await reconcileOne(txn, receipt)
          }
      }

      private func reconcileOne(_ txn: Transaction, _ receipt: PendingReceipt) async {
          receipt.extractionAttempts += 1
          do {
              let resp = try await api.extract(ocrText: receipt.ocrText, source: "scan",
                                               capturedAt: txn.txnDate)
              let r = resp.receipt
              txn.catKey = r.categoryKey
              txn.gstCents = r.gst.map(ReceiptMapper.cents)
              txn.deductiblePct = r.deductible
              txn.isAi = true
              txn.extractionStatus = "done"
              txn.updatedAt = Epoch.nowMs()
              try? context.save()
              sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
          } catch {
              if receipt.extractionAttempts >= maxExtractionAttempts {
                  txn.extractionStatus = "failed"
              }
              try? context.save()
          }
      }

      private func pendingReceipt(for transactionId: String) -> PendingReceipt? {
          let descriptor = FetchDescriptor<PendingReceipt>(
              predicate: #Predicate { $0.transactionId == transactionId }
          )
          return (try? context.fetch(descriptor))?.first
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/PendingExtractionReconcilerTests 2>&1 | tail -30
  ```
  Expected: **PASS** (2 tests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: PendingExtractionReconciler (pending->done, bounded->failed) + tests

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 10: The 4 SwiftUI steps + CaptureFlow (design-system styled, a11y ids)

The four designed steps + the `CaptureFlow` container that switches on `vm.stage`. This task also adds the capture accessibility ids (folded in here so the views compile against them). The steps are SwiftUI-only and have no unit tests of their own (they are covered by the XCUITest in Task 13); the build is the gate. The accessibility ids needed are added in this task's Step 1 so the views reference real constants.

**Files**
- Modify: `Snapceipt/Shared/AccessibilityID.swift` (capture ids)
- Create: `Snapceipt/Features/Capture/Views/CameraStep.swift`
- Create: `Snapceipt/Features/Capture/Views/ScanStep.swift`
- Create: `Snapceipt/Features/Capture/Views/ReviewStep.swift`
- Create: `Snapceipt/Features/Capture/Views/SavedStep.swift`
- Create: `Snapceipt/Features/Capture/Views/CaptureFlow.swift`

- [ ] **Step 1: Add the capture accessibility ids**

  In `Snapceipt/Shared/AccessibilityID.swift`, add inside `enum AccessibilityID` (after `captureClose`):
  ```swift
      // Capture flow
      static let captureScanTitle = "capture.scan.title"
      static let captureReviewMerchant = "capture.review.merchant"
      static let captureReviewCategory = "capture.review.category"
      static let captureReviewBadge = "capture.review.badge"
      static let captureReviewProfileToggle = "capture.review.profileToggle"
      static let captureSave = "capture.save"
      static let captureSavedTitle = "capture.saved.title"
      static let captureSnapAnother = "capture.snapAnother"
      static let captureDone = "capture.done"
  ```

- [ ] **Step 2: Create `CameraStep.swift`**
  ```swift
  import SwiftUI

  /// Full-bleed VisionKit scanner with a single Close affordance. The shutter,
  /// auto-capture, edge detection, dewarp, and flash are all native to
  /// VNDocumentCameraViewController — we do not rebuild them.
  struct CameraStep: View {
      let onScanned: (UIImage) -> Void
      let onClose: () -> Void

      var body: some View {
          ZStack(alignment: .topTrailing) {
              DocumentScannerView { result in
                  switch result {
                  case .failure:
                      onClose()
                  case .success(let images):
                      guard let first = images.first else { onClose(); return }  // cancelled
                      onScanned(first)
                  }
              }
              .ignoresSafeArea()

              Button(action: onClose) {
                  Icon(name: "x", size: 18, color: .white)
                      .padding(12)
                      .background(.black.opacity(0.45), in: Circle())
              }
              .buttonStyle(.plain)
              .padding(.trailing, 18)
              .padding(.top, 12)
              .accessibilityIdentifier(AccessibilityID.captureClose)
          }
      }
  }
  ```

- [ ] **Step 3: Create `ScanStep.swift` (thumbnail + animated scan line + reveal chips)**
  ```swift
  import SwiftUI

  /// Receipt thumbnail behind an animated scan line, with the 5 field-reveal chips
  /// flipping pending→found as extraction resolves. Auto-advance is driven by the
  /// view-model moving to `.review`; this view only animates while `.scanning`.
  struct ScanStep: View {
      @Environment(\.accent) private var accent
      let image: UIImage?
      let draft: ExtractedReceipt?

      @State private var scanY: CGFloat = 0
      @State private var revealed = 0

      private let chips = ["Merchant", "Date", "GST", "Total", "Category"]

      var body: some View {
          VStack(spacing: 22) {
              Text("Reading your receipt…")
                  .font(.display(20))
                  .foregroundStyle(Palette.ink)
                  .accessibilityIdentifier(AccessibilityID.captureScanTitle)

              ZStack {
                  RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                      .fill(Palette.paper)
                      .frame(width: 220, height: 300)
                      .cardShadow()
                  if let image {
                      Image(uiImage: image)
                          .resizable().scaledToFill()
                          .frame(width: 220, height: 300)
                          .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                  }
                  // Scan line.
                  Rectangle()
                      .fill(LinearGradient(colors: [accent.base.opacity(0), accent.base, accent.base.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing))
                      .frame(width: 220, height: 3)
                      .offset(y: scanY)
              }
              .frame(width: 220, height: 300)

              HStack(spacing: 8) {
                  ForEach(Array(chips.enumerated()), id: \.offset) { idx, label in
                      let found = idx < revealed
                      Text(label)
                          .font(.ui(11.5, .semibold))
                          .foregroundStyle(found ? .white : Palette.ink3)
                          .padding(.horizontal, 10).padding(.vertical, 6)
                          .background(found ? accent.base : Palette.paper2,
                                      in: Capsule())
                          .animation(.spring(response: 0.3, dampingFraction: 0.7), value: found)
                  }
              }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.cream)
          .onAppear { animate() }
      }

      private func animate() {
          withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
              scanY = 130
          }
          // Stagger the chip reveals for feel; the VM advances to Review when done.
          for i in 1...chips.count {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 * Double(i)) {
                  revealed = i
              }
          }
      }
  }
  ```

- [ ] **Step 4: Create `ReviewStep.swift` (editable card + AI banner + confidence badge + category picker + profile toggle)**
  ```swift
  import SwiftUI

  /// The designed editable review card: total + GST pill, the AI-suggestion banner,
  /// the confidence badge (shown iff !needsReview), editable merchant/date/category/
  /// payment/tax-label, a Personal/Business profile toggle that re-skins live, a
  /// read-only line-items list, disabled mileage/bank chips, and the Save button.
  struct ReviewStep: View {
      @Environment(\.accent) private var accent
      @Binding var draft: ExtractedReceipt
      // Presentation-only in v1: re-skins the toggle live but is NOT the save target.
      // `CaptureViewModel.save()` always persists under `profiles.activeProfile` (the
      // txn `mode`/`profileId` come from the active profile, per the scope-by-active-
      // profileId rule). See the toggle comment below.
      @Binding var mode: String                 // "personal" | "business"
      let onSave: () -> Void

      private var categoryKeys: [String] { CategoryKey.allCases.map(\.rawValue) }
      private func label(_ key: String) -> String {
          guard let ck = CategoryKey(rawValue: key) else { return key.capitalized }
          return CATS[ck]?.label ?? key.capitalized
      }

      var body: some View {
          ScrollView {
              VStack(spacing: 16) {
                  totalCard
                  aiBanner
                  fieldsCard
                  lineItemsCard
                  disabledChips
                  saveButton
              }
              .padding(18)
          }
          .background(Palette.cream)
      }

      private var totalCard: some View {
          VStack(spacing: 6) {
              HStack {
                  Text("Total detected").font(.ui(13)).foregroundStyle(Palette.ink2)
                  Spacer()
                  if let gst = draft.gst {
                      Text("GST \(amount(gst))")
                          .font(.ui(11.5, .semibold)).foregroundStyle(accent.deep)
                          .padding(.horizontal, 9).padding(.vertical, 5)
                          .background(accent.soft, in: Capsule())
                  }
              }
              Text(amount(draft.total)).numeric(40)
                  .foregroundStyle(Palette.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(16)
          .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
          .cardShadow()
      }

      @ViewBuilder
      private var aiBanner: some View {
          let text = draft.needsReview
              ? "Double-check the details below."
              : bannerTemplate
          HStack(alignment: .top, spacing: 10) {
              Icon(name: "sparkles", size: 18, color: accent.base)
              Text(text).font(.ui(13)).foregroundStyle(Palette.ink)
              Spacer()
              if !draft.needsReview {
                  Text("\(draft.confidenceBadge)%")
                      .font(.ui(12, .bold)).foregroundStyle(.white)
                      .padding(.horizontal, 8).padding(.vertical, 4)
                      .background(accent.base, in: Capsule())
                      .accessibilityIdentifier(AccessibilityID.captureReviewBadge)
              }
          }
          .padding(14)
          .background(accent.soft, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
          .overlay(
              RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                  .stroke(accent.base.opacity(0.35), lineWidth: 1)
          )
      }

      private var bannerTemplate: String {
          var s = "Looks like a \(draft.merchant) — filed under \(label(draft.categoryKey))"
          if let d = draft.deductible { s += ", claimable at \(d)%" }
          return s + "."
      }

      private var fieldsCard: some View {
          VStack(spacing: 12) {
              field("Merchant") {
                  TextField("Merchant", text: $draft.merchant)
                      .accessibilityIdentifier(AccessibilityID.captureReviewMerchant)
              }
              field("Date") { TextField("YYYY-MM-DD", text: $draft.date) }
              field("Category") {
                  Picker("Category", selection: $draft.categoryKey) {
                      ForEach(categoryKeys, id: \.self) { Text(label($0)).tag($0) }
                  }
                  .pickerStyle(.menu)
                  .accessibilityIdentifier(AccessibilityID.captureReviewCategory)
              }
              field("Payment") {
                  TextField("Payment method", text: Binding(
                      get: { draft.paymentMethod ?? "" },
                      set: { draft.paymentMethod = $0.isEmpty ? nil : $0 }))
              }
              field("Tax label") {
                  TextField("e.g. GST", text: Binding(
                      get: { draft.taxLabel ?? "" },
                      set: { draft.taxLabel = $0.isEmpty ? nil : $0 }))
              }
              profileToggle
          }
          .padding(16)
          .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
          .cardShadow()
      }

      // v1: presentation-only. Toggling Personal/Business re-skins the card live but
      // does NOT change which profile the txn is saved under — `save()` uses
      // `profiles.activeProfile` (scope-by-active-profileId). This is intentional for
      // v1; switching the save target is deferred.
      private var profileToggle: some View {
          HStack(spacing: 8) {
              ForEach(ProfileType.allCases) { type in
                  let selected = mode == type.rawValue
                  Button { mode = type.rawValue } label: {
                      Text(type.label)
                          .font(.ui(13, .semibold))
                          .foregroundStyle(selected ? .white : Palette.ink2)
                          .frame(maxWidth: .infinity, minHeight: 38)
                          .background(selected ? accent.base : Palette.paper2,
                                      in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                  }
                  .buttonStyle(.plain)
              }
          }
          .accessibilityIdentifier(AccessibilityID.captureReviewProfileToggle)
      }

      private var lineItemsCard: some View {
          Group {
              if !draft.lineItems.isEmpty {
                  VStack(spacing: 8) {
                      ForEach(Array(draft.lineItems.enumerated()), id: \.offset) { _, li in
                          HStack {
                              Text(li.name).font(.ui(13)).foregroundStyle(Palette.ink)
                              Spacer()
                              Text(amount(li.price)).font(.ui(13, .semibold)).foregroundStyle(Palette.ink2)
                          }
                      }
                  }
                  .padding(16)
                  .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                  .cardShadow()
              }
          }
      }

      private var disabledChips: some View {
          HStack(spacing: 8) {
              chip("Add to mileage", icon: "pin")
              chip("Match to bank", icon: "card")
          }
          .opacity(0.45)
      }

      private func chip(_ title: String, icon: String) -> some View {
          HStack(spacing: 6) {
              Icon(name: icon, size: 14, color: Palette.ink2)
              Text(title).font(.ui(12, .semibold)).foregroundStyle(Palette.ink2)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(Palette.paper2, in: Capsule())
      }

      private var saveButton: some View {
          Button(action: onSave) {
              Text("Save receipt")
                  .font(.ui(16, .bold)).foregroundStyle(.white)
                  .frame(maxWidth: .infinity, minHeight: 54)
                  .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier(AccessibilityID.captureSave)
      }

      @ViewBuilder
      private func field(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
          HStack {
              Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink3)
                  .frame(width: 92, alignment: .leading)
              control().font(.ui(15)).foregroundStyle(Palette.ink)
          }
      }

      /// Display a dollar Decimal as "$X.XX".
      private func amount(_ d: Decimal) -> String {
          let f = NumberFormatter()
          f.numberStyle = .currency
          f.currencyCode = "AUD"
          f.locale = Locale(identifier: "en_AU")
          return f.string(from: d as NSDecimalNumber) ?? "$0.00"
      }
  }
  ```

- [ ] **Step 5: Create `SavedStep.swift` (confetti + success ring)**
  ```swift
  import SwiftUI

  /// Saved confirmation: a green success ring/checkmark with a light confetti burst,
  /// a one-line summary, and Snap another / Done.
  struct SavedStep: View {
      @Environment(\.accent) private var accent
      let merchant: String
      let onSnapAnother: () -> Void
      let onDone: () -> Void

      @State private var pop = false

      var body: some View {
          VStack(spacing: 18) {
              ZStack {
                  Circle().stroke(Palette.income, lineWidth: 4).frame(width: 96, height: 96)
                  Icon(name: "check", size: 40, color: Palette.income)
                  Confetti(active: pop, color: accent.base)
              }
              .scaleEffect(pop ? 1 : 0.6)
              .animation(.spring(response: 0.45, dampingFraction: 0.6), value: pop)

              Text("Receipt saved!")
                  .font(.display(24)).foregroundStyle(Palette.ink)
                  .accessibilityIdentifier(AccessibilityID.captureSavedTitle)
              Text(merchant.isEmpty ? "Synced to your ledger." : "\(merchant) — synced to your ledger.")
                  .font(.ui(13.5)).foregroundStyle(Palette.ink2)

              VStack(spacing: 10) {
                  Button(action: onSnapAnother) {
                      Text("Snap another").font(.ui(16, .bold)).foregroundStyle(.white)
                          .frame(maxWidth: .infinity, minHeight: 52)
                          .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                  }
                  .buttonStyle(.plain)
                  .accessibilityIdentifier(AccessibilityID.captureSnapAnother)
                  Button(action: onDone) {
                      Text("Done").font(.ui(15, .semibold)).foregroundStyle(Palette.ink2)
                          .frame(maxWidth: .infinity, minHeight: 48)
                  }
                  .buttonStyle(.plain)
                  .accessibilityIdentifier(AccessibilityID.captureDone)
              }
              .padding(.horizontal, 28).padding(.top, 8)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.cream)
          .onAppear { pop = true }
      }
  }

  /// A lightweight confetti burst (no dependency): random colored shards fanning out.
  private struct Confetti: View {
      let active: Bool
      let color: Color
      var body: some View {
          ZStack {
              ForEach(0..<14, id: \.self) { i in
                  let angle = Double(i) / 14 * 2 * .pi
                  RoundedRectangle(cornerRadius: 1)
                      .fill([color, Palette.income, Palette.alert, Palette.ink3][i % 4])
                      .frame(width: 5, height: 9)
                      .offset(x: active ? cos(angle) * 70 : 0,
                              y: active ? sin(angle) * 70 : 0)
                      .opacity(active ? 0 : 1)
                      .animation(.easeOut(duration: 0.9).delay(0.05), value: active)
              }
          }
      }
  }
  ```

  > If `Icons.paths` lacks `"x"`, `"check"`, `"sparkles"`, or `"card"`, substitute the nearest existing key (the foundation `Icons.swift` already includes `"camera"`, `"receipt"`, `"pin"`, etc.). The build step verifies; missing keys render an empty path (harmless) but pick a real key for visual correctness.

- [ ] **Step 6: Create `CaptureFlow.swift` (switches on `vm.stage`)**
  ```swift
  import SwiftUI

  /// The full-screen capture container, switching on the view-model stage. Holds the
  /// editable draft + the live profile mode binding. Under the stub seam (Task 12) it
  /// starts at `.scanning` with a canned image so the simulator needs no camera.
  struct CaptureFlow: View {
      @Bindable var vm: CaptureViewModel
      @Environment(\.accent) private var accent
      let onClose: () -> Void

      @State private var mode: String = ProfileType.personal.rawValue

      var body: some View {
          ZStack {
              Palette.cream.ignoresSafeArea()
              switch vm.stage {
              case .camera:
                  CameraStep(
                      onScanned: { image in
                          Task {
                              let lines = (try? await OCR.recognize(in: image)) ?? []
                              await vm.onScanned(image: image,
                                                 rawText: lines.map(\.text).joined(separator: "\n"))
                          }
                      },
                      onClose: onClose)
              case .scanning:
                  ScanStep(image: vm.capturedImage, draft: vm.draft)
              case .review:
                  if let binding = draftBinding {
                      ReviewStep(draft: binding, mode: $mode, onSave: { vm.save() })
                  }
              case .saved:
                  SavedStep(merchant: vm.draft?.merchant ?? "",
                            onSnapAnother: { vm.reset() },
                            onDone: onClose)
              }
          }
          .onAppear { mode = activeMode }
          // v1: the Review Personal/Business toggle is presentation-only — it re-skins
          // the card but is NOT the save target. `vm.save()` persists under
          // `profiles.activeProfile`, so `mode` here drives appearance only.
          .onChange(of: mode) { _, _ in /* re-skin handled by the toggle's accent */ }
      }

      private var activeMode: String { mode }

      /// Non-nil binding to the draft once it exists.
      private var draftBinding: Binding<ExtractedReceipt>? {
          guard vm.draft != nil else { return nil }
          return Binding(get: { vm.draft! }, set: { vm.draft = $0 })
      }
  }
  ```

- [ ] **Step 7: Build the app target — expect success**
  ```
  xcodegen generate && xcodebuild build -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25
  ```
  Expected: **BUILD SUCCEEDED**. If an icon key is missing, swap it for an existing `Icons.paths` key.

- [ ] **Step 8: Commit**
  ```
  git add -A && git commit -m "iOS capture: 4 SwiftUI steps (Camera/Scan/Review/Saved) + CaptureFlow + a11y ids

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 11: Wire CaptureViewModel construction + queues into the shell (CaptureHost)

A small `CaptureHost` view that constructs the `CaptureViewModel` from the shell's environment (api, profiles, sync, context), and runs the `ReceiptUploadQueue.drain()` + `PendingExtractionReconciler.reconcile()` on appear/reconnect. This isolates DI so `RootView` (Task 12) just presents `CaptureHost`. The shell already injects `SyncEngine` (which conforms to `SyncEnqueuing`) and `Reachability`.

**Files**
- Create: `Snapceipt/Features/Capture/CaptureHost.swift`
- Test: `SnapceiptTests/CaptureHostFactoryTests.swift`

- [ ] **Step 1: Write a failing test for the VM factory (pure construction)**

  The host view itself isn't unit-tested, but the factory it uses is. Create `SnapceiptTests/CaptureHostFactoryTests.swift`:
  ```swift
  import Testing
  import SwiftData
  @testable import Snapceipt

  @MainActor
  struct CaptureHostFactoryTests {
      @Test("makeCaptureViewModel wires the active user + reducer + deps")
      func buildsViewModel() throws {
          UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
          let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
          let ctx = ModelContext(container)
          let profile = Profile(userId: "u7", name: "Me", type: "business",
                                accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950", isDefault: true)
          ctx.insert(profile); try ctx.save()
          final class SpySync: SyncEnqueuing {
              func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
          }
          let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u7")
          let vm = CaptureFactory.makeViewModel(
              api: MockAPIClient(), sync: SpySync(), profiles: store, context: ctx, userId: "u7")
          #expect(vm.stage == .camera)
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/CaptureHostFactoryTests 2>&1 | tail -30
  ```
  Expected: **FAIL** — "cannot find 'CaptureFactory' in scope".

- [ ] **Step 3: Implement `CaptureHost.swift` (factory + host view)**
  ```swift
  import SwiftUI
  import SwiftData

  /// Constructs the capture view-model with the production `ImageReducer`. Split out so
  /// it is testable without SwiftUI environment plumbing.
  enum CaptureFactory {
      @MainActor
      static func makeViewModel(api: APIClient, sync: any SyncEnqueuing,
                                profiles: ProfilesStore, context: ModelContext,
                                userId: String) -> CaptureViewModel {
          CaptureViewModel(api: api, reducer: ImageReducer(), sync: sync,
                           profiles: profiles, context: context, userId: userId)
      }
  }

  /// Full-screen capture host presented by the Snap tab. Builds the view-model from the
  /// shell environment and drains the upload queue + re-extract reconciler on appear and
  /// on reconnect. Optionally pre-seeds a canned image (UI-test stub seam, Task 12).
  struct CaptureHost: View {
      let api: APIClient
      let sync: any SyncEnqueuing
      @Bindable var profiles: ProfilesStore
      let reachability: Reachability
      let context: ModelContext
      let userId: String
      /// Stub seam: a canned (image, rawText). When set, the flow starts at `.scanning`.
      let stub: (image: UIImage, rawText: String)?
      let onClose: () -> Void

      @State private var vm: CaptureViewModel?

      var body: some View {
          Group {
              if let vm {
                  CaptureFlow(vm: vm, onClose: onClose)
                      .environment(\.accent, profiles.accent)
              } else {
                  Color.black.ignoresSafeArea()
              }
          }
          .task {
              let model = vm ?? CaptureFactory.makeViewModel(
                  api: api, sync: sync, profiles: profiles, context: context, userId: userId)
              vm = model
              await drainQueues()
              if let stub {
                  await model.onScanned(image: stub.image, rawText: stub.rawText)
              }
          }
          .onChange(of: reachability.isOnline) { _, online in
              if online { Task { await drainQueues() } }
          }
      }

      private func drainQueues() async {
          await ReceiptUploadQueue(api: api, context: context).drain()
          await PendingExtractionReconciler(api: api, context: context, sync: sync).reconcile()
      }
  }
  ```

- [ ] **Step 4: Run — expect PASS**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/CaptureHostFactoryTests 2>&1 | tail -30
  ```
  Expected: **PASS** (1 test).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: CaptureHost + CaptureFactory (DI + drains upload/reconcile queues)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 12: RootView wiring (Snap tab overlay → CaptureFlow) + the -uiTestStub canned-image seam

Replace `ShellView.capturePlaceholder` with the real `CaptureHost`. The Snap tab already routes `.tab(.snap)` → `overlay = .capture`; the `.overlay { if router.overlay == .capture ... }` now presents `CaptureHost` instead of the "coming soon" cover. Under `AppLaunch.useStub` (`-uiTestStub`) the host gets a canned bundled image + canned `rawText` so the flow starts at `.scanning` without a camera. Add the canned image to the app bundle.

**Files**
- Modify: `Snapceipt/App/RootView.swift` (`ShellView`: replace `capturePlaceholder`)
- Create: `Snapceipt/Resources/CannedReceipt/canned-receipt.jpg` (a small bundled JPEG)
- Modify: `Snapceipt/App/AppLaunch.swift` (expose the canned stub payload)

- [ ] **Step 1: Add a small bundled canned receipt image (deterministic, no external tools)**

  Generate a guaranteed-decodable 220×300 JPEG using only tooling that ships with macOS (`swift` + AppKit) — **no Pillow / no host-tool branch**. The bytes must decode via `UIImage(data:)`, because `AppLaunch.cannedScan` (Step 2) guards on a non-nil `UIImage`; if it were nil, `captureStub` would be nil and Task 13 would never reach `.scanning`. The OCR text is canned (not read from the image), so any small image works — but it MUST be a real, decodable JPEG. Run once and check the file into version control:
  ```
  mkdir -p Snapceipt/Resources/CannedReceipt
  /usr/bin/swift - <<'SWIFT'
  import AppKit
  let size = NSSize(width: 220, height: 300)
  let img = NSImage(size: size)
  img.lockFocus()
  NSColor(calibratedRed: 245/255, green: 238/255, blue: 228/255, alpha: 1).setFill()
  NSRect(origin: .zero, size: size).fill()
  img.unlockFocus()
  guard let tiff = img.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
      fputs("FAILED to render canned JPEG\n", stderr); exit(1)
  }
  try! jpeg.write(to: URL(fileURLWithPath: "Snapceipt/Resources/CannedReceipt/canned-receipt.jpg"))
  print("wrote canned-receipt.jpg bytes=\(jpeg.count)")
  SWIFT
  # Verify it is a real, decodable JPEG (not an empty marker stub):
  file Snapceipt/Resources/CannedReceipt/canned-receipt.jpg | grep -q "JPEG image data" \
    || { echo "ERROR: canned-receipt.jpg is not a valid JPEG"; exit 1; }
  ```
  This is hermetic: `swift`/AppKit ship with the macOS toolchain (no Pillow, no `pip install`), and the `file` check fails loudly rather than silently committing a non-decodable stub. The resulting `canned-receipt.jpg` (~9–10 KB) is committed in this task's commit (Step 6), so the asset is pinned in version control and `UIImage(data:)` is guaranteed non-nil for Task 13.

- [ ] **Step 2: Add the canned stub accessor to `AppLaunch`**

  In `Snapceipt/App/AppLaunch.swift`, add inside `struct AppLaunch` (before the closing brace):
  ```swift
      /// Canned (image, rawText) for the camera-less capture UI test. Loaded from the
      /// app bundle when `-uiTestStub` is set; nil otherwise (production uses the camera).
      var cannedScan: (image: UIImage, rawText: String)? {
          guard useStub,
                let url = Bundle.main.url(forResource: "canned-receipt", withExtension: "jpg"),
                let data = try? Data(contentsOf: url),
                let image = UIImage(data: data) else { return nil }
          let rawText = "THE GROUNDS\n28/05/2026\nFlat White x2  9.00\nBig Brekkie 24.00\nGST 3.86\nTOTAL 42.50"
          return (image, rawText)
      }
  ```
  And add `import UIKit` at the top of the file (it currently imports `Foundation` + `SwiftData`).

- [ ] **Step 3: Replace `capturePlaceholder` with `CaptureHost` in `ShellView`**

  In `Snapceipt/App/RootView.swift`, replace the overlay block:
  ```swift
          // --- Capture placeholder cover (full-screen, P1 stub) ---
          .overlay {
              if router.overlay == .capture { capturePlaceholder }
          }
  ```
  with:
  ```swift
          // --- Capture cover (full-screen): the 4-stage CaptureFlow ---
          .overlay {
              if router.overlay == .capture { captureCover(accent: accent) }
          }
  ```
  Then replace the entire `private var capturePlaceholder` computed property with:
  ```swift
      /// The full-screen capture flow, presented when the Snap tab routes to `.capture`.
      /// Under `-uiTestStub` it starts at the Scan stage with a canned image (no camera).
      @ViewBuilder
      private func captureCover(accent: AccentPalette) -> some View {
          CaptureHost(
              api: captureAPI,
              sync: sync,
              profiles: profiles,
              reachability: reachability,
              context: profiles.context,
              userId: profiles.userId,
              stub: captureStub,
              onClose: { router.dismissOverlay() }
          )
          .environment(\.accent, accent)
          .transition(.opacity)
      }

      /// The APIClient the capture flow calls. Reuses the app's live/stub client built at
      /// launch via `AppLaunch` (DEBUG) and falls back to the live client in Release.
      private var captureAPI: APIClient {
          #if DEBUG
          return AppLaunch.current.makeAPIClient(auth: auth)
          #else
          return LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.app")!, auth: auth)
          #endif
      }

      /// The canned (image, rawText) used by the camera-less UI test, or nil in production.
      private var captureStub: (image: UIImage, rawText: String)? {
          #if DEBUG
          return AppLaunch.current.cannedScan
          #else
          return nil
          #endif
      }
  ```
  > `ShellView` already has `@Environment(AuthStore.self) private var auth` and `@Bindable var sync`, `profiles`, `reachability`. `AppLaunch.current` + `makeAPIClient`/`cannedScan` are DEBUG-only, hence the `#if DEBUG`.

  Add the bundled folder to the app target resources by ensuring `project.yml` picks it up. The `Snapceipt:` target already globs `path: Snapceipt`, so `Snapceipt/Resources/CannedReceipt/canned-receipt.jpg` is included automatically as a resource (XcodeGen treats non-source files under a source path as resources). No `project.yml` change is required.

- [ ] **Step 4: Build the app — expect success**
  ```
  xcodegen generate && xcodebuild build -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -25
  ```
  Expected: **BUILD SUCCEEDED**.

- [ ] **Step 5: Run the full unit-test suite to confirm no regressions**
  ```
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests 2>&1 | tail -30
  ```
  Expected: **PASS** (all SnapceiptTests).

- [ ] **Step 6: Commit**
  ```
  git add -A && git commit -m "iOS capture: wire Snap-tab overlay to CaptureHost + bundled canned-image -uiTestStub seam

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

### Task 13: CaptureUITests — hermetic flow (Snap → Scan → Review → Save → Saved)

A camera-less XCUITest: launch seeded + stubbed, tap the Snap tab, and assert the canned flow advances Scan → Review (fields + confidence badge) → Save → Saved ("Receipt saved!"). Uses `StubAPIClient.extract` (canned, `needsReview:false`) so the badge is visible.

> **Stub note (intentional divergence):** this test exercises the iOS `StubAPIClient.extract` from Task 4 — an independent canned response (`meals` / `0.92` / `needsReview:false`). It intentionally differs from the BACKEND stub (`office` / `0.9`) because the simulator never reaches the worker. The test only asserts the badge is present (which `needsReview:false` guarantees) and does not assert the category/confidence numbers, so the divergence does not affect the assertions.

**Files**
- Create: `SnapceiptUITests/CaptureUITests.swift`

- [ ] **Step 1: Write the failing UI test**

  Create `SnapceiptUITests/CaptureUITests.swift`:
  ```swift
  import XCTest

  /// Hermetic capture flow: seeded shell + stub API + canned image (no camera).
  /// Snap tab → Scan → Review (assert fields + confidence badge) → Save → Saved.
  final class CaptureUITests: UITestCase {
      func testSnapToSaved() {
          launchSeeded()   // -uiTestStub + -uiTestSeed: signed-in, 2 profiles, StubAPIClient

          // Open the capture flow via the raised center Snap tab.
          let snap = app.buttons[AccessibilityID.tabSnap].firstMatch
          XCTAssertTrue(snap.waitForExistence(timeout: 10), "Snap tab not found")
          snap.tap()

          // The Scan stage shows its title (canned image starts at .scanning under the stub).
          XCTAssertTrue(app.staticTexts[AccessibilityID.captureScanTitle].waitForExistence(timeout: 5),
                        "Scan stage did not appear")

          // It auto-advances to Review once the stub extract resolves: the Save button +
          // the editable Merchant field + the confidence badge (shown because !needsReview).
          let save = app.buttons[AccessibilityID.captureSave]
          XCTAssertTrue(save.waitForExistence(timeout: 8), "Review stage (Save button) did not appear")
          XCTAssertTrue(app.textFields[AccessibilityID.captureReviewMerchant].exists,
                        "Merchant field missing on Review")
          XCTAssertTrue(app.staticTexts[AccessibilityID.captureReviewBadge].exists,
                        "Confidence badge should be shown for a confident (needsReview=false) draft")

          // Save → Saved.
          save.tap()
          XCTAssertTrue(app.staticTexts[AccessibilityID.captureSavedTitle].waitForExistence(timeout: 5),
                        "Saved stage did not appear")
          XCTAssertTrue(app.staticTexts["Receipt saved!"].exists, "Saved headline missing")

          // Dismiss back to the shell.
          app.buttons[AccessibilityID.captureDone].tap()
          XCTAssertTrue(app.buttons[AccessibilityID.shellTabBar].waitForExistence(timeout: 5),
                        "Did not return to the shell after Done")
      }
  }
  ```

- [ ] **Step 2: Run — expect FAIL on first run if any seam is off**
  ```
  xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/CaptureUITests 2>&1 | tail -40
  ```
  Expected on the FIRST run before the seam is correct: **FAIL** (e.g. the Scan title not found because the seeded launch isn't a stub launch, or the badge not shown). Diagnose: confirm `launchSeeded()` includes `-uiTestStub` (it does — see `UITestCase.swift`), and that `AppLaunch.current.cannedScan` returns non-nil (it requires `-uiTestStub`). The seeded session provides the active profile so `CaptureHost` can build the VM. The stub extract returns `needsReview:false`, so the badge shows.

- [ ] **Step 3: Fix any seam gap surfaced by the run, then re-run — expect PASS**

  Likely fixes (apply only if the run reports them):
  - If `captureStub` is nil under `launchSeeded` (canned image missing from the bundle), confirm `Snapceipt/Resources/CannedReceipt/canned-receipt.jpg` exists and is in the app target (it is, via the `Snapceipt` source glob). Re-run `xcodegen generate`.
  - If the Snap tab id differs, it is `AccessibilityID.tabSnap` (= `"tabbar.snap"`) on the `TabBar`'s center button.

  Re-run:
  ```
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptUITests/CaptureUITests 2>&1 | tail -40
  ```
  Expected: **PASS** (1 test).

- [ ] **Step 4: Run the full test suite (unit + UI) as the final gate**
  ```
  xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
  ```
  Expected: **PASS** (all SnapceiptTests + SnapceiptUITests).

- [ ] **Step 5: Commit**
  ```
  git add -A && git commit -m "iOS capture: hermetic CaptureUITests (Snap -> Scan -> Review -> Save -> Saved)

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Notes / risk reconciliation

- **Camera in CI:** never runs in the simulator — the `-uiTestStub` canned-image seam (Task 12) is mandatory for the capture XCUITest; production uses the real `DocumentScannerView`.
- **`PendingReceipt`** stays local-only: registered in `SnapceiptSchema.models` (Task 5), never given an `EntityType` case, never passed to `sync.enqueue`.
- **Sign/cents/GST rules** are enforced once in `ReceiptMapper` (Task 6) and reused by the reconciler (Task 9) — no duplicated math.
- **Five conformers** (`LiveAPIClient`, `StubAPIClient`, `MockAPIClient`, `PreviewAPIClient`, and the `RootView` preview which reuses `PreviewAPIClient`) all gain `extract` + `uploadImage` in Task 4, or the project won't compile.
- **Image dimensions in `PendingReceipt`:** derived from the reduced JPEG (post-downscale), so `width`/`height` match what was uploaded.
