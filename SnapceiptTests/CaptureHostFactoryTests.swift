import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
struct CaptureHostFactoryTests {
    @Test("makeCaptureViewModel wires the active user + reducer + deps")
    func buildsViewModel() throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let profile = Profile(userId: "u7", name: "Me", type: "business",
                              accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950", isDefault: true)
        ctx.insert(profile); try ctx.save()
        @MainActor final class SpySync: SyncEnqueuing {
            func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
        }
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u7")
        let vm = CaptureFactory.makeViewModel(
            api: MockAPIClient(), sync: SpySync(), profiles: store, context: ctx, userId: "u7",
            reachability: Reachability())
        #expect(vm.stage == .camera)
    }
}
