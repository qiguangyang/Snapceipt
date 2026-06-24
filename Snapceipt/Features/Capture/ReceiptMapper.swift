import Foundation

/// Pure mapping from the editable draft to a `Transaction` + its `LineItem`s.
/// No `ModelContext` — the caller inserts + enqueues. Sign by income, dollars→cents,
/// gst nil→nil, mode lowercase passthrough, line-item cents/sortOrder/quantity.
enum ReceiptMapper {
    static func map(_ draft: ExtractedReceipt,
                    mode: String, profileId: String, userId: String) -> (Transaction, [LineItem]) {
        let magnitude = cents(draft.total)
        // total >= 0 always; expense negative, income positive.
        let signed = draft.categoryKey == CategoryKey.income.rawValue ? magnitude : -magnitude

        // GST authority rule: gst-free ⇒ 0/nil; else honor the printed line as the
        // manual/printed amount (provenance "printed" when a line was extracted).
        let treatment: GstTreatment.Result = draft.gstFree
            ? GstTreatment.applyGstFree(true, totalCents: magnitude)
            : GstTreatment.Result(gstCents: draft.gst.map(cents),
                                  gstSource: draft.gst != nil ? "printed" : nil)

        let txn = Transaction(
            userId: userId,
            profileId: profileId,
            merchant: draft.merchant,
            catKey: draft.categoryKey,
            amountCents: signed,
            currency: draft.currencyCode,
            txnDate: draft.date,
            mode: mode.lowercased(),
            taxLabel: draft.taxLabel,
            deductiblePct: draft.deductible,
            paymentMethod: draft.paymentMethod,
            isAi: true,
            gstCents: treatment.gstCents,
            gstFree: draft.gstFree,
            capital: draft.capital,
            gstSource: treatment.gstSource,
            source: "scan",
            extractionStatus: draft.extractionStatus
        )

        let items = draft.lineItems.enumerated().map { index, li in
            LineItem(
                userId: userId,
                transactionId: txn.id,
                name: li.name,
                priceCents: cents(li.price),
                quantity: 1,
                sortOrder: index
            )
        }
        return (txn, items)
    }

    /// Dollars → cents with round-half-up (matches the backend
    /// `Math.round(n*100)/100` on a non-negative dollar amount; `total >= 0` always,
    /// so the sign-asymmetry of `.plain` vs `Math.round` is never hit).
    static func cents(_ dollars: Decimal) -> Int {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}
