import Testing
import SwiftData
import SwiftUI
@testable import Snapceipt

@MainActor
struct ProfilesStoreTests {

    private func makeStore() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        // Isolate UserDefaults so a persisted activeProfileId from another run
        // can't leak in.
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, configurations: config)
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
        #expect(sync.calls.count == 1)        // exactly one upsert per add
    }
}
