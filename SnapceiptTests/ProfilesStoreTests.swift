import Testing
import Foundation
import SwiftData
import SwiftUI
@testable import Snapceipt

@MainActor
@Suite("ProfilesStore F7")
struct ProfilesStoreF7Tests {
    private func fixture() throws -> (ModelContext, MockSyncEngine, ProfilesStore) {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: ctx, sync: sync, userId: "u1")
        return (ctx, sync, store)
    }

    @Test("update mutates the profile and enqueues an upsert")
    func update() throws {
        let (_, sync, store) = try fixture()
        let p = Profile(userId: "u1", name: "Biz", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p)
        sync.calls.removeAll()
        store.update(p) { $0.name = "Renamed"; $0.gstRegistered = true }
        #expect(p.name == "Renamed")
        #expect(p.gstRegistered == true)
        #expect(sync.calls.last?.op == "upsert")
        #expect(sync.calls.last?.entityType == .profile)
    }

    @Test("delete soft-deletes a non-active profile and enqueues delete")
    func delete() throws {
        let (_, sync, store) = try fixture()
        let p1 = Profile(userId: "u1", name: "A", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        let p2 = Profile(userId: "u1", name: "B", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p1); store.add(p2)
        store.setActive(p1.id)
        sync.calls.removeAll()
        let ok = store.delete(p2)
        #expect(ok == true)
        #expect(p2.deletedAt != nil)
        #expect(store.profiles.contains { $0.id == p2.id } == false)
        #expect(sync.calls.last?.op == "delete")
    }

    @Test("delete refuses the last profile and the active profile")
    func deleteGuards() throws {
        let (_, _, store) = try fixture()
        let only = Profile(userId: "u1", name: "Only", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(only)
        #expect(store.delete(only) == false)           // last profile
        let p2 = Profile(userId: "u1", name: "B", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p2); store.setActive(p2.id)
        #expect(store.delete(p2) == false)             // active profile
    }

    @Test("activeFinancialYearStartMonth reads the active profile's tax_settings, default 7")
    func fyStart() throws {
        let (ctx, sync, store) = try fixture()
        let p = Profile(userId: "u1", name: "Biz", type: "business", accent1: "#0", accent2: "#1", accent3: "#2")
        store.add(p)  // add() seeds a TaxSettings via TaxSettingsSeeder (FY start 7)
        #expect(store.activeFinancialYearStartMonth() == 7)
        // change it
        let pid = p.id
        let d = FetchDescriptor<TaxSettings>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let ts = try ctx.fetch(d).first!
        ts.financialYearStartMonth = 4
        try ctx.save()
        #expect(store.activeFinancialYearStartMonth() == 4)
        _ = sync
    }
}

@MainActor
struct ProfilesStoreTests {

    private func makeStore() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        // Isolate UserDefaults so a persisted activeProfileId from another run
        // can't leak in.
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, TaxSettings.self, configurations: config)
        let context = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: context, sync: sync, userId: "u1")
        return (context, store, sync)
    }

    private func seed(_ store: ProfilesStore, _ context: ModelContext,
                      name: String, type: ProfileType, swatch: AccentSwatch) -> Profile {
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = type
        vm.name = name
        vm.swatch = swatch
        return vm.create()!
    }

    @Test("setActive switches the active profile and re-derives the accent")
    func setActiveUpdatesAccent() throws {
        let (context, store, _) = try makeStore()
        let personal = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        let business = seed(store, context, name: "Lumen Studio", type: .business, swatch: AP_ACCENTS[2])

        store.setActive(personal.id)
        #expect(store.activeProfile?.id == personal.id)
        #expect(store.accent.base == Color(hex: 0xE8602C))   // terracotta

        store.setActive(business.id)
        #expect(store.activeProfile?.id == business.id)
        #expect(store.accent.base == Color(hex: 0x3F5BB0))   // indigo
    }

    @Test("setActive ignores an unknown id")
    func setActiveUnknownNoop() throws {
        let (context, store, _) = try makeStore()
        let p = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        store.setActive(p.id)
        store.setActive("does-not-exist")
        #expect(store.activeProfileId == p.id)
    }

    @Test("first added profile is the default and becomes active")
    func firstIsDefaultActive() throws {
        let (context, store, sync) = try makeStore()
        let p = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        #expect(p.isDefault == true)
        #expect(store.activeProfileId == p.id)
        #expect(store.profiles.count == 1)
        #expect(sync.calls.count == 2)        // profile upsert + taxSettings seed
        #expect(sync.calls[0].entityType == .profile)
        #expect(sync.calls[1].entityType == .taxSettings)
    }

    @Test func rescopeToNewUserLoadsThatUsersProfilesAndPicksDefault() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, TaxSettings.self, configurations: config)
        let ctx = ModelContext(container)
        let pA = Profile(userId: "user-A", name: "Alpha", type: "personal",
                         accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
        ctx.insert(pA); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: MockSyncEngine(), userId: "")
        #expect(store.profiles.isEmpty)            // scoped to "" — does NOT see user-A
        store.rescope(to: "user-A")
        #expect(store.profiles.count == 1)
        #expect(store.activeProfileId == pA.id)    // re-resolved to the default profile
    }
}
