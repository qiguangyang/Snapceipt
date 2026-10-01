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

    @Test("issue records the invoice total as an income transaction (positive, category income)")
    func issueRecordsIncome() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.issueInvoiceHandler = { _ in
            IssueInvoiceResponse(pdfUrl: "/invoices/dl/tok", number: "INV-0010",
                                 status: "issued", issueDate: "2026-06-19", dueDate: "2026-07-03",
                                 issuedAt: 999, subtotalCents: 50_00, gstCents: 5_00, totalCents: 55_00,
                                 expiresAt: 1)
        }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine()
        v.lineItems[0].itemDescription = "Widget"
        v.lineItems[0].quantity = 2
        v.lineItems[0].unitPriceCents = 25_00
        _ = await v.issue(api: mock)

        let income = try ctx.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.source == "invoice" && $0.deletedAt == nil }))
        #expect(income.count == 1)
        #expect(income.first?.amountCents == 55_00)       // positive ⇒ income
        #expect(income.first?.catKey == CategoryKey.income.rawValue)
        #expect(income.first?.note == "Invoice INV-0010")
        #expect(sync.calls.contains { $0.op == "upsert" && $0.entityType == .transaction })

        // The income transaction carries the invoice's line items (line total, qty).
        let txnId = try #require(income.first?.id)
        let items = try ctx.fetch(FetchDescriptor<LineItem>(
            predicate: #Predicate { $0.transactionId == txnId && $0.deletedAt == nil }))
        #expect(items.count == 1)
        #expect(items.first?.name == "Widget")
        #expect(items.first?.quantity == 2)
        #expect(items.first?.priceCents == 50_00)         // 2 × $25 line total
        #expect(sync.calls.contains { $0.op == "upsert" && $0.entityType == .lineItem })
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

    @Test("send success applies emailed/pdfUrl + returns true")
    func sendSucceeds() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.sendInvoiceHandler = { _ in SendInvoiceResponse(pdfUrl: "/invoices/dl/sent", emailed: true) }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].unitPriceCents = 50_00
        let ok = await v.send(api: mock)
        #expect(ok == true)
        #expect(mock.sendInvoiceCalls.count == 1)
        #expect(v.emailed == true)
        #expect(v.pdfUrl == "/invoices/dl/sent")
        #expect(v.errorMessage == nil)
    }

    @Test("send failure surfaces errorMessage + returns false")
    func sendFails() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.sendInvoiceHandler = { _ in throw APIError(code: "X", message: "no client email", status: 400) }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 10_00
        let ok = await v.send(api: mock)
        #expect(ok == false)
        #expect(v.errorMessage != nil)
        #expect(v.emailed == false)
    }

    @Test("generatePdf calls invoicePdf once, sets pdfUrl, returns the url")
    func generatePdfSucceeds() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.invoicePdfHandler = { _ in InvoicePdfResponse(pdfUrl: "/invoices/dl/fresh", expiresAt: 1) }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].unitPriceCents = 50_00
        let url = await v.generatePdf(api: mock)
        #expect(url == "/invoices/dl/fresh")
        #expect(v.pdfUrl == "/invoices/dl/fresh")
        #expect(mock.invoicePdfCalls.count == 1)
        #expect(v.errorMessage == nil)
    }

    @Test("generatePdf failure surfaces errorMessage + returns nil")
    func generatePdfFails() async throws {
        let (ctx, sync) = try makeFixture()
        let mock = MockAPIClient()
        mock.invoicePdfHandler = { _ in throw APIError(code: "X", message: "boom", status: 500) }
        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: "a@acme.com")
        v.addLine(); v.lineItems[0].unitPriceCents = 50_00
        let url = await v.generatePdf(api: mock)
        #expect(url == nil)
        #expect(v.errorMessage != nil)
    }

    @Test("canEmail reflects whether the client has a usable email (drives Send vs Save PDF)")
    func canEmailReflectsClient() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync); v.load(id: nil)
        #expect(v.canEmail == false)                 // no client yet
        v.setClient(name: "Acme", email: "   ")      // whitespace-only ⇒ still false
        #expect(v.canEmail == false)
        v.setClient(name: "Acme", email: "a@acme.com")
        #expect(v.canEmail == true)
    }

    @Test("fresh invoice uses the profile GST rate (15%) for totals + snapshots it on save")
    func freshInvoiceUsesProfileRate() throws {
        let (ctx, sync) = try makeFixture()
        // A 15% (NZ) profile keyed "p1" — the rate the VM resolves for a fresh invoice.
        let p = Profile(userId: "u1", name: "Biz", type: "business",
                        accent1: "#0", accent2: "#1", accent3: "#2", gstRateBp: 1500)
        p.id = "p1"
        ctx.insert(p); try ctx.save()

        let v = vm(ctx, sync); v.load(id: nil)
        v.setClient(name: "Acme", email: nil)
        v.addLine(); v.lineItems[0].unitPriceCents = 200_00   // $200 ex-GST
        // 15% of $200 = $30 GST; total $230.
        #expect(v.totals.gst == 30_00)
        #expect(v.totals.total == 230_00)
        v.saveDraft()
        #expect(v.gstRateBp == 1500)
        let inv = try ctx.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(inv.gstRateBp == 1500)
        #expect(inv.gstCents == 30_00)
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

    @Test func selectionPersistsClientId() throws {
        let (ctx, sync) = try makeFixture()
        let picker = ClientPickerViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        let client = try #require(picker.create(name: "Acme", email: "old@example.com"))
        let editor = InvoiceEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        editor.load(id: nil)
        editor.setClient(ClientSelection(client))
        editor.saveDraft()
        let loaded = InvoiceEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
        loaded.load(id: editor.invoiceId)
        #expect(loaded.clientId == client.id)
        #expect(loaded.clientName == "Acme" && loaded.clientEmail == "old@example.com")
        #expect(sync.calls.first?.entityType == .client)
        loaded.setClient(name: "Legacy", email: nil)
        loaded.saveDraft()
        #expect(loaded.clientId == nil)
    }

    @Test func scopedClientLinksAndDeletedHistory() throws {
        let (ctx, sync) = try makeFixture()
        let live = Client(userId: "u1", profileId: "p1", name: "Live")
        let foreign = Client(userId: "u2", profileId: "p1", name: "Foreign")
        let other = Client(userId: "u1", profileId: "p2", name: "Other")
        let deleted = Client(userId: "u1", profileId: "p1", name: "Deleted", deletedAt: 1)
        for client in [live, foreign, other, deleted] { ctx.insert(client) }
        try ctx.save()
        let v = vm(ctx, sync); v.load(id: nil)
        for client in [foreign, other, deleted] {
            v.setClient(ClientSelection(client))
            #expect(v.saveDraft() == false)
            #expect(v.errorMessage != nil && sync.calls.isEmpty)
        }
        v.setClient(ClientSelection(live))
        #expect(v.saveDraft())
        let id = v.invoiceId
        try ClientStore(context: ctx, sync: sync, userId: "u1", profileId: "p1").delete(id: live.id)
        let loaded = vm(ctx, sync); loaded.load(id: id)
        #expect(loaded.clientId == live.id && loaded.saveDraft())
    }

    @Test func saveFailureDoesNotEnqueueDraft() throws {
        let (ctx, sync) = try makeFixture()
        struct Failure: Error {}
        let v = InvoiceEditorViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure() })
        v.load(id: nil); v.setClient(name: "Acme", email: nil)
        #expect(v.saveDraft() == false)
        #expect(v.errorMessage != nil && sync.calls.isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Invoice>()).isEmpty)
    }
}
