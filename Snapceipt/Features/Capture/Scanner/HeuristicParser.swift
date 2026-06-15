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
    var category: CategoryKey = .office
    var confidence: Double = 0.3
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
