//
//  ReceiptScanner.swift
//
//  Receipt capture → OCR → parse → save, using Apple's on-device OCR.
//  Capture:  VisionKit  (VNDocumentCameraViewController — edge detect + dewarp)
//  OCR:      Vision     (VNRecognizeTextRequest — the engine behind Live Text)
//  Storage:  SwiftData
//
//  iOS 17+ (SwiftData). OCR itself works iOS 13+.
//

import SwiftUI
import Vision
import VisionKit
import SwiftData

// MARK: - Storage Models

@Model
final class Receipt {
    var id: UUID
    var merchant: String
    var purchaseDate: Date
    var total: Decimal
    var tax: Decimal?
    var currencyCode: String          // "USD", "AUD", "CNY" ...
    var rawText: String               // full OCR dump, kept for re-parsing / audit
    var imageData: Data?              // the cropped, dewarped scan (JPEG)
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \LineItem.receipt)
    var lineItems: [LineItem]

    init(merchant: String = "",
         purchaseDate: Date = .now,
         total: Decimal = 0,
         tax: Decimal? = nil,
         currencyCode: String = "USD",
         rawText: String = "",
         imageData: Data? = nil) {
        self.id = UUID()
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        self.total = total
        self.tax = tax
        self.currencyCode = currencyCode
        self.rawText = rawText
        self.imageData = imageData
        self.createdAt = .now
        self.lineItems = []
    }
}

@Model
final class LineItem {
    var name: String
    var price: Decimal
    var receipt: Receipt?

    init(name: String, price: Decimal) {
        self.name = name
        self.price = price
    }
}

// MARK: - OCR

/// One recognized line of text with its geometry.
/// boundingBox is normalized [0,1], origin at BOTTOM-LEFT (Vision convention).
struct RecognizedLine: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

enum OCR {
    enum Failure: Error { case noCGImage }

    /// Run on-device text recognition. Async wrapper around the callback API.
    static func recognize(in image: UIImage,
                          languages: [String] = ["en-US", "zh-Hans"]) async throws -> [RecognizedLine] {
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
            request.recognitionLevel = .accurate          // slower, far better for receipts
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            // request.customWords = ["TOTAL", "GST", "SUBTOTAL"]  // bias if helpful

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - Document Scanner (VisionKit camera with dewarp)

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

// MARK: - Parsing

struct ParsedReceipt {
    var merchant: String = ""
    var date: Date = .now
    var total: Decimal = 0
    var tax: Decimal?
    var currencyCode: String = "USD"
    var lineItems: [(name: String, price: Decimal)] = []
}

/// Offline, heuristic parser. Good enough for merchant/date/total on most receipts.
/// For robust line-item extraction across arbitrary layouts, use the LLM parser below.
enum HeuristicParser {

    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(-?\d{1,3}(?:[ ,]\d{3})*(?:[.,]\d{2}))"#)

    static func parse(_ lines: [RecognizedLine]) -> ParsedReceipt {
        var result = ParsedReceipt()
        let texts = lines.map { $0.text }
        let joined = texts.joined(separator: "\n")

        // Merchant: first line with letters that isn't a phone number / address noise.
        result.merchant = texts.first(where: { line in
            let letters = line.filter { $0.isLetter }.count
            return letters >= 3 && !line.contains("www") && !line.contains("@")
        }) ?? texts.first ?? ""

        // Date: NSDataDetector handles many formats and locales for you.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(joined.startIndex..., in: joined)
            if let match = detector.firstMatch(in: joined, range: range), let d = match.date {
                result.date = d
            }
        }

        // Currency: cheap symbol sniff.
        if joined.contains("$") { result.currencyCode = joined.contains("AUD") ? "AUD" : "USD" }
        else if joined.contains("¥") || joined.contains("￥") { result.currencyCode = "CNY" }
        else if joined.contains("£") { result.currencyCode = "GBP" }
        else if joined.contains("€") { result.currencyCode = "EUR" }

        // Total: prefer a line that mentions "total" but not "subtotal"; take the largest amount on it.
        // Fall back to the single largest amount anywhere on the receipt.
        func amounts(in s: String) -> [Decimal] {
            let r = NSRange(s.startIndex..., in: s)
            return amountRegex.matches(in: s, range: r).compactMap {
                guard let rng = Range($0.range, in: s) else { return nil }
                let cleaned = s[rng]
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: ",", with: ".")   // crude; tune per-locale
                // keep only last dot as decimal separator
                return Decimal(string: normalizeDecimal(String(cleaned)))
            }
        }

        let totalLine = texts.first { line in
            let l = line.lowercased()
            return l.contains("total") && !l.contains("subtotal") && !l.contains("sub total")
        }
        if let totalLine, let max = amounts(in: totalLine).max() {
            result.total = max
        } else {
            result.total = texts.flatMap(amounts).max() ?? 0
        }

        // Tax / GST line, if present.
        if let taxLine = texts.first(where: { ["tax", "gst", "vat"].contains { kw in $0.lowercased().contains(kw) } }),
           let taxVal = amounts(in: taxLine).max() {
            result.tax = taxVal
        }

        return result
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

// MARK: - LLM Parser (recommended for production)
//
// Do OCR on-device, then POST `rawText` to YOUR backend, which calls Claude and
// returns JSON. Never embed an API key in the app. Sketch of the client side:
//
// struct LLMParser {
//     static func parse(rawText: String) async throws -> ParsedReceipt {
//         var req = URLRequest(url: URL(string: "https://your-backend/parse-receipt")!)
//         req.httpMethod = "POST"
//         req.setValue("application/json", forHTTPHeaderField: "Content-Type")
//         req.httpBody = try JSONEncoder().encode(["text": rawText])
//         let (data, _) = try await URLSession.shared.data(for: req)
//         // backend returns { merchant, date (ISO8601), total, tax, currencyCode, lineItems: [{name, price}] }
//         return try decode(data)
//     }
// }
//
// Backend prompt (system): "You extract structured data from noisy receipt OCR.
// Respond with ONLY a JSON object, no prose, no markdown fences:
// {merchant, date (ISO 8601), currencyCode (ISO 4217), total (number),
//  tax (number|null), lineItems:[{name, price}]}. Infer currency from symbols/locale."

// MARK: - UI Flow

enum ScanStage {
    case idle, scanning, recognizing, review
}

struct ReceiptScanFlow: View {
    @Environment(\.modelContext) private var context
    @State private var stage: ScanStage = .idle
    @State private var parsed = ParsedReceipt()
    @State private var rawText = ""
    @State private var imageData: Data?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .idle:      idleView
                case .scanning:  scannerView
                case .recognizing: ProgressView("Reading receipt…")
                case .review:    ReceiptReviewForm(parsed: $parsed, onSave: save)
                }
            }
            .navigationTitle("Add Receipt")
            .alert("Couldn't scan",
                   isPresented: .constant(errorMessage != nil),
                   actions: { Button("OK") { errorMessage = nil } },
                   message: { Text(errorMessage ?? "") })
        }
    }

    private var idleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.viewfinder").font(.system(size: 64))
            Button("Scan a receipt") { stage = .scanning }
                .buttonStyle(.borderedProminent)
        }
    }

    private var scannerView: some View {
        DocumentScannerView { result in
            switch result {
            case .failure(let err):
                errorMessage = err.localizedDescription
                stage = .idle
            case .success(let images):
                guard let first = images.first else { stage = .idle; return }   // cancelled
                imageData = first.jpegData(compressionQuality: 0.7)
                stage = .recognizing
                Task { await runOCR(on: first) }
            }
        }
    }

    private func runOCR(on image: UIImage) async {
        do {
            let lines = try await OCR.recognize(in: image)
            rawText = lines.map(\.text).joined(separator: "\n")
            parsed = HeuristicParser.parse(lines)        // swap for LLMParser.parse(rawText:)
            stage = .review
        } catch {
            errorMessage = error.localizedDescription
            stage = .idle
        }
    }

    private func save() {
        let receipt = Receipt(merchant: parsed.merchant,
                              purchaseDate: parsed.date,
                              total: parsed.total,
                              tax: parsed.tax,
                              currencyCode: parsed.currencyCode,
                              rawText: rawText,
                              imageData: imageData)
        receipt.lineItems = parsed.lineItems.map { LineItem(name: $0.name, price: $0.price) }
        context.insert(receipt)
        stage = .idle
    }
}

/// Always let the user verify before saving — OCR is never 100%.
struct ReceiptReviewForm: View {
    @Binding var parsed: ParsedReceipt
    let onSave: () -> Void

    var body: some View {
        Form {
            Section("Details") {
                TextField("Merchant", text: $parsed.merchant)
                DatePicker("Date", selection: $parsed.date, displayedComponents: .date)
                TextField("Currency", text: $parsed.currencyCode)
            }
            Section("Amounts") {
                LabeledContent("Total", value: parsed.total, format: .number.precision(.fractionLength(2)))
                if let tax = parsed.tax {
                    LabeledContent("Tax", value: tax, format: .number.precision(.fractionLength(2)))
                }
            }
            Section { Button("Save receipt", action: onSave).bold() }
        }
    }
}
