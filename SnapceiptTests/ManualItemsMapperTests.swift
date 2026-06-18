import Testing
import Foundation
@testable import Snapceipt

/// Pure mapping for manual line-item entry: the running sum, the persisted set,
/// and the incomplete-row guard. Mirrors `ReceiptMapperTests` (Swift Testing).
struct ManualItemsMapperTests {

    private func draft(_ id: String, _ name: String, _ price: String) -> ItemDraft {
        ItemDraft(id: id, name: name, priceText: price)
    }

    // MARK: totalCents

    @Test("totalCents sums every row's price; blank/invalid prices count as 0")
    func totalSumsAllRows() {
        let items = [draft("a", "Coffee", "4.50"),
                     draft("b", "Sandwich", "12.00"),
                     draft("c", "", ""),            // blank row -> 0
                     draft("d", "Parking", "")]     // named, no price -> 0
        #expect(ManualItemsMapper.totalCents(items) == 1650)
    }

    @Test("totalCents rounds dollars→cents half-up via ReceiptMapper.cents")
    func totalRounds() {
        #expect(ManualItemsMapper.totalCents([draft("a", "X", "1.999")]) == 200)
        #expect(ManualItemsMapper.totalCents([]) == 0)
    }

    @Test("a negative (pasted) price is clamped to 0 — total, persisted priceCents, and the Save guard all stay sane")
    func negativePriceClamped() {
        // A line item can't have a negative price in this UI; a pasted "-5.00" must
        // not subtract from the total, persist a negative, or slip past hasIncompleteRow.
        #expect(ManualItemsMapper.totalCents([draft("a", "X", "-5.00")]) == 0)
        let out = ManualItemsMapper.lineItems(from: [draft("a", "X", "-5.00")], txnId: "t", userId: "u")
        #expect(out.first?.priceCents == 0)
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "", "-5.00")]) == false)
    }

    // MARK: lineItems

    @Test("lineItems drops unnamed rows, trims names, gap-free sortOrder, qty 1, carries id/parent/user")
    func lineItemsMapped() {
        let items = [draft("a", "  Coffee  ", "4.50"),
                     draft("b", "", "9.99"),     // unnamed -> dropped
                     draft("c", "Tip", "")]       // named, $0 -> kept
        let out = ManualItemsMapper.lineItems(from: items, txnId: "txn1", userId: "u9")

        #expect(out.count == 2)
        #expect(out[0].id == "a")
        #expect(out[0].name == "Coffee")          // trimmed
        #expect(out[0].priceCents == 450)
        #expect(out[0].quantity == 1)
        #expect(out[0].sortOrder == 0)
        #expect(out[0].transactionId == "txn1")
        #expect(out[0].userId == "u9")
        #expect(out[0].profileId == nil)
        #expect(out[1].id == "c")
        #expect(out[1].name == "Tip")
        #expect(out[1].priceCents == 0)
        #expect(out[1].sortOrder == 1)            // gap-free (c was index 2 in drafts)
    }

    // MARK: hasIncompleteRow

    @Test("hasIncompleteRow flags a priced row with no name, and only that")
    func incompleteRow() {
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "", "5.00")]) == true)
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "   ", "5.00")]) == true)  // whitespace name
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "", "")]) == false)        // blank row
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "Tip", "")]) == false)     // named $0
        #expect(ManualItemsMapper.hasIncompleteRow([draft("a", "Coffee", "4.50")]) == false)
    }
}
