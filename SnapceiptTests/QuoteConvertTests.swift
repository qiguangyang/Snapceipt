import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("Quote convert + shareLink")
struct QuoteConvertTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }
    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> QuoteEditorViewModel {
        QuoteEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    /// Build a saved, SENT quote with 2 lines so it is convert-eligible.
    private func sentQuote(_ ctx: ModelContext, _ sync: MockSyncEngine) -> QuoteEditorViewModel {
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.gstInclusive = false
        v.addLine(); v.lineItems[0].itemDescription = "Design"; v.lineItems[0].quantity = 2; v.lineItems[0].unitPriceCents = 100_00
        v.addLine(); v.lineItems[1].itemDescription = "Hosting"; v.lineItems[1].unitPriceCents = 30_00
        v.saveDraft()
        // Flip to sent in storage (a real send would do this server-side).
        let id = v.quoteId!
        let q = try! ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id }))[0]
        q.status = "sent"; try? ctx.save()
        let v2 = vm(ctx, sync); v2.load(id: id)
        return v2
    }

    @Test("shareLink saves, calls /quotes/:id/link, applies url/number, and issues (draft→sent)")
    func shareLink() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.quoteShareLinkHandler = { _ in
            QuoteShareLinkResponse(url: "https://api.snapceipt.cc/q/tok", number: "SN-0007")
        }
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 100_00
        #expect(v.canGeneratePdf == true)
        #expect(v.canConvert == false)              // draft: not convertible yet
        let url = await v.shareLink(api: mock)
        #expect(url == "https://api.snapceipt.cc/q/tok")
        #expect(mock.quoteShareLinkCalls.count == 1)
        #expect(v.pdfUrl == "https://api.snapceipt.cc/q/tok")
        #expect(v.number == "SN-0007")
        #expect(v.statusValue == .sent)             // sharing issues the quote
        #expect(v.canConvert == true)               // now convertible
        let q = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(q.number == "SN-0007")
        #expect(q.status == "sent")
        #expect(q.sentAt != nil)
    }

    @Test("convertToInvoice clones client + GST flags + line items into a draft invoice (due +14d)")
    func convertClones() throws {
        let (ctx, sync) = try makeFixture()
        let v = sentQuote(ctx, sync)
        #expect(v.canConvert == true)
        let invId = v.convertToInvoice()
        #expect(invId != nil)
        let inv = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == invId! }))[0]
        #expect(inv.status == "draft")
        #expect(inv.quoteId == v.quoteId)
        #expect(inv.clientName == "Acme")
        #expect(inv.clientEmail == "a@acme.com")
        #expect(inv.gstEnabled == true)
        #expect(inv.gstInclusive == false)
        // due = today + 14 days
        let today = ExportDateFormatter.shared.string(from: Date())
        let expected = ExportDateFormatter.shared.string(
            from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 14,
                to: ExportDateFormatter.shared.date(from: today)!)!)
        #expect(inv.dueDate == expected)
        let lines = try ctx.fetch(FetchDescriptor<InvoiceLineItem>(predicate: #Predicate { $0.invoiceId == invId! }))
            .sorted { $0.sortOrder < $1.sortOrder }
        #expect(lines.count == 2)
        #expect(lines[0].itemDescription == "Design")
        #expect(lines[0].quantity == 2)
        #expect(lines[0].unitPriceCents == 100_00)
        #expect(lines[1].itemDescription == "Hosting")
        // The quote now links to the invoice.
        let qid = v.quoteId!
        let q = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == qid }))[0]
        #expect(q.invoiceId == invId)
        // Enqueues the invoice + each line.
        #expect(sync.calls.contains { $0.entityType == .invoice && $0.op == "upsert" })
        #expect(sync.calls.filter { $0.entityType == .invoiceLineItem && $0.op == "upsert" }.count == 2)
    }

    @Test("convertToInvoice snapshots the quote's GST rate (15%) onto the invoice")
    func convertSnapshotsRate() throws {
        let (ctx, sync) = try makeFixture()
        // A 15% (NZ) profile keyed "p1" — the rate the quote snapshots on save.
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0", accent2: "#1", accent3: "#2", gstRateBp: 1500)
        p.id = "p1"
        ctx.insert(p); try ctx.save()

        let v = sentQuote(ctx, sync)
        #expect(v.gstRateBp == 1500)            // quote snapshotted the 15% rate
        let invId = v.convertToInvoice()
        #expect(invId != nil)
        let inv = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == invId! }))[0]
        #expect(inv.gstRateBp == 1500)          // invoice inherits the quote's rate
    }

    @Test("convert is idempotent: a second convert returns the same invoice id, no second invoice")
    func convertIdempotent() throws {
        let (ctx, sync) = try makeFixture()
        let v = sentQuote(ctx, sync)
        let first = v.convertToInvoice()
        // Reload so the VM observes the persisted invoiceId.
        let v2 = vm(ctx, sync); v2.load(id: v.quoteId)
        let second = v2.convertToInvoice()
        #expect(second == first)
        let invoices = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(invoices.count == 1)
    }

    @Test("convert not eligible for a draft quote (returns nil, no invoice)")
    func convertGated() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 100_00
        v.saveDraft()
        #expect(v.statusValue == .draft)
        #expect(v.canConvert == false)          // hidden while Draft
        #expect(v.convertToInvoice() == nil)
        let invoices = try ctx.fetch(FetchDescriptor<Invoice>())
        #expect(invoices.isEmpty)
    }

    @Test func convertPreservesClientLinkAndQuoteSnapshot() throws {
        let (ctx, sync) = try makeFixture()
        let client = Client(userId: "u1", profileId: "p1", name: "Original", email: "old@example.com")
        ctx.insert(client); try ctx.save()
        let v = sentQuote(ctx, sync)
        let qid = try #require(v.quoteId)
        let q = try #require(ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == qid })).first)
        q.clientId = client.id
        q.clientName = "Original"; q.clientEmail = "old@example.com"
        try ctx.save()
        _ = try ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1").save(id: client.id, draft: ClientDraft(name: "Renamed", email: "new@example.com"))
        v.load(id: qid)
        // Conversion must use the stored quote, even if the editor's working snapshot differs.
        v.setClient(name: "Unsaved other contact", email: "unsaved@example.com")
        let iid = try #require(v.convertToInvoice())
        let inv = try #require(ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == iid })).first)
        #expect(inv.clientId == client.id)
        #expect(inv.clientName == "Original" && inv.clientEmail == "old@example.com")
    }

    @Test func convertDoesNotCreateNewLinkToDeletedClient() throws {
        let (ctx, sync) = try makeFixture()
        let client = Client(userId: "u1", profileId: "p1", name: "Original")
        ctx.insert(client); try ctx.save()
        let v = sentQuote(ctx, sync)
        let qid = try #require(v.quoteId)
        let q = try #require(ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == qid })).first)
        q.clientId = client.id; try ctx.save()
        try ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1").delete(id: client.id)
        v.load(id: qid)
        sync.calls.removeAll()
        #expect(v.convertToInvoice() == nil && v.errorMessage != nil)
        #expect(try ctx.fetch(FetchDescriptor<Invoice>()).isEmpty)
        #expect(q.clientId == client.id && q.status == "sent" && sync.calls.isEmpty)
    }
}
