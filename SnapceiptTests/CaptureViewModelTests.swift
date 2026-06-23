import Testing
import SwiftData
import UIKit
@testable import Snapceipt

@MainActor
struct CaptureViewModelTests {

    /// Spy enqueuer (mirrors the one used by ProfilesStore tests).
    @MainActor final class SpySync: SyncEnqueuing {
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

    /// Lets a test hold a mock /extract call mid-flight, then release it on demand — so we can
    /// observe the "Review now" on-device state BEFORE the AI lands, then let it land.
    @MainActor final class Gate {
        private var cont: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { cont = $0 }
        }
        func open() { opened = true; cont?.resume(); cont = nil }
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
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
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

    private func cappedResponse() -> ExtractionResponse {
        let json = """
        {"requestId":"r-capped","receipt":{"merchant":"Kmart","date":"2026-06-15","currencyCode":"AUD",
          "total":19.99,"gst":1.82,"category":"office","deductible":100,
          "lineItems":[],"confidence":0.45,"needsReview":true},
         "meta":{"model":"heuristic","source":"scan","latencyMs":2,"attempts":1,"stub":false,
                 "capped":true,"smartScan":{"used":10,"cap":10,"plan":"free"}}}
        """
        return try! JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }

    /// Wrap a plain rawText string into zero-box RecognizedLines (behaviour unchanged).
    private func zeroLines(_ rawText: String) -> [RecognizedLine] {
        rawText.split(separator: "\n").map {
            RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
        }
    }

    @Test("presentCapture -> confirm; retake -> camera; confirm(onScanned) -> review")
    func confirmRetakeFlow() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse() }
        let img = image()
        vm.presentCapture(image: img)
        #expect(vm.stage == .confirm)
        #expect(vm.capturedImage != nil)
        vm.retake()
        #expect(vm.stage == .camera)
        #expect(vm.capturedImage == nil)
        // Re-capture then confirm (onScanned) advances to review.
        vm.presentCapture(image: img)
        #expect(vm.stage == .confirm)
        await vm.onScanned(image: img, lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(vm.stage == .review)
    }

    @Test("onScanned -> scanning -> review with the extracted draft on success")
    func successPath() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(vm.stage == .review)
        #expect(vm.draft?.merchant == "Cafe")
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.draft?.needsReview == false)
    }

    @Test("extract failure (non-FM, online) -> empty pending draft, needsReview, still reaches review")
    func failurePathFallsBack() async throws {
        struct Boom: Error {}
        let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        #expect(vm.stage == .review)
        #expect(vm.draft?.extractionStatus == "pending")
        #expect(vm.draft?.needsReview == true)
        // New contract: no on-device heuristic — a cloud failure queues an EMPTY pending draft.
        #expect(vm.draft?.merchant == "")
        #expect(vm.draft?.total == 0)
    }

    @Test("save inserts the txn + line items, enqueues each, creates a PendingReceipt, -> saved")
    func saveInsertsAndEnqueues() async throws {
        let (vm, _, sync, ctx) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
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

    @Test("capped response sets smartScanCapped=true, smartScanCap, and smartScanUsed from meta.smartScan")
    func cappedResponseSetsSignal() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.cappedResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("KMART\nTOTAL 19.99"))
        #expect(vm.stage == .review)
        #expect(vm.smartScanCapped == true)
        #expect(vm.smartScanCap == 10)
        #expect(vm.smartScanUsed == 10)
        #expect(vm.draft?.needsReview == true)
    }

    @Test("normal (non-capped) response leaves smartScanCapped=false")
    func nonCappedResponseLeavesSignalFalse() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(vm.smartScanCapped == false)
        #expect(vm.smartScanCap == nil)
    }

    @Test("extract failure (offline) resets smartScanCapped, smartScanCap, and smartScanUsed to nil/false")
    func offlineFailureResetsCappedSignal() async throws {
        struct Boom: Error {}
        let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        #expect(vm.smartScanCapped == false)
        #expect(vm.smartScanCap == nil)
        #expect(vm.smartScanUsed == nil)
    }

    /// Locks the Saved-summary save target (Finding 1) against the active profile, not
    /// the default. `business` differs from the "personal" default, so this fails if
    /// `savedMode = profile.type` in save() is removed (it would stay "personal"), and
    /// `activeMode` fails if the activeProfile mode stops feeding the Review toggle.
    @Test("save() captures the ACTIVE profile's mode as savedMode (not the default)")
    func savedModeFollowsActiveProfile() async throws {
        let (vm, _, _, _) = try fixture(activeType: "business") { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        // The Review toggle seeds from the active profile's mode, pre-save.
        #expect(vm.activeMode == "business")
        vm.save()
        // The Saved summary reads the real save target captured in save().
        #expect(vm.savedMode == "business")
    }

    @Test("AppSettings.smartScanEnabled defaults to true when the key is unset")
    func smartScanDefaultsOn() {
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        #expect(AppSettings.smartScanEnabled == true)
    }

    @Test("ScanDiagnostics.summary renders the DeepSeek engine line")
    func diagnosticsSummaryDeepseek() {
        let d = ScanDiagnostics(engine: .deepseek, model: "deepseek-v4-flash",
                                clientMs: 850, serverMs: 700, attempts: 1,
                                stub: false, capped: false, confidence: 0.91)
        #expect(d.summary == "Snapceipt AI · 1 try · 700ms srv · 850ms · conf 0.91")
    }

    @Test("Smart Scan OFF, non-FM -> manual empty draft, status done, no /extract call, diagnostics onDeviceQueued")
    func smartScanOffUsesHeuristic() async throws {
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey) }
        // The handler must NOT be invoked when Smart Scan is OFF.
        let (vm, api, _, _) = try fixture { _, _, _ in
            Issue.record("extract() must not be called when Smart Scan is OFF")
            throw MockAPIClientError.unscripted
        }
        // Set OFF *after* fixture(), which resets the key to default-ON.
        UserDefaults.standard.set(false, forKey: AppSettings.smartScanEnabledKey)
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        #expect(vm.stage == .review)
        #expect(api.extractCalls.isEmpty)
        // New contract: no on-device heuristic — Smart Scan OFF (non-FM) seeds an EMPTY
        // "done" draft for manual entry (the reconciler never re-extracts it).
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.draft?.merchant == "")
        #expect(vm.draft?.needsReview == true)
        #expect(vm.diagnostics?.engine == .onDeviceQueued)
    }

    @Test("Smart Scan ON success -> diagnostics deepseek with model/attempts from meta, status done")
    func smartScanOnSuccessDiagnostics() async throws {
        let (vm, api, _, _) = try fixture { _, _, _ in self.okResponse() }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(api.extractCalls.count == 1)
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.diagnostics?.engine == .deepseek)
        #expect(vm.diagnostics?.model == "x")     // okResponse() meta.model == "x"
        #expect(vm.diagnostics?.attempts == 1)
    }

    @Test("Smart Scan ON failure (non-FM) -> empty pending draft, diagnostics onDeviceQueued")
    func smartScanOnFailureDiagnostics() async throws {
        struct Boom: Error {}
        let (vm, _, _, _) = try fixture { _, _, _ in throw Boom() }
        await vm.onScanned(image: image(), lines: zeroLines("WOOLWORTHS\nTOTAL 22.00"))
        // New contract: a cloud failure (no on-device heuristic) queues an EMPTY pending draft.
        #expect(vm.draft?.extractionStatus == "pending")
        #expect(vm.draft?.merchant == "")
        #expect(vm.diagnostics?.engine == .onDeviceQueued)
    }

    @Test("reviewNow() quits waiting -> review with an EMPTY PENDING draft + onDeviceQueued diagnostics")
    func reviewNowQuitsWaiting() async throws {
        // Handler stays in-flight (cancellable sleep) so we can act mid-scanning.
        let (vm, _, _, _) = try fixture { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return self.okResponse()
        }
        let scan = Task { await vm.onScanned(image: self.image(), lines: self.zeroLines("WOOLWORTHS\nTOTAL 22.00")) }
        while vm.stage != .scanning { await Task.yield() }
        vm.reviewNow()
        #expect(vm.stage == .review)
        #expect(vm.draft?.extractionStatus == "pending")
        // New contract: no on-device heuristic — "Review now" drops to an EMPTY pending draft;
        // the AI refreshes it in place when it lands.
        #expect(vm.draft?.merchant == "")
        #expect(vm.draft?.total == 0)
        #expect(vm.diagnostics?.engine == .onDeviceQueued)
        vm.cancelExtraction()   // reviewNow no longer cancels; stop the in-flight call for the test
        await scan.value
    }

    @Test("Review now: when the AI lands it refreshes the open Review screen in place")
    func reviewNowRefreshesInPlace() async throws {
        let gate = Gate()
        let (vm, _, _, _) = try fixture { _, _, _ in
            await gate.wait()
            return self.okResponse(merchant: "AICafe")
        }
        let scan = Task { await vm.onScanned(image: self.image(), lines: self.zeroLines("WOOLWORTHS\nTOTAL 22.00")) }
        while vm.stage != .scanning { await Task.yield() }
        vm.reviewNow()
        #expect(vm.stage == .review)
        #expect(vm.draft?.extractionStatus == "pending")
        #expect(vm.draft?.merchant != "AICafe")          // on-device shown first
        let revBefore = vm.draftRevision
        gate.open()                                       // AI result lands
        await scan.value
        #expect(vm.stage == .review)                      // stayed on Review (not yanked)
        #expect(vm.draft?.merchant == "AICafe")           // refreshed in place
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.diagnostics?.engine == .deepseek)
        #expect(vm.draftRevision > revBefore)             // signalled ReviewStep to re-seed rows/total
    }

    @Test("Review now: a user edit before the AI lands is NOT clobbered by the AI result")
    func reviewNowEditNotClobbered() async throws {
        let gate = Gate()
        let (vm, _, _, _) = try fixture { _, _, _ in
            await gate.wait()
            return self.okResponse(merchant: "AICafe")
        }
        let scan = Task { await vm.onScanned(image: self.image(), lines: self.zeroLines("WOOLWORTHS\nTOTAL 22.00")) }
        while vm.stage != .scanning { await Task.yield() }
        vm.reviewNow()
        var edited = vm.draft!
        edited.merchant = "My Edit"
        vm.editDraft(edited)
        #expect(vm.draftUserEdited == true)
        gate.open()                                       // AI lands AFTER the edit
        await scan.value
        #expect(vm.draft?.merchant == "My Edit")          // user's edit preserved
        #expect(vm.diagnostics?.engine == .onDeviceQueued) // AI result discarded
        #expect(vm.draftRevision == 0)                    // no re-seed signal (edit guard held)
    }

    @Test("reviewNow() is a no-op once the AI has already resolved (stage left .scanning)")
    func reviewNowNoOpAfterResolved() async throws {
        let (vm, _, _, _) = try fixture { _, _, _ in self.okResponse(merchant: "Cafe") }
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        #expect(vm.stage == .review)
        #expect(vm.draft?.extractionStatus == "done")
        vm.reviewNow()   // AI already landed -> must not downgrade
        #expect(vm.draft?.extractionStatus == "done")
        #expect(vm.draft?.merchant == "Cafe")
    }

    @Test("autosaveOnExitIfScanning() persists a PENDING receipt flagged autoSaved")
    func autosaveOnExitPersistsPending() async throws {
        let (vm, _, sync, ctx) = try fixture { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return self.okResponse()
        }
        let scan = Task { await vm.onScanned(image: self.image(), lines: self.zeroLines("WOOLWORTHS\nTOTAL 22.00")) }
        while vm.stage != .scanning { await Task.yield() }
        vm.autosaveOnExitIfScanning()
        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        #expect(txns.count == 1)
        #expect(txns[0].extractionStatus == "pending")
        #expect(txns[0].source == "scan")
        let pending = try ctx.fetch(FetchDescriptor<PendingReceipt>())
        #expect(pending.count == 1)
        #expect(pending[0].autoSaved == true)
        #expect(sync.calls.contains { $0.entityType == .transaction })
        await scan.value
    }

    @Test("autosaveOnExitIfScanning() is a no-op outside .scanning")
    func autosaveOnExitNoOpOutsideScanning() async throws {
        let (vm, _, _, ctx) = try fixture { _, _, _ in self.okResponse() }
        // Still at .camera (nothing scanned yet) — must not persist anything.
        vm.autosaveOnExitIfScanning()
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
    }

    @Test("autosaveOnExitIfScanning() with NO resolvable profile surfaces an error and persists nothing")
    func autosaveOnExitNoProfile() async throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        UserDefaults.standard.removeObject(forKey: AppSettings.smartScanEnabledKey)
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        // No profiles inserted -> activeProfile == nil and profiles.isEmpty.
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        let api = MockAPIClient()
        api.extractHandler = { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return self.okResponse()
        }
        let vm = CaptureViewModel(api: api, reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")
        let scan = Task { await vm.onScanned(image: self.image(), lines: self.zeroLines("X\nTOTAL 1.00")) }
        while vm.stage != .scanning { await Task.yield() }
        vm.autosaveOnExitIfScanning()
        // No profile to file under: must NOT silently persist a half-saved txn, and must
        // surface a signal rather than dropping the scan into the void.
        #expect(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<PendingReceipt>()).isEmpty)
        #expect(vm.errorMessage != nil)
        await scan.value
    }

    @Test("ScanDiagnostics.summary renders the on-device queued (finishing with AI) line")
    func diagnosticsSummaryOnDeviceQueued() {
        let d = ScanDiagnostics(engine: .onDeviceQueued, model: nil,
                                clientMs: 9, serverMs: nil, attempts: nil,
                                stub: nil, capped: nil, confidence: 0.40)
        #expect(d.summary == "on-device · finishing with AI… · 9ms · conf 0.40")
    }

    @Test("ScanDiagnostics.summary renders the on-device AI (Foundation Models) line")
    func diagnosticsSummaryFoundationModel() {
        let d = ScanDiagnostics(engine: .foundationModel, model: "apple-on-device",
                                clientMs: 1200, serverMs: nil, attempts: nil,
                                stub: nil, capped: nil, confidence: 0.88)
        #expect(d.summary == "On-device AI · 1200ms · conf 0.88")
    }

    @Test("save(toProfileId:) files the txn under the SELECTED profile, not the active one")
    func saveUnderSelectedProfile() async throws {
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let p1 = Profile(userId: "u1", name: "Home Budget", type: "personal",
                         accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A", isDefault: true)
        let p2 = Profile(userId: "u1", name: "Studio North", type: "business",
                         accent1: "#2F6FB0", accent2: "#E2ECF6", accent3: "#1E4E80", isDefault: false)
        ctx.insert(p1); ctx.insert(p2); try ctx.save()
        let store = ProfilesStore(context: ctx, sync: SpySync(), userId: "u1")
        store.setActive(p1.id)
        let api = MockAPIClient(); api.extractHandler = { _, _, _ in self.okResponse() }
        let vm = CaptureViewModel(api: api, reducer: PassReducer(), sync: SpySync(),
                                  profiles: store, context: ctx, userId: "u1")
        await vm.onScanned(image: image(), lines: zeroLines("CAFE\nTOTAL 10.00"))
        // Active profile is p1 (personal); explicitly assign the receipt to p2 (business).
        vm.save(toProfileId: p2.id)
        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        #expect(txns.count == 1)
        #expect(txns.first?.profileId == p2.id)
        #expect(txns.first?.mode == "business")
        #expect(vm.savedMode == "business")
    }
}
