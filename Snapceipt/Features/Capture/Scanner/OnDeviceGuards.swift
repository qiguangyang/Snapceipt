import Foundation

/// Minimal deterministic safety net for an on-device LLM result (it's a small model and can
/// hallucinate). Mirrors the server's GST reconcile (src/lib/deepseek.ts reconcileGst): honor a
/// printed "GST $X" line; otherwise clamp an impossible model GST to total/11. NOT the old
/// HeuristicParser — just the AU-tax guard the cloud path also applies.
enum OnDeviceGuards {
    static func reconcile(_ r: ExtractedReceipt, ocrText: String) -> ExtractedReceipt {
        var out = r
        out.total = max(0, r.total)
        out.gst = reconcileGst(r.gst, total: out.total, ocrText: ocrText)
        return out
    }

    /// Two-decimals dollar-amount pattern (parity with the server's printedGst `\.\d{2}`).
    private static let amountRegex = try! Regex(#"(\d{1,3}(?:[ ,]\d{3})*\.\d{2})"#)

    /// The last dollar amount on the LAST line containing the word "GST" (mirrors the server's
    /// printedGst); nil if no such line carries an amount.
    private static func printedGst(_ ocrText: String) -> Decimal? {
        var found: Decimal?
        for line in ocrText.split(whereSeparator: \.isNewline) {
            guard line.range(of: #"\bgst\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let matches = line.matches(of: Self.amountRegex)
            if let last = matches.last,
               let v = Decimal(string: String(line[last.range]).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")) {
                found = v
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
