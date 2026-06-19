import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@Suite("SwiftDataModel")
struct SwiftDataModelTests {

    /// A fresh, isolated in-memory context per test.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    @Test("inserts a Profile + Transaction and fetches by profileId with sync fields intact")
    func insertFetchProfileScoped() throws {
        let ctx = try makeContext()

        let profile = Profile(
            userId: "u1",
            name: "Studio North",
            type: "business",
            initials: "SN",
            accent1: "#0E7C72",
            accent2: "#DCF0ED",
            accent3: "#0A5950",
            abn: "12 345 678 901",
            gstRegistered: true,
            sortOrder: 1,
            isDefault: true,
            lastEditedDeviceId: "dev-1"
        )
        ctx.insert(profile)

        let pid = profile.id
        let txn = Transaction(
            userId: "u1",
            profileId: pid,
            merchant: "The Grounds",
            catKey: "meals",
            amountCents: -4250,
            txnDate: "2026-05-28",
            mode: "business",
            deductiblePct: 50,
            gstCents: 386,
            source: "scan",
            rev: 3,
            lastEditedDeviceId: "dev-1"
        )
        ctx.insert(txn)
        try ctx.save()

        // Fetch the transaction filtered by its profile (capture a String, not the
        // optional column directly, to keep the #Predicate simple + valid).
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid }
        )
        descriptor.sortBy = [SortDescriptor(\.updatedAt)]
        let found = try ctx.fetch(descriptor)

        let one = try #require(found.first)
        #expect(found.count == 1)
        #expect(one.merchant == "The Grounds")
        #expect(one.catKey == "meals")
        #expect(one.amountCents == -4250)        // signed Int cents
        #expect(one.currency == "AUD")           // default applied
        #expect(one.gstCents == 386)
        #expect(one.deductiblePct == 50)
        #expect(one.source == "scan")
        // Sync envelope persisted:
        #expect(one.userId == "u1")
        #expect(one.profileId == pid)
        #expect(one.rev == 3)
        #expect(one.deletedAt == nil)
        #expect(one.lastEditedDeviceId == "dev-1")
        #expect(one.entityType == .transaction)

        // The profile persisted its business fields + accent palette.
        let profiles = try ctx.fetch(FetchDescriptor<Profile>())
        let p = try #require(profiles.first)
        #expect(p.type == "business")
        #expect(p.accent1 == "#0E7C72")
        #expect(p.gstRegistered == true)
        #expect(p.isDefault == true)
        #expect(p.profileId == nil)              // a profile is not profile-scoped
        #expect(p.entityType == .profile)
    }

    @Test("a soft-delete tombstone persists on a syncable row")
    func tombstone() throws {
        let ctx = try makeContext()
        let card = LoyaltyCard(
            userId: "u1",
            brand: "Flybuys",
            number: "6008900000000000",
            barcodeFormat: "code128",
            color1: "#0E7C72",
            color2: "#0A5950",
            deletedAt: 1_900_000_000_000
        )
        ctx.insert(card)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<LoyaltyCard>())
        let c = try #require(rows.first)
        #expect(c.deletedAt == 1_900_000_000_000)
        #expect(c.barcodeFormat == "code128")
        #expect(c.entityType == .loyaltyCard)
    }

    @Test("OutboxMutation round-trips through the store")
    func outboxRoundTrip() throws {
        let ctx = try makeContext()
        let m = OutboxMutation(
            entityType: EntityType.transaction.rawValue,
            entityId: "t1",
            op: "upsert",
            payloadJSON: #"{"id":"t1","amountCents":-4250}"#,
            baseRev: 2,
            attemptCount: 0,
            status: "pending"
        )
        ctx.insert(m)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<OutboxMutation>())
        let got = try #require(rows.first)
        #expect(got.entityType == "transaction")
        #expect(got.entityId == "t1")
        #expect(got.op == "upsert")
        #expect(got.baseRev == 2)
        #expect(got.status == "pending")
        #expect(got.payloadJSON.contains("-4250"))
        #expect(!got.mutationId.isEmpty)
    }

    @Test("EntityType still has exactly the 18 syncable cases")
    func entityTypeCount() {
        #expect(EntityType.allCases.count == 18)
    }

    @Test("the full schema builds an in-memory container without throwing")
    func schemaBuilds() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        #expect(container.schema.entities.isEmpty == false)
    }

    @MainActor @Test func transactionAndCategoryCarryBasColumns() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let t = Transaction(userId: "u1", profileId: "p1", catKey: "groceries",
                            amountCents: -33_000, txnDate: "2026-04-01",
                            gstFree: true, capital: false, gstSource: nil)
        ctx.insert(t)
        let c = Snapceipt.Category(userId: "u1", profileId: "p1", key: "groceries", label: "Groceries",
                         icon: "tag", tint: "#C99A22", soft: "#F6EECE", gstFreeDefault: true)
        ctx.insert(c)
        try ctx.save()
        let tx = try ctx.fetch(FetchDescriptor<Transaction>()).first!
        #expect(tx.gstFree == true)
        #expect(tx.capital == false)
        #expect(tx.gstSource == nil)
        let cat = try ctx.fetch(FetchDescriptor<Snapceipt.Category>()).first!
        #expect(cat.gstFreeDefault == true)
        // Defaults: a txn/category built WITHOUT the new params defaults to false/nil.
        let t2 = Transaction(userId: "u1", profileId: "p1", catKey: "fuel",
                             amountCents: -80_00, txnDate: "2026-04-02")
        #expect(t2.gstFree == false && t2.capital == false && t2.gstSource == nil)
        let c2 = Snapceipt.Category(userId: "u1", profileId: "p1", key: "fuel", label: "Fuel",
                          icon: "tag", tint: "#2F6FB0", soft: "#E2ECF6")
        #expect(c2.gstFreeDefault == false)
    }
}
