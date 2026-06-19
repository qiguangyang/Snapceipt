import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("Quote convert + generatePdf")
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

    @Test("generatePdf saves, calls the route, persists pdfR2Key/number, leaves status draft")
    func generatePdf() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.generateQuotePdfHandler = { _ in
            GenerateQuotePdfResponse(pdfUrl: "/quotes/dl/tok", number: "SN-0007", expiresAt: 1)
        }
        let v = vm(ctx, sync)
        v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 100_00
        #expect(v.canGeneratePdf == true)
        let ok = await v.generatePdf(api: mock)
        #expect(ok == true)
        #expect(mock.generateQuotePdfCalls.count == 1)
        #expect(v.pdfUrl == "/quotes/dl/tok")
        #expect(v.number == "SN-0007")
        #expect(v.statusValue == .draft)            // status unchanged
        let q = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(q.number == "SN-0007")
        #expect(q.status == "draft")
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
        #expect(v.canConvert == false)
        #expect(v.convertToInvoice() == nil)
        let invoices = try ctx.fetch(FetchDescriptor<Invoice>())
        #expect(invoices.isEmpty)
    }
}
