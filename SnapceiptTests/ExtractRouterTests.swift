import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct ExtractRouterTests {
    final class SpySync: SyncEnqueuing {
        func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
    }
    struct PassReducer: ImageReducing { func reduce(_ i: UIImage) -> Data { Data([0xFF,0xD8,0xFF]) } }
    struct StubExtractor: OnDeviceExtracting {
        let confidence: Double
        func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt {
            ExtractedReceipt(merchant: "FM", date: "2026-06-20", total: 10, gst: 0.9,
                             categoryKey: "meals", deductible: 50, lineItems: [],
                             confidence: confidence, needsReview: confidence < 0.8, extractionStatus: "done")
        }
    }
    private func img() -> UIImage {
        UIGraphicsImageRenderer(size: .init(width: 4, height: 4)).image { _ in }
    }
    private func lines(_ s: String) -> [RecognizedLine] {
        s.split(separator: "\n").map { RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero) }
    }
    /// Build a VM for the matrix. `cloudMode` maps to AppSettings.smartScanEnabled
    /// (ON = Cloud AI). Defaults to ON to match the persisted default.
    private func vm(extractor: OnDeviceExtracting?, online: Bool, cloudMode: Bool = true,
                    extractHandler: ((String, String, String?) async throws -> ExtractionResponse)?)
        throws -> (CaptureViewModel, MockAPIClient, ModelContext) {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        UserDefaults.standard.set(cloudMode, forKey: AppSettings.smartScanEnabledKey)
        let c = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(c)
        let p = Profile(userId: "u1", name: "Me", type: "personal", accent1: "#0", accent2: "#1", accent3: "#2", isDefault: true)
        ctx.insert(p); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1"); store.setActive(p.id)
        let api = MockAPIClient(); api.extractHandler = extractHandler
        let m = CaptureViewModel(api: api, reducer: PassReducer(), sync: SpySync(),
                                 profiles: store, context: ctx, userId: "u1",
                                 onDeviceExtractor: extractor, isOnline: { online })
        return (m, api, ctx)
    }
    private func ok(_ merchant: String) -> ExtractionResponse {
        let j = "{\"requestId\":\"r\",\"receipt\":{\"merchant\":\"\(merchant)\",\"date\":\"2026-05-28\",\"currencyCode\":\"AUD\",\"total\":10.0,\"gst\":0.91,\"category\":\"meals\",\"deductible\":50,\"lineItems\":[],\"confidence\":0.95,\"needsReview\":false},\"meta\":{\"model\":\"x\",\"source\":\"scan\",\"latencyMs\":1,\"attempts\":1,\"stub\":false}}"
        return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(j.utf8))
    }

    // 1. ON + online -> cloud /extract (api called, engine .deepseek). FM (if any) untouched.
    @Test("ON + online -> cloud /extract")
    func onOnlineCloud() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.95), online: true, cloudMode: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(m.stage == .review)
        #expect(api.extractCalls.count == 1)            // cloud called
        #expect(m.draft?.merchant == "CLOUD")
        #expect(m.diagnostics?.engine == .deepseek)
    }

    // 2. ON + offline + FM -> on-device FM (api NOT called, engine .foundationModel).
    @Test("ON + offline + FM -> on-device FM, no cloud")
    func onOfflineFm() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.95), online: false, cloudMode: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(m.stage == .review)
        #expect(api.extractCalls.isEmpty)               // cloud NOT called
        #expect(m.draft?.merchant == "FM")
        #expect(m.diagnostics?.engine == .foundationModel)
        #expect(m.draft?.extractionStatus == "done")    // confident -> stays done
    }

    // 2b. ON + offline + FM, low-confidence -> FM result marked pending for the reconciler.
    @Test("ON + offline + FM low-confidence -> pending")
    func onOfflineFmLowConfidencePending() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: false, cloudMode: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)               // never cloud while offline
        #expect(m.draft?.merchant == "FM")
        #expect(m.diagnostics?.engine == .foundationModel)
        #expect(m.draft?.extractionStatus == "pending") // reconciler cloud-upgrades later
    }

    // 3. ON + offline + non-FM -> empty pending draft (engine .onDeviceQueued, no cloud).
    @Test("ON + offline + non-FM -> pending, no cloud")
    func onOfflineNonFmPending() async throws {
        let (m, api, _) = try vm(extractor: nil, online: false, cloudMode: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "pending")
        #expect(m.draft?.merchant == "")                // empty draft
        #expect(m.diagnostics?.engine == .onDeviceQueued)
    }

    // 4. OFF + FM -> on-device FM (api NOT called, engine .foundationModel).
    @Test("OFF + FM -> on-device FM, no cloud")
    func offFm() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.95), online: true, cloudMode: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)               // OFF -> never cloud
        #expect(m.draft?.merchant == "FM")
        #expect(m.diagnostics?.engine == .foundationModel)
        #expect(m.draft?.extractionStatus == "done")
    }

    // 4b. OFF + FM, low-confidence -> result stays "done" (NOT pending); never cloud.
    @Test("OFF + FM low-confidence -> done (not pending)")
    func offFmLowConfidenceStaysDone() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: true, cloudMode: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)               // OFF -> never cloud
        #expect(m.draft?.merchant == "FM")
        #expect(m.diagnostics?.engine == .foundationModel)
        #expect(m.draft?.extractionStatus == "done")    // needsReview surfaces it; never pending
        #expect(m.draft?.needsReview == true)
    }

    // 5. OFF + non-FM -> manual empty draft (engine .onDeviceQueued, status done, no cloud).
    @Test("OFF + non-FM -> manual done, no cloud")
    func offNonFmManual() async throws {
        let (m, api, _) = try vm(extractor: nil, online: true, cloudMode: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "done")
        #expect(m.draft?.merchant == "")
        #expect(m.diagnostics?.engine == .onDeviceQueued)
    }
}
