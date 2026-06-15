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

    private static let dateDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func isDateLine(_ s: String) -> Bool {
        guard let d = dateDetector else { return false }
        let r = NSRange(s.startIndex..., in: s)
        return d.firstMatch(in: s, range: r)?.date != nil
    }

    static func parse(_ lines: [RecognizedLine]) -> ParsedReceipt {
        var result = ParsedReceipt()
        let texts = lines.map { $0.text }
        let joined = texts.joined(separator: "\n")

        // Tender/keyword exclusion regex used for both total calculation and line-items.
        let tenderRe = #"(?i)\b(total|subtotal|gst|tax|vat|change|cash|eftpos|balance|amount due|tendered|rounding)\b"#

        // Merchant: first line with >=3 letters that isn't web/email/date/header noise.
        let headerStop = ["tax invoice", "invoice", "receipt", "customer copy", "merchant copy", "eftpos", "duplicate"]
        result.merchant = texts.first(where: { line in
            let l = line.lowercased()
            let letters = line.filter { $0.isLetter }.count
            return letters >= 3 && !l.contains("www") && !line.contains("@")
                && !isDateLine(line) && !headerStop.contains(where: { l.contains($0) })
        }) ?? texts.first ?? ""

        // Date: NSDataDetector across the joined text.
        var dateFound = false
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(joined.startIndex..., in: joined)
            if let match = detector.firstMatch(in: joined, range: range), let d = match.date {
                result.date = d
                dateFound = true
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

        func maxAmount(_ ls: [String]) -> Decimal? { ls.flatMap(amounts).max() }

        // Total: unified algorithm with date-skip and tender exclusion.
        let nonDate = texts.filter { !isDateLine($0) }
        let totalLines = nonDate.filter { line in
            let l = line.lowercased()
            return l.contains("total") && !l.contains("subtotal") && !l.contains("sub total")
        }
        let usedTotalLine: Bool
        if let t = maxAmount(totalLines), t > 0 {
            result.total = t; usedTotalLine = true
        } else {
            let nonTender = nonDate.filter { $0.range(of: tenderRe, options: .regularExpression) == nil }
            result.total = maxAmount(nonTender) ?? 0; usedTotalLine = false
        }

        // GST: word-boundary regex to avoid "Taxi" matching "tax".
        let gstRe = #"(?i)\b(gst|tax|vat)\b"#
        let gstPrinted: Bool
        if let taxLine = texts.first(where: { $0.range(of: gstRe, options: .regularExpression) != nil }),
           let taxVal = amounts(in: taxLine).max() {
            result.tax = taxVal; gstPrinted = true
        } else if result.total > 0 {
            result.tax = roundedGST(result.total); gstPrinted = false
        } else { gstPrinted = false }

        // Line items: non-merchant, non-tender lines that have a price and a name.
        let priceTokenRe = #"(?:\$\s*)?\d{1,3}(?:[ ,]\d{3})*[.,]\d{2}\s*$"#
        for line in texts {
            if line == result.merchant { continue }
            if line.range(of: tenderRe, options: .regularExpression) != nil { continue }
            let letters = line.filter { $0.isLetter }.count
            guard letters >= 2, let price = amounts(in: line).last else { continue }
            let name = line.replacingOccurrences(of: priceTokenRe, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            result.lineItems.append((name: name, price: price))
        }

        // Category: inferred from merchant name and line text.
        result.category = ReceiptCategoryHeuristic.infer(merchant: result.merchant, lineTexts: texts)

        // Confidence: placeholder 0.3 for Task 5 (graded computation added in Task 6).
        result.confidence = 0.3

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
