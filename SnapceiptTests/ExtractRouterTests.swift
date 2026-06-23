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
    private func vm(extractor: OnDeviceExtracting?, online: Bool,
                    extractHandler: ((String, String, String?) async throws -> ExtractionResponse)?)
        throws -> (CaptureViewModel, MockAPIClient, ModelContext) {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
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

    @Test("FM-capable: high-confidence FM result is used, no cloud call")
    func fmHighConfidence() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.95), online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(m.stage == .review)
        #expect(m.draft?.merchant == "FM")
        #expect(api.extractCalls.isEmpty)               // cloud not called
    }

    @Test("FM-capable online: low-confidence FM triggers a cloud upgrade in place")
    func fmLowConfidenceUpgrades() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)            // cloud upgrade ran
        #expect(m.draft?.merchant == "CLOUD")           // upgraded in place
    }

    @Test("FM-capable offline: low-confidence FM is left pending (no cloud)")
    func fmLowConfidenceOfflinePending() async throws {
        let (m, api, _) = try vm(extractor: StubExtractor(confidence: 0.4), online: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "pending")
        #expect(m.draft?.merchant == "FM")
    }

    @Test("non-FM online: cloud is used")
    func nonFmOnlineCloud() async throws {
        let (m, api, _) = try vm(extractor: nil, online: true) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)
        #expect(m.draft?.merchant == "CLOUD")
    }

    @Test("non-FM offline: empty pending draft, no cloud")
    func nonFmOfflinePending() async throws {
        let (m, api, _) = try vm(extractor: nil, online: false) { _,_,_ in self.ok("CLOUD") }
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "pending")
        #expect(m.draft?.merchant == "")                // empty draft
    }

    @Test("Smart Scan OFF, non-FM: manual empty draft, no cloud")
    func offNonFmManual() async throws {
        let (m, api, _) = try vm(extractor: nil, online: true) { _,_,_ in self.ok("CLOUD") }
        UserDefaults.standard.set(false, forKey: AppSettings.smartScanEnabledKey)
        await m.onScanned(image: img(), lines: lines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.isEmpty)
        #expect(m.draft?.extractionStatus == "done")
        #expect(m.draft?.merchant == "")
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
    }
}
