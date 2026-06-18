import Foundation

// MARK: - Wire types

/// Decoded `/extract` response (§9). All amounts are DOLLARS on the wire.
struct ExtractionResponse: Decodable {
    let requestId: String
    let receipt: ExtractedReceipt
    let meta: ExtractionMeta
}

/// Smart-scan usage counters echoed by the real `/extract` path.
/// Absent on stub/offline paths — always decode with `decodeIfPresent`.
struct SmartScanMeta: Decodable, Equatable {
    let used: Int
    let cap: Int
    let plan: String
}

/// `/extract` `meta` block.
struct ExtractionMeta: Decodable {
    let model: String
    let source: String
    let latencyMs: Int
    let attempts: Int
    let stub: Bool
    /// `true` when the monthly smart-scan cap was hit and a heuristic result
    /// was served instead of the LLM. Defaults to `false` when absent (stub /
    /// offline responses omit this field).
    let capped: Bool
    /// Usage counters for the smart-scan cap. Present on the real path;
    /// absent on stub/offline paths.
    let smartScan: SmartScanMeta?

    private enum CodingKeys: String, CodingKey {
        case model, source, latencyMs, attempts, stub, capped, smartScan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        source = try c.decode(String.self, forKey: .source)
        latencyMs = try c.decode(Int.self, forKey: .latencyMs)
        attempts = try c.decode(Int.self, forKey: .attempts)
        stub = try c.decode(Bool.self, forKey: .stub)
        capped = try c.decodeIfPresent(Bool.self, forKey: .capped) ?? false
        smartScan = try c.decodeIfPresent(SmartScanMeta.self, forKey: .smartScan)
    }
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
    /// User-editable GST treatment (spec §4.6). Defaulted so existing init/decode
    /// callers are unchanged; surfaced in ReviewStep.
    var gstFree: Bool = false
    var capital: Bool = false
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
         gstFree: Bool = false, capital: Bool = false,
         extractionStatus: String = "done") {
        self.merchant = merchant; self.date = date; self.total = total; self.gst = gst
        self.categoryKey = categoryKey; self.deductible = deductible
        self.lineItems = lineItems; self.confidence = confidence; self.needsReview = needsReview
        self.paymentMethod = paymentMethod; self.taxLabel = taxLabel
        self.gstFree = gstFree
        self.capital = capital
        self.extractionStatus = extractionStatus
    }
}

extension ExtractedReceipt {
    /// Build the draft from a successful `/extract` response. Status "done".
    init(response: ExtractionResponse) {
        self = response.receipt
        self.extractionStatus = "done"
    }

    /// Build the draft from the on-device heuristic. `extractionStatus` defaults to
    /// "pending" (offline fallback → reconciler re-extracts later); pass "done" for a
    /// deliberate Smart-Scan-OFF result so the reconciler never overwrites it.
    /// `needsReview = true`, low confidence; category/deductible default to the
    /// server fallback defaults ("office"/100). `date` falls back to `capturedAt`.
    init(parsed: ParsedReceipt, capturedAt: String, extractionStatus: String = "pending") {
        let iso = ExtractedReceipt.ymd(from: parsed.date) ?? capturedAt
        self.init(
            merchant: parsed.merchant,
            date: iso,
            total: parsed.total,
            gst: parsed.tax,
            categoryKey: parsed.category.rawValue,
            deductible: 100,
            lineItems: parsed.lineItems.map { LineItemDraft(name: $0.name, price: $0.price) },
            confidence: parsed.confidence,
            needsReview: true,
            extractionStatus: extractionStatus
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
