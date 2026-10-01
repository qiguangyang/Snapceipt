import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("QuoteListViewModel")
struct QuoteListViewModelTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> QuoteListViewModel {
        QuoteListViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    private func insertQuote(_ ctx: ModelContext, profileId: String, createdAt: Int,
                             clientName: String) {
        let q = Quote(userId: "u1", profileId: profileId, clientName: clientName,
                      createdAt: createdAt, updatedAt: createdAt)
        ctx.insert(q)
    }

    @Test("reload returns only the active profile's non-deleted quotes, newest first")
    func reloadScopedNewestFirst() throws {
        let (ctx, sync) = try makeFixture()
        insertQuote(ctx, profileId: "p1", createdAt: 100, clientName: "Old")
        insertQuote(ctx, profileId: "p1", createdAt: 300, clientName: "New")
        insertQuote(ctx, profileId: "p2", createdAt: 200, clientName: "Other")   // excluded
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.quotes.count == 2)
        #expect(v.quotes[0].clientName == "New")   // createdAt desc
        #expect(v.quotes[1].clientName == "Old")
    }

    @Test("delete soft-deletes (excluded from reload) and enqueues a delete")
    func deleteSoft() throws {
        let (ctx, sync) = try makeFixture()
        insertQuote(ctx, profileId: "p1", createdAt: 100, clientName: "X")
        try ctx.save()
        let v = vm(ctx, sync)
        let q = v.quotes[0]
        v.delete(q)
        let live = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(live.isEmpty)
        #expect(v.quotes.isEmpty)
        #expect(sync.calls.last?.op == "delete")
        #expect(sync.calls.last?.entityType == .quote)
    }

    @Test("duplicate clones client + line items into a fresh draft and returns its id")
    func duplicateClones() throws {
        let (ctx, sync) = try makeFixture()
        let src = Quote(userId: "u1", profileId: "p1", clientName: "Acme",
                        gstEnabled: true, status: "sent", gstRateBp: 1500,
                        createdAt: 100, updatedAt: 100)
        ctx.insert(src)
        ctx.insert(QuoteLineItem(userId: "u1", quoteId: src.id, itemDescription: "Design",
                                 quantity: 2, unitPriceCents: 5000, sortOrder: 0))
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.quotes.count == 1)

        let newId = v.duplicate(src)
        #expect(newId != nil)
        #expect(newId != src.id)
        #expect(v.quotes.count == 2)

        let copy = try ctx.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.id == newId! }))[0]
        #expect(copy.clientName == "Acme")
        #expect(copy.status == "draft")        // fresh draft, not the source's "sent"
        #expect(copy.number == nil)            // no number / invoice carried over
        #expect(copy.invoiceId == nil)
        #expect(copy.gstRateBp == 1500)        // GST rate copied

        let lines = try ctx.fetch(FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.quoteId == newId! }))
        #expect(lines.count == 1)
        #expect(lines[0].itemDescription == "Design")
        #expect(lines[0].unitPriceCents == 5000)
        #expect(lines[0].quantity == 2)

        #expect(sync.calls.contains { $0.op == "upsert" && $0.entityType == .quote })
        #expect(sync.calls.contains { $0.op == "upsert" && $0.entityType == .quoteLineItem })
    }
}

extension QuoteListViewModelTests {
    @Test func doubleTapCreatesOneDraft() async throws {
        let (context, sync) = try makeFixture()
        let quote = Quote(userId: "u1", profileId: "p1", clientName: "Legacy", clientAddress: "Address", clientMobile: "123", validUntil: "2000-01-01")
        context.insert(quote); try context.save()
        let model = QuoteListViewModel(context: context, sync: sync, userId: "u1", profileId: "p1", clock: { Date(timeIntervalSince1970: 1790811000) })
        let first = try #require(model.duplicate(quote))
        #expect(model.duplicate(quote) == nil)
        #expect(try context.fetch(FetchDescriptor<Quote>()).count == 2)
        let copy = try #require(context.fetch(FetchDescriptor<Quote>()).first { $0.id == first })
        #expect(copy.clientAddress == "Address" && copy.clientMobile == "123")
        #expect(copy.validUntil == "2026-10-28")
        for _ in 0..<5 { await Task.yield() }
        #expect(model.duplicate(quote) == nil) // stays guarded while the review prompt is open
        model.finishCreatingDraft() // cancelling presentation keeps the committed draft
        #expect(try context.fetch(FetchDescriptor<Quote>()).count == 2)
        #expect(model.duplicate(quote) != nil)
        #expect(try context.fetch(FetchDescriptor<Quote>()).count == 3)
    }
}

extension QuoteListViewModelTests {
    @Test func linkedDuplicateUsesCurrentClientAndFailuresDoNotNavigate() throws {
        let (context, sync) = try makeFixture()
        let client = Client(userId: "u1", profileId: "p1", name: "Current")
        let quote = Quote(userId: "u1", profileId: "p1", clientId: client.id, clientName: "Old")
        context.insert(client); context.insert(quote)
        context.insert(QuoteLineItem(userId: "u1", quoteId: quote.id, itemDescription: "Work", unitPriceCents: 100))
        try context.save()
        let model = vm(context, sync)
        let id = try #require(model.duplicate(quote))
        #expect(try context.fetch(FetchDescriptor<Quote>()).first { $0.id == id }?.clientName == "Current")
        enum Failure: Error { case save }
        let failing = QuoteListViewModel(context: context, sync: sync, userId: "u1", profileId: "p1", persist: { _ in throw Failure.save })
        let previousCalls = sync.calls.count
        #expect(failing.duplicate(quote) == nil && failing.errorMessage != nil)
        #expect(sync.calls.count == previousCalls)
        #expect(try ModelContext(context.container).fetch(FetchDescriptor<Quote>()).count == 2)
        client.deletedAt = 1; try context.save()
        let deleted = vm(context, sync)
        #expect(deleted.duplicate(quote) == nil)
        #expect(deleted.errorMessage == "Select a live client in this business before creating again.")
    }
}
