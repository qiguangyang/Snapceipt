import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct CaptureViewModelTests {

    /// Spy enqueuer (mirrors the one used by ProfilesStore tests).
    final class SpySync: SyncEnqueuing {
        struct Call { let op: String; let entityType: EntityType; let entityId: String }
        private(set) var calls: [Call] = []
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
            calls.append(Call(op: op, entityType: entityType, entityId: entity.id))
        }
    }

    /// Pass-through reducer so tests don't depend on JPEG sizing.
    struct PassReducer: ImageReducing {
        func reduce(_ image: UIImage) -> Data { Data([0xFF, 0xD8, 0xFF]) }
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    private func fixture(activeType: String = "personal",
                         extractHandler: ((String, String, String?) async throws -> ExtractionResponse)?)
        throws -> (CaptureViewModel, MockAPIClient, SpySync, ModelContext) {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let profile = Profile(userId: "u1", name: "Me", type: activeType,
                              accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
        ctx.insert(profile); try ctx.save()
        let storeSync = SpySync()
        let store = ProfilesStore(context: ctx, sync: storeSync, userId: "u1")
        store.setActive(profile.id)
        let api = MockAPIClient()
        api.extractHandler = extractHandler
        let vmSync = SpySync()
        let vm = CaptureViewModel(api: api, reducer: PassReducer(), sync: vmSync,
                                  profiles: store, context: ctx, userId: "u1")
        return (vm, api, vmSync, ctx)
    }

    private func okResponse(merchant: String = "Cafe") -> ExtractionResponse {
        let json = """
        {"requestId":"r","receipt":{"merchant":"\(merchant)","date":"2026-05-28","currencyCode":"AUD",
          "total":10.00,"gst":0.91,"category":"meals","deductible":50,
          "lineItems":[{"name":"Latte","price":5.00}],"confidence":0.95,"needsReview":false},
         "meta":{"model":"x","source":"scan","latencyMs":1,"attempts":1,"stub":false}}
        """
        return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }

    @Test("onScanned -> scanning -> review with the extracted draft on success")
    func successPath() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), rawText: "CAFE\nTOTAL 10.00")
        #expect(vm.stage == .review)
        #expect(vm.draft?.merchant == "Cafe")
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.draft?.needsReview == false)
    }

    @Test("extract failure -> heuristic fallback draft, pending + needsReview, still reaches review")
    func failurePathFallsBack() async throws {
        struct Boom: Error {}
        let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
        await vm.onScanned(image: image(), rawText: "WOOLWORTHS\nTOTAL 22.00")
        #expect(vm.stage == .review)
        #expect(vm.draft?.extractionStatus == "pending")
        #expect(vm.draft?.needsReview == true)
        #expect(vm.draft?.total == Decimal(string: "22.00"))
    }

    @Test("save inserts the txn + line items, enqueues each, creates a PendingReceipt, -> saved")
    func saveInsertsAndEnqueues() async throws {
        let (vm, _, sync, ctx) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), rawText: "CAFE\nTOTAL 10.00")
        vm.save()
        #expect(vm.stage == .saved)
        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        #expect(txns.count == 1)
        #expect(txns[0].source == "scan")
        // The canned stub is category "meals" (not income), so the VM→mapper path
        // must persist a NEGATIVE amount. Locks the sign through save().
        #expect(txns[0].amountCents < 0)
        let items = try ctx.fetch(FetchDescriptor<LineItem>())
        #expect(items.count == 1)
        // one upsert for the txn + one per line item
        #expect(sync.calls.filter { $0.entityType == .transaction }.count == 1)
        #expect(sync.calls.filter { $0.entityType == .lineItem }.count == 1)
        let pending = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(pending.count == 1)
        #expect(pending[0].transactionId == txns[0].id)
        #expect(pending[0].ocrText == "CAFE\nTOTAL 10.00")
    }

    /// Locks the Saved-summary save target (Finding 1) against the active profile, not
    /// the default. `business` differs from the "personal" default, so this fails if
    /// `savedMode = profile.type` in save() is removed (it would stay "personal"), and
    /// `activeMode` fails if the activeProfile mode stops feeding the Review toggle.
    @Test("save() captures the ACTIVE profile's mode as savedMode (not the default)")
    func savedModeFollowsActiveProfile() async throws {
        let (vm, _, _, _) = try fixture(activeType: "business") { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), rawText: "CAFE\nTOTAL 10.00")
        // The Review toggle seeds from the active profile's mode, pre-save.
        #expect(vm.activeMode == "business")
        vm.save()
        // The Saved summary reads the real save target captured in save().
        #expect(vm.savedMode == "business")
    }
}
