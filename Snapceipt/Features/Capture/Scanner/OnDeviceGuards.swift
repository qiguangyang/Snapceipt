import Foundation
import CoreGraphics

/// Minimal deterministic safety net for an on-device LLM result (it's a small model and can
/// hallucinate). Mirrors the server's GST reconcile (src/lib/deepseek.ts reconcileGst): honor a
/// printed "GST $X" line; otherwise clamp an impossible model GST to total/11. NOT the old
/// HeuristicParser — just the AU-tax guard the cloud path also applies.
enum OnDeviceGuards {
    static func reconcile(_ r: ExtractedReceipt, ocrText: String) -> ExtractedReceipt {
        var out = r
        // The printed grand total is authoritative — the small FM model can be wrong (observed
        // adding GST on top of a GST-inclusive total). Fall back to FM's only when none is found
        // (or a 0 printed total, which preserves the total==0 → nil-GST contract).
        let printed = printedTotal(ocrText)
        out.total = (printed != nil && printed! > 0) ? printed! : max(0, r.total)
        out.gst = reconcileGst(r.gst, total: out.total, ocrText: ocrText)
        return out
    }

    /// Two-decimals dollar-amount pattern (parity with the server's printedGst `\.\d{2}`).
    private static let amountRegex = try! Regex(#"(\d{1,3}(?:[ ,]\d{3})*\.\d{2})"#)

    /// Collapse OCR whitespace that splits a decimal between digits ("4. 42" → "4.42") so the
    /// contiguous `amountRegex` can match; nothing else on the line is touched (contiguous case
    /// is a no-op).
    private static func joinSplitDecimals(_ line: Substring) -> String {
        String(line).replacing(#/(\d)\s*\.\s*(\d)/#) { "\($0.1).\($0.2)" }
    }

    /// Strips "$", ",", and spaces from a matched amount and parses it as `Decimal`.
    private static func amount(_ s: Substring) -> Decimal? {
        Decimal(string: s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: ""))
    }

    /// The last dollar amount on the LAST line containing the word "GST" (mirrors the server's
    /// printedGst); nil if no such line carries an amount.
    private static func printedGst(_ ocrText: String) -> Decimal? {
        var found: Decimal?
        for line in ocrText.split(whereSeparator: \.isNewline) {
            guard line.range(of: #"\bgst\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let normalized = joinSplitDecimals(line)
            let matches = normalized.matches(of: Self.amountRegex)
            if let last = matches.last, let v = amount(normalized[last.range]) {
                found = v
            }
        }
        return found
    }

    /// The largest cents-bearing amount on lines that name the grand total (whole word "total"),
    /// excluding lines that also name a non-grand-total figure (subtotal, GST, savings, etc.).
    /// nil if no qualifying line carries an amount. The FM total is wrong often enough that we
    /// prefer this whenever it's present and > 0.
    private static func printedTotal(_ ocrText: String) -> Decimal? {
        // Lines mentioning these alongside "total" are NOT the grand total.
        let excludeRegex = #"subtotal|sub total|\bgst\b|included|savings?|discount|balance|change"#
        var found: Decimal?
        for line in ocrText.split(whereSeparator: \.isNewline) {
            guard line.range(of: #"\btotal\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            if line.range(of: excludeRegex, options: [.regularExpression, .caseInsensitive]) != nil { continue }
            let normalized = joinSplitDecimals(line)
            // Largest amount on this line (e.g. "Total for 7 items: $34.87" → 34.87, not the 7).
            for match in normalized.matches(of: Self.amountRegex) {
                if let v = amount(normalized[match.range]) {
                    found = max(found ?? v, v)
                }
            }
        }
        return found
    }

    /// Geometry-based GST backstop: pair the "GST" label observation with the money observation on
    /// its SAME printed row, even when row reconstruction failed to merge them (columnar receipts).
    /// Picks the amount whose vertical center is closest to a GST label's center, among amounts to
    /// the label's right that are a plausible GST (`0 <= v <= total*0.12`). Returns nil without
    /// geometry or when no qualifying pair is found.
    static func geometricGst(lines: [RecognizedLine], total: Decimal) -> Decimal? {
        guard lines.contains(where: { $0.boundingBox != .zero }) else { return nil }
        let gstCap = total * Decimal(string: "0.12")!
        // GST label observations (line names "GST" as a whole word).
        let labels = lines.filter {
            $0.text.range(of: #"\bgst\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard !labels.isEmpty else { return nil }
        // Money observations: a single amount match, value within the plausible-GST window.
        struct MoneyObs { let value: Decimal; let box: CGRect }
        let amounts: [MoneyObs] = lines.compactMap { line in
            let normalized = joinSplitDecimals(Substring(line.text))
            let matches = normalized.matches(of: Self.amountRegex)
            guard matches.count == 1, let v = amount(normalized[matches[0].range]) else { return nil }
            guard v >= 0, v <= gstCap else { return nil }
            return MoneyObs(value: v, box: line.boundingBox)
        }
        guard !amounts.isEmpty else { return nil }
        var best: (dy: CGFloat, value: Decimal)?
        for label in labels {
            let lbox = label.boundingBox
            for m in amounts {
                guard m.box.minX >= lbox.minX - 1 else { continue }   // amount to the label's right
                let dy = abs(m.box.midY - lbox.midY)
                guard dy <= max(lbox.height, m.box.height) else { continue }   // same printed row
                if best == nil || dy < best!.dy { best = (dy, m.value) }
            }
        }
        return best.map { round2($0.value) }
    }

    /// Apply the geometric GST backstop to an extracted receipt: when a total is present and a
    /// geometric GST is found, return a copy with `gst` replaced. No-op otherwise.
    static func withGeometricGst(_ r: ExtractedReceipt, lines: [RecognizedLine]) -> ExtractedReceipt {
        guard r.total > 0, let g = geometricGst(lines: lines, total: r.total) else { return r }
        var out = r
        out.gst = g
        return out
    }

    /// Geometry-based grand-total backstop: pair the "Total" label (whole word, NOT "Subtotal")
    /// with the largest money amount on its SAME printed row. Independent of row reconstruction, so
    /// the model/row-merge can't corrupt the total. Returns nil without geometry or no qualifying pair.
    static func geometricTotal(lines: [RecognizedLine]) -> Decimal? {
        guard lines.contains(where: { $0.boundingBox != .zero }) else { return nil }
        let labels = lines.filter {
            $0.text.range(of: #"\btotal\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            && $0.text.range(of: #"sub[ ]?total"#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        guard !labels.isEmpty else { return nil }
        struct MoneyObs { let value: Decimal; let box: CGRect }
        let amounts: [MoneyObs] = lines.compactMap { line in
            let normalized = joinSplitDecimals(Substring(line.text))
            let matches = normalized.matches(of: Self.amountRegex)
            guard matches.count == 1, let v = amount(normalized[matches[0].range]), v > 0 else { return nil }
            return MoneyObs(value: v, box: line.boundingBox)
        }
        guard !amounts.isEmpty else { return nil }
        // Nearest-row amount to a Total label (tie → larger value, i.e. the grand total).
        var best: (dy: CGFloat, value: Decimal)?
        for label in labels {
            let lbox = label.boundingBox
            for m in amounts {
                guard m.box.minX >= lbox.minX - 1 else { continue }
                let dy = abs(m.box.midY - lbox.midY)
                guard dy <= max(lbox.height, m.box.height) else { continue }
                let better: Bool
                if let b = best {
                    better = dy < b.dy || (dy == b.dy && m.value > b.value)
                } else {
                    better = true
                }
                if better { best = (dy, m.value) }
            }
        }
        return best.map { round2($0.value) }
    }

    /// Apply the geometric total backstop: replace `total` with the geometry-paired grand total when
    /// one is found (> 0). No-op otherwise.
    static func withGeometricTotal(_ r: ExtractedReceipt, lines: [RecognizedLine]) -> ExtractedReceipt {
        guard let t = geometricTotal(lines: lines), t > 0 else { return r }
        var out = r
        out.total = t
        return out
    }

    /// Deterministic, LANGUAGE-INDEPENDENT line items for the on-device fallback used when Apple's
    /// model can't read the receipt (`unsupportedLanguageOrLocale` — common for non-English AU
    /// receipts). Parses the column-aligned layout rows: a row's trailing amount is the price; the
    /// text before it (minus a leading quantity) is the name. Skips total/tax/payment/meta rows and
    /// any amount equal to the grand total (a payment line). Keeps non-Latin names as-is.
    static func lineItems(fromLayout layoutText: String, total: Decimal) -> [ExtractedReceipt.LineItemDraft] {
        let excludeRegex = #"(?i)\b(sub ?total|total|gst|tax|change|cash|visa|eftpos|master ?card|amex|credit|debit|card|balance|tip|surcharge|round|payment|paid|tender|amount|qty|description|discount|savings?|zeller|tyro|square|account|approved|terminal|abn|invoice|receipt|date|time|server|table|guests?)\b"#
        var items: [ExtractedReceipt.LineItemDraft] = []
        for row in layoutText.split(whereSeparator: \.isNewline) {
            let normalized = joinSplitDecimals(row)
            guard let last = normalized.matches(of: Self.amountRegex).last,
                  let price = amount(normalized[last.range]), price > 0 else { continue }
            if total > 0, price == total { continue }   // a payment / grand-total line, not an item
            var name = String(normalized[..<last.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            name = name.replacing(#/^\d+\s+/#, with: "").trimmingCharacters(in: .whitespaces)  // drop leading qty
            guard name.range(of: #"\p{L}"#, options: .regularExpression) != nil,            // must have a letter
                  name.range(of: excludeRegex, options: .regularExpression) == nil else { continue }
            items.append(.init(name: name, price: round2(price)))
        }
        return items
    }

    /// Best-guess merchant for the fallback: the topmost (highest on the receipt) text line carrying
    /// letters and no amount. Any script — a non-English store name is kept verbatim.
    static func topMerchant(lines: [RecognizedLine]) -> String {
        let candidates = lines.filter { (line: RecognizedLine) -> Bool in
            guard line.boundingBox != .zero else { return false }
            let hasLetter = line.text.range(of: #"\p{L}"#, options: .regularExpression) != nil
            let hasAmount = !line.text.matches(of: Self.amountRegex).isEmpty
            return hasLetter && !hasAmount
        }
        guard let top = candidates.max(by: { $0.boundingBox.midY < $1.boundingBox.midY }) else { return "" }
        return top.text.trimmingCharacters(in: .whitespaces)
    }

    private static func reconcileGst(_ gst: Decimal?, total: Decimal, ocrText: String) -> Decimal? {
        guard total > 0 else { return nil }
        let cap = round2(total / 11)
        let printedCap = total * Decimal(string: "0.12")!   // surcharge/rounding allowance
        if let printed = printedGst(ocrText), printed >= 0, printed <= printedCap { return round2(printed) }
        if let gst, gst > cap + Decimal(string: "0.005")! { return cap }
        return gst
    }

    private static func round2(_ d: Decimal) -> Decimal {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        return r
    }
}
