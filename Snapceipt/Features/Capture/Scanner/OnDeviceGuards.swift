import Foundation

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
