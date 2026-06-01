import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("LoyaltyWalletViewModel")
struct LoyaltyWalletViewModelTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> LoyaltyWalletViewModel {
        LoyaltyWalletViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    private func insertCard(_ ctx: ModelContext, profileId: String, sortOrder: Int,
                            createdAt: Int = Epoch.nowMs()) {
        ctx.insert(LoyaltyCard(userId: "u1", profileId: profileId, brand: "B-\(sortOrder)",
                               number: "123", color1: "#000000", color2: "#FFFFFF",
                               sortOrder: sortOrder, createdAt: createdAt))
    }

    @Test("reload returns only the active profile's non-deleted cards, sorted")
    func reloadScopedSorted() throws {
        let (ctx, sync) = try makeFixture()
        insertCard(ctx, profileId: "p1", sortOrder: 1)
        insertCard(ctx, profileId: "p1", sortOrder: 0)
        insertCard(ctx, profileId: "p2", sortOrder: 0)   // other profile — excluded
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.cards.count == 2)
        #expect(v.cards.allSatisfy { $0.profileId == "p1" })
        #expect(v.cards[0].sortOrder == 0)   // sorted by sortOrder asc
        #expect(v.cards[1].sortOrder == 1)
    }

    @Test("delete soft-deletes (excluded from reload) and enqueues a delete")
    func deleteSoft() throws {
        let (ctx, sync) = try makeFixture()
        insertCard(ctx, profileId: "p1", sortOrder: 0)
        try ctx.save()
        let v = vm(ctx, sync)
        let card = v.cards[0]
        v.delete(card)
        #expect(v.cards.isEmpty)
        #expect(card.deletedAt != nil)
        #expect(sync.calls.last?.op == "delete")
        #expect(sync.calls.last?.entityType == .loyaltyCard)
    }

    @Test("nextSortOrder is max existing + 1 for the active profile")
    func nextSortOrder() throws {
        let (ctx, sync) = try makeFixture()
        insertCard(ctx, profileId: "p1", sortOrder: 2)
        insertCard(ctx, profileId: "p1", sortOrder: 5)
        insertCard(ctx, profileId: "p2", sortOrder: 9)   // other profile — ignored
        try ctx.save()
        let v = vm(ctx, sync)
        #expect(v.nextSortOrder() == 6)
    }

    @Test("nextSortOrder is 0 for an empty wallet")
    func nextSortOrderEmpty() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        #expect(v.nextSortOrder() == 0)
    }
}
