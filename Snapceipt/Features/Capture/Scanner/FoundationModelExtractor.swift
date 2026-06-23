import Foundation

/// Pure FM-output → ExtractedReceipt mapping (no FoundationModels import) so it is unit-testable
/// without a device. Converts Double→Decimal, backfills a nil date to capturedAt, applies guards.
enum FoundationModelMapping {
    static func toReceipt(
        merchant: String, date: String?, total: Double, gst: Double?,
        category: String, deductible: Int?, items: [(String, Double)],
        confidence: Double, capturedAt: String, ocrText: String
    ) -> ExtractedReceipt {
        let cat = CategoryKey(rawValue: category)?.rawValue ?? CategoryKey.office.rawValue
        // Convert FM Doubles to Decimal via their shortest round-trippable string form to avoid
        // binary-float taint (Decimal(0.91) -> 0.91000000000000003…; Decimal(string: "0.91") is exact).
        let draft = ExtractedReceipt(
            merchant: merchant,
            date: (date?.isEmpty == false ? date! : capturedAt),
            total: Decimal(string: String(total)) ?? Decimal(total),
            gst: gst.map { Decimal(string: String($0)) ?? Decimal($0) },
            categoryKey: cat,
            deductible: deductible,
            lineItems: items.map { .init(name: $0.0, price: Decimal(string: String($0.1)) ?? Decimal($0.1)) },
            confidence: confidence,
            needsReview: confidence < 0.8,
            extractionStatus: "done")
        return OnDeviceGuards.reconcile(draft, ocrText: ocrText)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26, *)
@Generable
struct FMReceipt {
    @Guide(description: "Merchant / store name") var merchant: String
    @Guide(description: "Date as YYYY-MM-DD, or omit if not found") var date: String?
    @Guide(description: "GST-inclusive grand total, positive number") var total: Double
    @Guide(description: "Printed GST amount, or omit if none printed") var gst: Double?
    @Guide(description: "One of: meals, groceries, fuel, software, office, home, health, travel, income")
    var category: String
    @Guide(description: "0-100 deductible percent, or omit") var deductible: Int?
    @Guide(description: "Purchased products only; exclude ABN/store/payment/totals/promos", .count(0...50))
    var lineItems: [FMLineItem]
    @Guide(description: "0..1 confidence") var confidence: Double
}

@available(iOS 26, *)
@Generable
struct FMLineItem {
    @Guide(description: "Product name") var name: String
    @Guide(description: "Line total in dollars") var price: Double
}

/// On-device extraction via Apple Foundation Models (guided generation).
@available(iOS 26, *)
struct FoundationModelExtractor: OnDeviceExtracting {
    func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt {
        let instructions = """
        You extract structured data from noisy Australian receipt OCR text. AUD only.
        category MUST be one of: meals, groceries, fuel, software, office, home, health, travel, income.
        total is the GST-inclusive grand total. If a GST amount is printed, use it exactly.
        lineItems are ONLY purchased products — exclude ABN/store/contact, payment/card/EFTPOS/
        change, subtotals/totals, counts, and promos. Repair split decimals (e.g. 19 90 -> 19.90).
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Receipt (rows):\n" + (layoutText.isEmpty ? ocrText : layoutText)
        // respond(to:generating:) verified against the iOS 26.5 SDK; returns Response<Content>.content.
        let result = try await session.respond(to: prompt, generating: FMReceipt.self)
        let r = result.content
        return FoundationModelMapping.toReceipt(
            merchant: r.merchant, date: r.date, total: r.total, gst: r.gst,
            category: r.category, deductible: r.deductible,
            items: r.lineItems.map { ($0.name, $0.price) },
            confidence: r.confidence, capturedAt: capturedAt,
            // Guard's printedGst needs the GST label paired with its amount on ONE line.
            // Prefer the row-paired layoutText — raw OCR order scrambles the GST label and
            // its amount onto SEPARATE lines, so printedGst can't recover it from raw text.
            ocrText: layoutText.isEmpty ? ocrText : layoutText)
    }
}
#endif

/// Capability gate + factory. Returns a Foundation Models extractor only when the framework is
/// present AND the device/OS/Apple-Intelligence state allows it; otherwise nil (non-FM path).
enum OnDeviceAI {
    static func makeExtractor() -> OnDeviceExtracting? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return FoundationModelExtractor()
            default: return nil   // .deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady
            }
        }
        #endif
        return nil
    }
}
