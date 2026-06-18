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

@MainActor
@Suite("AddLoyaltyViewModel")
struct AddLoyaltyViewModelTests {
    private func makeFixture() throws -> (ModelContext, MockSyncEngine) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return (ModelContext(container), MockSyncEngine())
    }

    private func vm(_ ctx: ModelContext, _ sync: MockSyncEngine) -> AddLoyaltyViewModel {
        AddLoyaltyViewModel(context: ctx, sync: sync, userId: "u1", profileId: "p1")
    }

    @Test("brands exposes the catalog plus the custom path")
    func brandsExposed() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        #expect(v.brands.count == LoyaltyBrand.catalog.count + 1)
        #expect(v.brands.last?.key == "custom")
    }

    @Test("not savable until a brand is selected and a number is entered")
    func canSave() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        #expect(v.canSave == false)
        v.selectedBrand = LoyaltyBrand.catalog.first
        #expect(v.canSave == false)             // brand chosen, number still empty
        v.number = "   "
        #expect(v.canSave == false)             // whitespace-only number is not enough
        v.number = "9352999000000"
        #expect(v.canSave == true)
    }

    @Test("custom brand requires both a name and a number")
    func canSaveCustom() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.selectedBrand = LoyaltyBrand.custom
        #expect(v.canSave == false)
        v.customName = "Local Cafe"
        #expect(v.canSave == false)             // name only, number missing
        v.number = "AB-2299"
        #expect(v.canSave == true)
        v.customName = "   "
        #expect(v.canSave == false)             // name blanked again
    }

    @Test("save creates a card scoped to the active profile with brand fields + enqueues upsert")
    func saveCreates() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        let brand = LoyaltyBrand.catalog.first { $0.key == "everydayRewards" }!
        v.selectedBrand = brand
        v.number = "9352999000000"
        v.format = .ean13
        let saved = v.save(sortOrder: 3)
        #expect(saved != nil)
        let rows = try ctx.fetch(FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.deletedAt == nil }))
        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.profileId == "p1")
        #expect(row.brand == "Everyday Rewards")
        #expect(row.subBrand == "Woolworths")
        #expect(row.color1 == "#1A8A3C")
        #expect(row.color2 == "#0C5C26")
        #expect(row.number == "9352999000000")
        #expect(row.barcodeFormat == "ean13")
        #expect(row.sortOrder == 3)
        #expect(sync.calls.count == 1)
        #expect(sync.calls[0].op == "upsert")
        #expect(sync.calls[0].entityType == .loyaltyCard)
    }

    @Test("custom brand uses the typed name + neutral colors")
    func saveCustom() throws {
        let (ctx, sync) = try makeFixture()
        let v = vm(ctx, sync)
        v.selectedBrand = LoyaltyBrand.custom
        v.customName = "Local Cafe"
        v.number = "AB-2299"
        let saved = v.save(sortOrder: 0)
        #expect(saved != nil)
        let row = try ctx.fetch(FetchDescriptor<LoyaltyCard>(predicate: #Predicate { $0.deletedAt == nil }))[0]
        #expect(row.brand == "Local Cafe")
        #expect(row.subBrand == nil)
        // Manual entry now defaults to Code 128 so a barcode always renders (BUG fix).
        #expect(row.barcodeFormat == "code128")
    }
}
