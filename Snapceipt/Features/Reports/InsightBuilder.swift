import Foundation

/// On-device, always-truthful, mode-aware insight for the Reports card. Computes a
/// top-category line and/or a period-over-period delta from the period's data. NO
/// network / AI (spec defers real AI insights beyond v1). (spec §4.6)
enum InsightBuilder {
    enum Mode { case business, personal }

    /// Build the insight string. `window` is the current period; `prevWindow` is the
    /// same-length immediately-prior period (used for the delta). `periodWord` is the
    /// noun for the window ("month"/"quarter"/"year") so the copy ("this <word>" /
    /// "last <word>") stays truthful for whichever period the caller selected — never
    /// "this month" over a quarter/FY window. Empty data -> fallback.
    static func insight(mode: Mode, txns: [TransactionQuery.Txn],
                        window: Period.Window, prevWindow: Period.Window,
                        periodWord: String = "period") -> String {
        let cats = TransactionQuery.byCategory(txns, window: window)
        guard let top = cats.first else {
            return "Add a few receipts and your insights will appear here."
        }

        let label = catLabel(top.catKey)
        var line = "\(label) is your biggest expense this \(periodWord) — \(fmt(top.spendCents))."

        // Period-over-period delta (current vs prior window total expense).
        let cur = TransactionQuery.netSaved(txns, window: window).expenseCents
        let prevTotal = TransactionQuery.netSaved(txns, window: prevWindow).expenseCents
        if prevTotal > 0 {
            let diff = cur - prevTotal
            if diff != 0 {
                let dir = diff < 0 ? "less" : "more"
                line += " You spent \(fmt(abs(diff))) \(dir) than last \(periodWord)."
            }
        }
        return line
    }

    /// Human label for a catKey via CATS, falling back to the raw key.
    private static func catLabel(_ key: String) -> String {
        if let ck = CategoryKey(rawValue: key), let meta = CATS[ck] { return meta.label }
        return key.capitalized
    }
}
