import Foundation
import Testing
import SwiftData
@testable import Snapceipt

/// Spy implementing the sync seam — records every enqueue for assertions.
@MainActor
final class MockSyncEngine: SyncEnqueuing {
    struct Call { let op: String; let entityType: EntityType; let entityId: String }
    private(set) var calls: [Call] = []
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        calls.append(Call(op: op, entityType: entityType, entityId: entity.id))
    }
}

@MainActor
struct AddProfileViewModelTests {

    /// A fresh in-memory context + a ProfilesStore + spy, wired together.
    private func makeFixture() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, configurations: config)
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
        #expect(sync.calls.count == 1)
        #expect(sync.calls.first?.op == "upsert")
        #expect(sync.calls.first?.entityType == .profile)
        #expect(sync.calls.first?.entityId == created.id)
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
