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

        // Determine whether real geometry is available (any non-zero box).
        let hasGeometry = lines.contains { $0.boundingBox != .zero }

        // Merchant: use geometry when available (topmost = greatest maxY); else
        // fall back to first letter-rich, non-noise line (text-only path).
        let headerStop = ["tax invoice", "invoice", "receipt", "customer copy", "merchant copy", "eftpos", "duplicate"]
        let isMerchantCandidate: (RecognizedLine) -> Bool = { rl in
            let l = rl.text.lowercased()
            let letters = rl.text.filter { $0.isLetter }.count
            return letters >= 3 && !l.contains("www") && !rl.text.contains("@")
                && !isDateLine(rl.text) && !headerStop.contains(where: { l.contains($0) })
        }
        if hasGeometry {
            // Top of receipt = largest boundingBox.maxY (origin is bottom-left).
            result.merchant = lines
                .filter { isMerchantCandidate($0) }
                .max(by: { $0.boundingBox.maxY < $1.boundingBox.maxY })?.text
                ?? texts.first ?? ""
        } else {
            result.merchant = texts.first(where: { line in
                let l = line.lowercased()
                let letters = line.filter { $0.isLetter }.count
                return letters >= 3 && !l.contains("www") && !line.contains("@")
                    && !isDateLine(line) && !headerStop.contains(where: { l.contains($0) })
            }) ?? texts.first ?? ""
        }

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
        // When geometry is present and no explicit "total" line exists, prefer the
        // amount on the tallest (biggest font = greatest boundingBox.height) non-tender
        // line; fall back to max value if all heights are equal.
        let nonDate = texts.filter { !isDateLine($0) }
        let nonDateLines = lines.filter { !isDateLine($0.text) }
        let totalLines = nonDate.filter { line in
            let l = line.lowercased()
            return l.contains("total") && !l.contains("subtotal") && !l.contains("sub total")
        }
        let usedTotalLine: Bool
        if let t = maxAmount(totalLines), t > 0 {
            result.total = t; usedTotalLine = true
        } else if hasGeometry {
            // Geometry tiebreak: among non-tender, non-date lines with amounts,
            // pick the amount on the line with the greatest boundingBox.height.
            let nonTenderLines = nonDateLines.filter {
                $0.text.range(of: tenderRe, options: .regularExpression) == nil
            }
            // For each candidate line, find its max amount.
            let candidates: [(amount: Decimal, height: CGFloat)] = nonTenderLines.compactMap { rl in
                guard let amt = amounts(in: rl.text).max(), amt > 0 else { return nil }
                return (amount: amt, height: rl.boundingBox.height)
            }
            if let best = candidates.max(by: {
                $0.height != $1.height ? $0.height < $1.height : $0.amount < $1.amount
            }) {
                result.total = best.amount
            } else {
                result.total = 0
            }
            usedTotalLine = false
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
        // Group split observations into visual rows first — Apple Vision routinely
        // emits an item's name (left) and its right-column price as SEPARATE
        // observations, so "Flat White" + "5.00" on the same row must be paired into
        // one "Flat White 5.00" item. Without geometry (zero boxes) the per-line texts
        // are used unchanged.
        let priceTokenRe = #"(?:\$\s*)?\d{1,3}(?:[ ,]\d{3})*[.,]\d{2}\s*$"#
        for line in rowTexts(lines) {
            if line == result.merchant { continue }
            if line.range(of: tenderRe, options: .regularExpression) != nil { continue }
            if isDateLine(line) { continue }
            let letters = line.filter { $0.isLetter }.count
            guard letters >= 2, let price = amounts(in: line).last else { continue }
            let name = line.replacingOccurrences(of: priceTokenRe, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            result.lineItems.append((name: name, price: price))
        }

        // Category: inferred from merchant name and line text.
        result.category = ReceiptCategoryHeuristic.infer(merchant: result.merchant, lineTexts: texts)

        // Confidence: graded from 0.3 base + signals found.
        var confidence = 0.3
        if usedTotalLine { confidence += 0.2 }
        if dateFound { confidence += 0.1 }
        if gstPrinted { confidence += 0.1 }
        if result.category != .office { confidence += 0.05 }
        result.confidence = min(0.75, confidence)

        return result
    }

    /// Group OCR observations into visual rows when geometry is present, returning one
    /// combined left-to-right text per row. Vision often splits an item's name and its
    /// right-column price into separate observations; grouping by row pairs them so
    /// line-item extraction sees "name price" together. Without geometry (all boxes
    /// `.zero`, e.g. text-only callers/tests) the per-observation texts are returned
    /// unchanged, so existing behaviour is preserved.
    private static func rowTexts(_ lines: [RecognizedLine]) -> [String] {
        guard lines.contains(where: { $0.boundingBox != .zero }) else {
            return lines.map { $0.text }
        }
        // Vision origin is bottom-left → larger midY = higher on the receipt.
        let sorted = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            // Same-row observations are adjacent in this sort, so compare to the last row.
            if let lastIdx = rows.indices.last,
               rows[lastIdx].contains(where: { sameRow($0.boundingBox, line.boundingBox) }) {
                rows[lastIdx].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map { $0.text }
                .joined(separator: " ")
        }
    }

    /// Two boxes share a visual row when their vertical ranges overlap by more than
    /// 40% of the shorter box's height.
    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let minHeight = min(a.height, b.height)
        return minHeight > 0 && overlap > 0.4 * minHeight
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
