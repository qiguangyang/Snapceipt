import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct ShareDraftIngestTests {

    @MainActor final class SpySync: SyncEnqueuing {
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
    }
    struct PassReducer: ImageReducing {
        func reduce(_ image: UIImage) -> Data { Data([0xFF, 0xD8, 0xFF]) }
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }
    private func draft() -> ExtractedReceipt {
        ExtractedReceipt(merchant: "Yakitori Bar", date: "2026-06-20", total: 30.00, gst: 2.70,
                         categoryKey: CategoryKey.meals.rawValue, deductible: 50,
                         lineItems: [.init(name: "Skewer", price: 3.00)],
                         confidence: 0.8, needsReview: false, extractionStatus: "pending")
    }

    @Test("ingestSharedDraft files under the active profile and reaches .saved")
    func ingestDraftPersists() throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let profile = Profile(userId: "u1", name: "Me", type: "personal",
                              accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
        ctx.insert(profile); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        store.setActive(profile.id)
        let vm = CaptureViewModel(api: MockAPIClient(), reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")

        vm.ingestSharedDraft(image: image(), draft: draft())

        #expect(vm.stage == .saved)
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).count == 1)
        #expect(try ctx.fetch(FetchDescriptor<PendingReceipt>()).count == 1)
    }

    @Test("ingestSharedDraft with NO resolvable profile persists nothing and does NOT reach .saved")
    func ingestDraftNoProfileDoesNotPersist() throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        // No profiles inserted -> activeProfile == nil, no profile matches activeProfileId.
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        let vm = CaptureViewModel(api: MockAPIClient(), reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")

        vm.ingestSharedDraft(image: image(), draft: draft())

        #expect(vm.stage != .saved)        // the exact gate the drain uses to NOT delete/count
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PendingReceipt>()).isEmpty)
        #expect(vm.errorMessage != nil)
    }
}
