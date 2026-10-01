import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct RepeatWorkServiceTests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T23:30:00Z")!
    private func fixture() throws -> (ModelContext, MockSyncEngine, Client) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        context.autosaveEnabled = false
        let client = Client(userId: "u1", profileId: "p1", name: "Current", email: "new@test.com", mobilePhone: "123", address: "New address")
        context.insert(client)
        context.insert(Profile(id: "p1", userId: "u1", name: "Business", type: "business", accent1: "a", accent2: "b", accent3: "c", gstRegistered: false, gstRateBp: 1500))
        try context.save()
        return (context, MockSyncEngine(), client)
    }
    private func service(_ context: ModelContext, _ sync: any SyncEnqueuing) -> RepeatWorkService {
        RepeatWorkService(context: context, sync: sync, userId: "u1", profileId: "p1")
    }
    private func seedQuote(_ context: ModelContext, _ client: Client) throws -> Quote {
        let quote = Quote(userId: "u1", profileId: "p1", number: "Q-1", clientId: client.id, clientName: "Old", clientEmail: "old@test.com", clientAddress: "Old address", clientMobile: "456", gstEnabled: true, gstInclusive: true, subtotalCents: 2000, gstCents: 300, totalCents: 2300, currency: "NZD", status: "sent", validUntil: "2000-01-01", sentAt: 1, pdfR2Key: "old.pdf", invoiceId: "old-invoice", gstRateBp: 1500)
        context.insert(quote)
        context.insert(QuoteLineItem(userId: "u1", quoteId: quote.id, itemDescription: "Work", unitLabel: "hour", quantity: 2, unitPriceCents: 1150, sortOrder: 4))
        context.insert(QuoteLineItem(userId: "u1", quoteId: quote.id, itemDescription: "Deleted", unitPriceCents: 9, deletedAt: 1))
        context.insert(QuoteLineItem(userId: "other", quoteId: quote.id, itemDescription: "Foreign", unitPriceCents: 9))
        try context.save()
        return quote
    }
    private func snapshot(_ entity: any Syncable) -> String {
        let json = SyncEntityRegistry().encodePayload(entityType: entity.entityType, entity: entity)
        let fields = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    @Test func repeatsPaidInvoiceAsUnpaidDraft() throws {
        let (context, sync, client) = try fixture()
        let source = Invoice(userId: "u1", profileId: "p1", number: "INV-1", quoteId: "quote", clientId: client.id, clientName: "Old", gstEnabled: true, gstInclusive: true, subtotalCents: 2000, gstCents: 300, totalCents: 2300, currency: "NZD", status: "issued", issueDate: "2020-01-01", dueDate: "2020-01-15", issuedAt: 1, pdfR2Key: "old.pdf", gstRateBp: 1500)
        let line = InvoiceLineItem(userId: "u1", invoiceId: source.id, itemDescription: "Work", unitLabel: "hour", quantity: 2, unitPriceCents: 1150)
        context.insert(source); context.insert(line)
        context.insert(InvoiceLineItem(userId: "u1", invoiceId: source.id, itemDescription: "Deleted", unitPriceCents: 1, deletedAt: 1))
        context.insert(Payment(userId: "u1", invoiceId: source.id, amountCents: 2300, paidOn: "2020-01-02"))
        try context.save()
        let id = try service(context, sync).repeatInvoice(sourceId: source.id, now: now)
        let saved = ModelContext(context.container)
        let copy = try #require(saved.fetch(FetchDescriptor<Invoice>()).first { $0.id == id })
        #expect(id != source.id && copy.status == "draft")
        #expect(copy.number == nil && copy.quoteId == nil && copy.pdfR2Key == nil && copy.issueDate == nil && copy.issuedAt == nil)
        #expect(copy.dueDate == "2026-10-14")
        #expect(copy.clientId == client.id && copy.clientName == "Current" && copy.clientEmail == "new@test.com")
        #expect(copy.gstEnabled && copy.gstInclusive && copy.gstRateBp == 1500 && copy.currency == "NZD")
        #expect(copy.totalCents == 2300)
        let lines = try saved.fetch(FetchDescriptor<InvoiceLineItem>()).filter { $0.invoiceId == id }
        #expect(lines.count == 1 && lines[0].id != line.id && lines[0].unitLabel == "hour" && lines[0].quantity == 2 && lines[0].unitPriceCents == 1150)
        #expect(try saved.fetch(FetchDescriptor<Payment>()).count == 1)
        #expect(try saved.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(sync.calls.map(\.entityType) == [.invoice, .invoiceLineItem])
    }
    @Test func repeatsQuoteWithFreshValidity() throws {
        let (context, sync, client) = try fixture()
        let source = try seedQuote(context, client)
        let id = try service(context, sync).repeatQuote(sourceId: source.id, now: now)
        let copy = try #require(context.fetch(FetchDescriptor<Quote>()).first { $0.id == id })
        #expect(copy.validUntil == "2026-10-28" && copy.status == "draft")
        #expect(copy.number == nil && copy.sentAt == nil && copy.pdfR2Key == nil && copy.invoiceId == nil)
        #expect(copy.clientId == client.id && copy.clientName == "Current" && copy.clientEmail == "new@test.com" && copy.clientMobile == "123" && copy.clientAddress == "New address")
        #expect(copy.gstEnabled && copy.gstInclusive && copy.gstRateBp == 1500 && copy.currency == "NZD" && copy.totalCents == 2300)
        let lines = try context.fetch(FetchDescriptor<QuoteLineItem>()).filter { $0.quoteId == id }
        #expect(lines.count == 1 && lines[0].unitLabel == "hour" && lines[0].quantity == 2 && lines[0].unitPriceCents == 1150)
        #expect(sync.calls.map(\.entityType) == [.quote, .quoteLineItem])
    }
    @Test func repeatDoesNotModifySource() throws {
        let (context, sync, client) = try fixture()
        let source = try seedQuote(context, client)
        let before = snapshot(source)
        let lines = try context.fetch(FetchDescriptor<QuoteLineItem>())
        let snapshots = lines.map { snapshot($0) }
        _ = try service(context, sync).repeatQuote(sourceId: source.id, now: now)
        #expect(snapshot(source) == before)
        #expect(lines.map { snapshot($0) } == snapshots)
        let saved = ModelContext(context.container)
        #expect(snapshot(try #require(saved.fetch(FetchDescriptor<Quote>()).first { $0.id == source.id })) == before)
        let savedLines = try saved.fetch(FetchDescriptor<QuoteLineItem>())
        #expect(lines.map { original in snapshot(savedLines.first { $0.id == original.id }!) } == snapshots)
    }
    @Test func emptyOrForeignOrDeletedSourceRejected() throws {
        let (context, sync, client) = try fixture()
        let source = try seedQuote(context, client)
        let repeatWork = service(context, sync)
        #expect(throws: RepeatWorkService.ValidationError.self) { try repeatWork.repeatQuote(sourceId: "missing", now: now) }
        for field in ["user", "profile", "deleted", "client", "empty"] {
            source.userId = field == "user" ? "other" : "u1"
            source.profileId = field == "profile" ? "other" : "p1"
            source.deletedAt = field == "deleted" ? 1 : nil
            client.deletedAt = field == "client" ? 1 : nil
            if field == "empty" {
                for line in try context.fetch(FetchDescriptor<QuoteLineItem>()) { line.deletedAt = 1 }
            }
            try context.save()
            #expect(throws: RepeatWorkService.ValidationError.self) { try repeatWork.repeatQuote(sourceId: source.id, now: now) }
        }
        #expect(sync.calls.isEmpty)
    }
    @Test func failedSaveLeavesNoPartialCloneOrEnqueue() throws {
        let (context, sync, client) = try fixture()
        let source = try seedQuote(context, client)
        source.clientName = "Pending editor input"
        client.name = "Pending contact"
        enum Failure: Error { case save }
        let repeatWork = RepeatWorkService(context: context, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure.save })
        #expect(throws: Failure.self) { try repeatWork.repeatQuote(sourceId: source.id, now: now) }
        #expect(sync.calls.isEmpty)
        let saved = ModelContext(context.container)
        #expect(try saved.fetch(FetchDescriptor<Quote>()).count == 1)
        #expect(try saved.fetch(FetchDescriptor<QuoteLineItem>()).count == 3)
        #expect(try saved.fetch(FetchDescriptor<Quote>()).first?.clientName == "Old")
        #expect(source.clientName == "Pending editor input" && client.name == "Pending contact")
    }
    @Test func blankDraftHasSelectedClientAndCurrentTaxSettings() throws {
        let (context, sync, client) = try fixture()
        let repeatWork = service(context, sync)
        let qid = try repeatWork.newQuote(clientId: client.id, now: now)
        let iid = try repeatWork.newInvoice(clientId: client.id, now: now)
        let quote = try #require(context.fetch(FetchDescriptor<Quote>()).first { $0.id == qid })
        let invoice = try #require(context.fetch(FetchDescriptor<Invoice>()).first { $0.id == iid })
        #expect(quote.clientId == client.id && quote.clientAddress == "New address" && quote.validUntil == "2026-10-28")
        #expect(invoice.clientId == client.id && invoice.dueDate == "2026-10-14")
        #expect(!quote.gstEnabled && !invoice.gstEnabled && quote.gstRateBp == 1500 && invoice.gstRateBp == 1500)
        #expect(quote.totalCents == 0 && invoice.totalCents == 0 && !quote.gstInclusive && !invoice.gstInclusive)
    }
}

extension RepeatWorkServiceTests {
    @Test func repeatUsesSavedSnapshotsAndPreservesPendingInput() throws {
        let (context, sync, client) = try fixture()
        let source = try seedQuote(context, client)
        let line = try #require(context.fetch(FetchDescriptor<QuoteLineItem>()).first { $0.itemDescription == "Work" })
        source.totalCents = 9999
        line.unitPriceCents = 9999
        client.name = "Pending contact"
        let id = try service(context, sync).repeatQuote(sourceId: source.id, now: now)
        let saved = ModelContext(context.container)
        let copy = try #require(saved.fetch(FetchDescriptor<Quote>()).first { $0.id == id })
        #expect(copy.totalCents == 2300 && copy.clientName == "Current")
        #expect(try saved.fetch(FetchDescriptor<QuoteLineItem>()).first { $0.quoteId == id }?.unitPriceCents == 1150)
        #expect(source.totalCents == 9999 && line.unitPriceCents == 9999 && client.name == "Pending contact")
        #expect(try saved.fetch(FetchDescriptor<Quote>()).first { $0.id == source.id }?.totalCents == 2300)
        #expect(try saved.fetch(FetchDescriptor<Client>()).first?.name == "Current")
    }

    @Test func realEngineFailedSaveHasNoDurableOutboxOrDraft() async throws {
        let (context, _, client) = try fixture()
        let source = try seedQuote(context, client)
        let api = MockAPIClient()
        let engine = SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter())
        enum Failure: Error { case save }
        var stagedCount = 0
        let repeatWork = RepeatWorkService(context: context, sync: engine, userId: "u1", profileId: "p1", persist: { mutationContext in
            stagedCount = try mutationContext.fetch(FetchDescriptor<OutboxMutation>()).count
            throw Failure.save
        })
        #expect(throws: Failure.self) { try repeatWork.repeatQuote(sourceId: source.id, now: now) }
        #expect(stagedCount == 2)
        let saved = ModelContext(context.container)
        #expect(try saved.fetch(FetchDescriptor<OutboxMutation>()).isEmpty)
        #expect(try saved.fetch(FetchDescriptor<Quote>()).count == 1)
        #expect(try saved.fetch(FetchDescriptor<QuoteLineItem>()).count == 3)
        await engine.push()
        #expect(api.pushCalls.isEmpty)
    }

    @Test func realEnginePushPreservesParentBeforeLinesWithPinnedClock() async throws {
        let (context, _, client) = try fixture()
        let source = try seedQuote(context, client)
        // Pin to force ties without depending on simulator execution speed.
        Epoch.override = 1000
        defer { Epoch.override = nil }
        let api = MockAPIClient()
        let engine = SyncEngine(api: api, context: context, auth: AuthStore(), toast: ToastCenter())
        let id = try service(context, engine).repeatQuote(sourceId: source.id, now: now)
        let rows = try context.fetch(FetchDescriptor<OutboxMutation>(sortBy: [SortDescriptor(\.createdAt)]))
        #expect(rows.count == 2 && rows[0].entityId == id)
        #expect(rows[0].createdAt < rows[1].createdAt)
        api.pushHandler = { mutations in
            PushResponse(results: mutations.map { PushResult(mutationId: $0.mutationId, status: "applied", reason: nil, entity: nil) }, serverTime: 1)
        }
        await engine.push()
        #expect(api.pushCalls.count == 1)
        #expect(api.pushCalls.first?.map(\.entityType) == ["quote", "quoteLineItem"])
        #expect(api.pushCalls.first?.first?.entityId == id)
    }

    @Test func invoiceSourceAndPaymentsRemainIdentical() throws {
        let (context, sync, client) = try fixture()
        let invoice = Invoice(userId: "u1", profileId: "p1", number: "I1", clientId: client.id, status: "issued")
        let line = InvoiceLineItem(userId: "u1", invoiceId: invoice.id, itemDescription: "Work", unitPriceCents: 2000)
        let payment = Payment(userId: "u1", invoiceId: invoice.id, amountCents: 2000, paidOn: "2020-01-01")
        context.insert(invoice); context.insert(line); context.insert(payment); try context.save()
        let before = [snapshot(invoice), snapshot(line), snapshot(payment)]
        _ = try service(context, sync).repeatInvoice(sourceId: invoice.id, now: now)
        #expect([snapshot(invoice), snapshot(line), snapshot(payment)] == before)
        let saved = ModelContext(context.container)
        let savedInvoice = try #require(saved.fetch(FetchDescriptor<Invoice>()).first { $0.id == invoice.id })
        let savedLine = try #require(saved.fetch(FetchDescriptor<InvoiceLineItem>()).first { $0.id == line.id })
        let savedPayment = try #require(saved.fetch(FetchDescriptor<Payment>()).first { $0.id == payment.id })
        #expect([snapshot(savedInvoice), snapshot(savedLine), snapshot(savedPayment)] == before)
    }

    @Test func rejectsUnavailableInvoiceAndBlankDraftClient() throws {
        let (context, sync, client) = try fixture()
        let invoice = Invoice(userId: "u1", profileId: "p1", clientId: client.id)
        context.insert(invoice); try context.save()
        let repeatWork = service(context, sync)
        #expect(throws: RepeatWorkService.ValidationError.emptySource) { try repeatWork.repeatInvoice(sourceId: invoice.id, now: now) }
        context.insert(InvoiceLineItem(userId: "u1", invoiceId: invoice.id, itemDescription: "Work", unitPriceCents: 100))
        for field in ["user", "profile", "deleted", "unlinked", "client"] {
            invoice.userId = field == "user" ? "other" : "u1"
            invoice.profileId = field == "profile" ? "other" : "p1"
            invoice.deletedAt = field == "deleted" ? 1 : nil
            invoice.clientId = field == "unlinked" ? nil : client.id
            client.deletedAt = field == "client" ? 1 : nil
            try context.save()
            #expect(throws: RepeatWorkService.ValidationError.self) { try repeatWork.repeatInvoice(sourceId: invoice.id, now: now) }
        }
        #expect(throws: RepeatWorkService.ValidationError.clientUnavailable) { try repeatWork.newQuote(clientId: client.id, now: now) }
        #expect(throws: RepeatWorkService.ValidationError.clientUnavailable) { try repeatWork.newInvoice(clientId: "missing", now: now) }
        #expect(sync.calls.isEmpty)
    }
}
