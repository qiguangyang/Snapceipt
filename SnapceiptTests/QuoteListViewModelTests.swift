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
}
