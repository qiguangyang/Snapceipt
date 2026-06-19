import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("InvoiceEditorViewModel")
struct InvoiceEditorViewModelTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }
    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> InvoiceEditorViewModel {
        InvoiceEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    @Test("load(nil): fresh draft, gst on, due = today+14, not issuable until valid")
    func loadNew() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        #expect(v.lineItems.isEmpty)
        #expect(v.gstEnabled == true)
        #expect(v.canIssue == false)
        #expect(v.dueDate == QuoteEditorViewModel.dueDatePlus14())
    }

    @Test("addLine + client makes it issuable; totals compute")
    func issuable() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].quantity = 2; v.lineItems[0].unitPriceCents = 100_00
        #expect(v.canIssue == true)
        #expect(v.totals.total == 220_00)
    }

    @Test("saveDraft persists invoice + lines and enqueues upserts")
    func saveDraft() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].itemDescription = "A"; v.lineItems[0].unitPriceCents = 50_00
        v.saveDraft()
        let invoices = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(invoices.count == 1)
        #expect(invoices[0].profileId == "p1")
        #expect(invoices[0].totalCents == 55_00)
        #expect(invoices[0].dueDate == v.dueDate)
        let lines = try ctx.fetch(FetchDescriptor<InvoiceLineItem>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(lines.count == 1)
        #expect(sync.calls.filter { $0.entityType == .invoice && $0.op == "upsert" }.count == 1)
        #expect(sync.calls.filter { $0.entityType == .invoiceLineItem && $0.op == "upsert" }.count == 1)
    }

    @Test("removing a line soft-deletes it + enqueues a line delete")
    func removeLine() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].itemDescription = "A"; v.lineItems[0].unitPriceCents = 10_00
        v.addLine(); v.lineItems[1].itemDescription = "B"; v.lineItems[1].unitPriceCents = 20_00
        v.saveDraft()
        let id = v.invoiceId!
        let v2 = vm(ctx, sync); v2.load(id: id)
        v2.removeLine(v2.lineItems[0]); v2.saveDraft()
        let live = try ctx.fetch(FetchDescriptor<InvoiceLineItem>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.count == 1)
        #expect(sync.calls.contains { $0.entityType == .invoiceLineItem && $0.op == "delete" })
    }

    @Test("issue saves, flushes, calls issueInvoice once, applies number/status/dates/totals")
    func issue() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        var flushAtIssue = -1
        mock.issueInvoiceHandler = { _ in
            flushAtIssue = sync.flushCount
            return IssueInvoiceResponse(pdfUrl: "/invoices/dl/tok", number: "INV-0009",
                                        status: "issued", issueDate: "2026-06-19", dueDate: "2026-07-03",
                                        issuedAt: 999, subtotalCents: 50_00, gstCents: 5_00, totalCents: 55_00,
                                        expiresAt: 1)
        }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].unitPriceCents = 50_00
        let ok = await v.issue(api: mock)
        #expect(ok == true)
        #expect(flushAtIssue == 1)            // flushed before the issue call
        #expect(mock.issueInvoiceCalls.count == 1)
        #expect(v.number == "INV-0009")
        #expect(v.status == "issued")
        #expect(v.pdfUrl == "/invoices/dl/tok")
        let inv = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(inv.number == "INV-0009")
        #expect(inv.status == "issued")
        #expect(inv.issueDate == "2026-06-19")
        #expect(inv.issuedAt == 999)
        #expect(inv.totalCents == 55_00)
    }

    @Test("issue failure keeps the invoice a draft + sets errorMessage")
    func issueFails() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.issueInvoiceHandler = { _ in throw APIError(code: "X", message: "boom", status: 500) }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 10_00
        let ok = await v.issue(api: mock)
        #expect(ok == false)
        #expect(v.errorMessage != nil)
        #expect(v.status == "draft")
    }

    @Test("badge derives from the invoice's payments (issued + partial)")
    func badge() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 100_00
        v.saveDraft()
        let id = v.invoiceId!
        let inv = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }))[0]
        inv.status = "issued"; inv.dueDate = "2030-01-01"   // far future -> not overdue
        ctx.insert(Payment(userId: "u1", invoiceId: id, amountCents: 40_00, paidOn: "2026-06-18"))
        try ctx.save()
        let v2 = vm(ctx, sync); v2.load(id: id)
        #expect(v2.badge == .partial)
    }
}
