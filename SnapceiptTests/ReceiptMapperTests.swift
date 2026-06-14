import Testing
import Foundation
@testable import Snapceipt

struct ReceiptMapperTests {
    private func draft(categoryKey: String, total: String, gst: String?,
                       deductible: Int?, items: [(String, String)] = []) -> ExtractedReceipt {
        ExtractedReceipt(
            merchant: "The Grounds", date: "2026-05-28",
            total: Decimal(string: total)!,
            gst: gst.map { Decimal(string: $0)! },
            categoryKey: categoryKey, deductible: deductible,
            lineItems: items.map { .init(name: $0.0, price: Decimal(string: $0.1)!) },
            confidence: 0.95, needsReview: false,
            paymentMethod: "Visip •••• 4242", taxLabel: "GST",
            extractionStatus: "done")
    }

    @Test("expense category negates amountCents; cents rounded from dollars")
    func expenseNegated() {
        let (txn, _) = ReceiptMapper.map(
            draft(categoryKey: "meals", total: "42.50", gst: "3.86", deductible: 50),
            mode: "personal", profileId: "p1", userId: "u1")
        #expect(txn.amountCents == -4250)
        #expect(txn.catKey == "meals")
        #expect(txn.gstCents == 386)
        #expect(txn.deductiblePct == 50)
        #expect(txn.currency == "AUD")
        #expect(txn.txnDate == "2026-05-28")
        #expect(txn.merchant == "The Grounds")
        #expect(txn.mode == "personal")
        #expect(txn.taxLabel == "GST")
        #expect(txn.paymentMethod == "Visip •••• 4242")
        #expect(txn.isAi == true)
        #expect(txn.source == "scan")
        #expect(txn.extractionStatus == "done")
        #expect(txn.profileId == "p1")
        #expect(txn.userId == "u1")
    }

    @Test("income category keeps a positive amountCents")
    func incomePositive() {
        let (txn, _) = ReceiptMapper.map(
            draft(categoryKey: "income", total: "1200.00", gst: nil, deductible: nil),
            mode: "business", profileId: "p2", userId: "u1")
        #expect(txn.amountCents == 120000)
        #expect(txn.gstCents == nil)         // nil gst -> nil gstCents
        #expect(txn.deductiblePct == nil)
        #expect(txn.mode == "business")
    }

    @Test("mode is lowercased at the boundary (uppercase input -> lowercase)")
    func modeLowercased() {
        let (txn, _) = ReceiptMapper.map(
            draft(categoryKey: "meals", total: "10.00", gst: nil, deductible: nil),
            mode: "Business", profileId: "p1", userId: "u1")
        #expect(txn.mode == "business")
    }

    @Test("line items map to cents, sortOrder=index, quantity=1, child userId; transactionId=parent")
    func lineItemsMapped() {
        let (txn, items) = ReceiptMapper.map(
            draft(categoryKey: "meals", total: "33.00", gst: "3.00", deductible: 50,
                  items: [("Flat White x2", "9.00"), ("Big Brekkie", "24.00")]),
            mode: "personal", profileId: "p1", userId: "u9")
        #expect(items.count == 2)
        #expect(items[0].name == "Flat White x2")
        #expect(items[0].priceCents == 900)
        #expect(items[0].sortOrder == 0)
        #expect(items[0].quantity == 1)
        #expect(items[0].userId == "u9")
        #expect(items[0].profileId == nil)
        #expect(items[0].transactionId == txn.id)
        #expect(items[1].priceCents == 2400)
        #expect(items[1].sortOrder == 1)
    }

    @Test("a printed GST line sets gstSource = printed; no GST line leaves it nil")
    func gstSourceFromCapture() {
        let withGst = ExtractedReceipt(
            merchant: "The Grounds", date: "2026-05-28", total: 42.50, gst: 3.86,
            categoryKey: "meals", deductible: 50, lineItems: [], confidence: 0.9, needsReview: false)
        let (t1, _) = ReceiptMapper.map(withGst, mode: "business", profileId: "p1", userId: "u1")
        #expect(t1.gstSource == "printed")
        #expect(t1.gstCents == 3_86)
        #expect(t1.gstFree == false)
        #expect(t1.capital == false)

        let noGst = ExtractedReceipt(
            merchant: "Cash sale", date: "2026-05-28", total: 10.00, gst: nil,
            categoryKey: "office", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
        let (t2, _) = ReceiptMapper.map(noGst, mode: "business", profileId: "p1", userId: "u1")
        #expect(t2.gstSource == nil)
        #expect(t2.gstCents == nil)
    }

    @Test("a gst-free draft maps to gstFree=true, gstCents=0, gstSource=nil")
    func gstFreeDraftMaps() {
        var draft = ExtractedReceipt(
            merchant: "Woolworths", date: "2026-05-28", total: 33.00, gst: 3.00,
            categoryKey: "groceries", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
        draft.gstFree = true
        let (t, _) = ReceiptMapper.map(draft, mode: "business", profileId: "p1", userId: "u1")
        #expect(t.gstFree == true)
        #expect(t.gstCents == 0)
        #expect(t.gstSource == nil)
    }

    @Test("a capital draft maps capital=true through to the txn")
    func capitalDraftMaps() {
        var draft = ExtractedReceipt(
            merchant: "Apple", date: "2026-05-28", total: 2200.00, gst: 200.00,
            categoryKey: "software", deductible: 100, lineItems: [], confidence: 0.9, needsReview: false)
        draft.capital = true
        let (t, _) = ReceiptMapper.map(draft, mode: "business", profileId: "p1", userId: "u1")
        #expect(t.capital == true)
    }
}
