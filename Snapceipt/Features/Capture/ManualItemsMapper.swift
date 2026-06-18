import Foundation

/// A single editable line on the manual-entry screen. A value type so the view
/// can bind `TextField`s and defer `LineItem` (`@Model`) creation to save —
/// mirroring how `AddManualView` builds its `Transaction` only on save.
struct ItemDraft: Identifiable, Equatable {
    let id: String
    var name: String
    var priceText: String

    init(id: String = Snapceipt.ID.uuidv7(), name: String = "", priceText: String = "") {
        self.id = id
        self.name = name
        self.priceText = priceText
    }
}

/// Pure mapping for manual line items — no `ModelContext`. Three predicates kept
/// deliberately separate so the running sum, the persisted set, and validation
/// can never disagree (see `2026-06-19-manual-entry-line-items-design.md`).
/// Reuses `ReceiptMapper.cents` for dollars→cents rounding.
enum ManualItemsMapper {

    /// Σ of every row's price — a blank/invalid price parses to 0 — so the
    /// auto-filled amount is literally the sum of whatever prices are typed.
    static func totalCents(_ items: [ItemDraft]) -> Int {
        items.reduce(0) { $0 + cents($1.priceText) }
    }

    /// One `LineItem` per row with a non-empty (trimmed) name. `sortOrder` is
    /// gap-free over the persisted rows; `quantity` is always 1 (matches the
    /// scan path). The draft's `id` carries through so edit-mode reconciliation
    /// can match it against the existing row.
    static func lineItems(from items: [ItemDraft], txnId: String, userId: String) -> [LineItem] {
        items
            .filter { !trimmed($0.name).isEmpty }
            .enumerated()
            .map { index, draft in
                LineItem(
                    id: draft.id,
                    userId: userId,
                    transactionId: txnId,
                    name: trimmed(draft.name),
                    priceCents: cents(draft.priceText),
                    quantity: 1,
                    sortOrder: index
                )
            }
    }

    /// A row with a price but no description still needs naming — blocks Save.
    static func hasIncompleteRow(_ items: [ItemDraft]) -> Bool {
        items.contains { cents($0.priceText) > 0 && trimmed($0.name).isEmpty }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dollars string → cents, reusing the scan path's rounding. Blank/invalid → 0.
    /// Clamped to non-negative: a line item can't have a negative price, and a pasted
    /// "-5.00" must not subtract from the total, persist a negative `priceCents`, or
    /// slip past `hasIncompleteRow` (which guards on `> 0`).
    private static func cents(_ priceText: String) -> Int {
        let cleaned = priceText.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned) else { return 0 }
        return max(0, ReceiptMapper.cents(value))
    }
}
