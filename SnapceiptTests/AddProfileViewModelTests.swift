import Foundation
import Testing
import SwiftData
@testable import Snapceipt

/// Spy implementing the sync seam — records every enqueue for assertions.
@MainActor
final class MockSyncEngine: SyncEnqueuing {
    struct Call { let op: String; let entityType: EntityType; let entityId: String }
    var calls: [Call] = []
    var flushCount = 0
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        calls.append(Call(op: op, entityType: entityType, entityId: entity.id))
    }
    func flush() async { flushCount += 1 }
}

@MainActor
struct AddProfileViewModelTests {

    /// A fresh in-memory context + a ProfilesStore + spy, wired together.
    private func makeFixture() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, TaxSettings.self, configurations: config)
        let context = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: context, sync: sync, userId: "u1")
        return (context, store, sync)
    }

    @Test("invalid until a non-empty name is entered")
    func validity() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        #expect(vm.isValid == false)
        vm.name = "   "
        #expect(vm.isValid == false)        // whitespace-only is still invalid
        vm.name = "Studio"
        #expect(vm.isValid == true)
    }

    @Test("create() persists the business contact + bank details entered at creation")
    func createPersistsBusinessDetails() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .business
        vm.name = "Lumen Studio"
        vm.businessEmail = "hi@lumen.example"
        vm.phone = "0400 111 222"
        vm.website = "lumen.example"
        vm.address = "9 Studio Rd\nMelbourne VIC 3000"
        vm.bankDetails = "BSB 000-000 Acct 12345678"

        _ = try #require(vm.create())
        let p = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(p.businessEmail == "hi@lumen.example")
        #expect(p.phone == "0400 111 222")
        #expect(p.website == "lumen.example")
        #expect(p.addressText == "9 Studio Rd\nMelbourne VIC 3000")
        #expect(p.bankDetails == "BSB 000-000 Acct 12345678")
    }

    @Test("create() ignores business details for a Personal profile")
    func personalProfileHasNoBusinessDetails() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .personal
        vm.name = "Home"
        vm.businessEmail = "ignored@example.com"
        _ = try #require(vm.create())
        let p = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(p.businessEmail == nil)
    }

    @Test("create() persists a Business profile with ABN + GST + chosen palette")
    func createPersists() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .business
        vm.name = "Lumen Studio"
        vm.abn = "12 345 678 901"
        vm.gstRegistered = true
        vm.swatch = AP_ACCENTS[2]           // Indigo

        let created = try #require(vm.create())

        // Round-trips through the in-memory store.
        let all = try context.fetch(FetchDescriptor<Profile>())
        #expect(all.count == 1)
        let p = try #require(all.first)
        #expect(p.id == created.id)
        #expect(p.userId == "u1")
        #expect(p.name == "Lumen Studio")
        #expect(p.type == "business")
        #expect(p.abn == "12 345 678 901")
        #expect(p.gstRegistered == true)
        #expect(p.accent1 == "#3F5BB0")
        #expect(p.accent2 == "#E7EAF8")
        #expect(p.accent3 == "#2C4290")
        #expect(p.initials == "LS")          // derived from name
    }

    @Test("create() sets the new profile active and enqueues exactly one upsert")
    func createActivatesAndSyncs() throws {
        let (context, store, sync) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.name = "Personal"
        let created = try #require(vm.create())

        #expect(store.activeProfileId == created.id)
        #expect(sync.calls.count == 2)  // profile upsert + taxSettings seed
        #expect(sync.calls[0].op == "upsert")
        #expect(sync.calls[0].entityType == .profile)
        #expect(sync.calls[0].entityId == created.id)
        #expect(sync.calls[1].entityType == .taxSettings)
    }

    @Test("create() returns nil and writes nothing when invalid")
    func createInvalidNoop() throws {
        let (context, store, sync) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        // name left empty
        #expect(vm.create() == nil)
        #expect(try context.fetch(FetchDescriptor<Profile>()).isEmpty)
        #expect(sync.calls.isEmpty)
    }

    @Test("the swatch auto-follows type until the user manually picks one")
    func swatchAutoFollowsType() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")

        // Defaults to terracotta (the Personal default).
        #expect(vm.swatch.id == AP_ACCENTS[0].id)

        // Switching to Business auto-applies teal…
        vm.type = .business
        #expect(vm.swatch.id == AP_ACCENTS[1].id)

        // …and switching back to Personal re-applies terracotta (the bug: the
        // auto-assignment used to trip `userPickedSwatch` and freeze the swatch).
        vm.type = .personal
        #expect(vm.swatch.id == AP_ACCENTS[0].id)
    }

    @Test("a manual swatch pick stops the type-default from overriding it")
    func manualSwatchStopsAutoFollow() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")

        // User manually picks Indigo.
        vm.swatch = AP_ACCENTS[2]
        #expect(vm.swatch.id == AP_ACCENTS[2].id)

        // Type changes no longer override the user's pick.
        vm.type = .business
        #expect(vm.swatch.id == AP_ACCENTS[2].id)
        vm.type = .personal
        #expect(vm.swatch.id == AP_ACCENTS[2].id)
    }

    @Test("personal profiles drop ABN/GST even if set on the form")
    func personalClearsBusinessFields() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .personal
        vm.name = "Me"
        vm.abn = "99 999 999 999"            // should be ignored for personal
        vm.gstRegistered = true
        _ = try #require(vm.create())
        let p = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(p.abn == nil)
        #expect(p.gstRegistered == false)
    }
}
