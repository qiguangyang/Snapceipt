import SwiftUI
import SwiftData

/// Constructs the capture view-model with the production `ImageReducer`. Split out so
/// it is testable without SwiftUI environment plumbing.
enum CaptureFactory {
    @MainActor
    static func makeViewModel(api: APIClient, sync: any SyncEnqueuing,
                              profiles: ProfilesStore, context: ModelContext,
                              userId: String, reachability: Reachability) -> CaptureViewModel {
        CaptureViewModel(api: api, reducer: ImageReducer(), sync: sync,
                         profiles: profiles, context: context, userId: userId,
                         onDeviceExtractor: OnDeviceAI.makeExtractor(),
                         // Under `-uiTestStub`, capture auto-feeds the canned scan on launch — before
                         // the simulator's (flaky) NWPathMonitor settles, so the real reachability can
                         // read offline and wrongly route capture to the empty pending draft. The stub
                         // design simulates offline via the API throwing `uiTestOffline` (reachability
                         // stays true), so force online here; production uses real reachability.
                         isOnline: { [weak reachability] in
                             // AppLaunch is a DEBUG-only test seam — in Release just use real reachability.
                             #if DEBUG
                             return AppLaunch.current.useStub ? true : (reachability?.isOnline ?? true)
                             #else
                             return reachability?.isOnline ?? true
                             #endif
                         })
    }
}

/// Full-screen capture host presented by the Snap tab. Builds the view-model from the
/// shell environment and drains the upload queue + re-extract reconciler on appear and
/// on reconnect. Optionally pre-seeds a canned image (UI-test stub seam, Task 12).
struct CaptureHost: View {
    let api: APIClient
    let sync: any SyncEnqueuing
    @Bindable var profiles: ProfilesStore
    let reachability: Reachability
    let context: ModelContext
    let userId: String
    /// Stub seam: a canned (image, rawText). When set, the flow starts at `.scanning`.
    let stub: (image: UIImage, rawText: String)?
    let onClose: () -> Void

    @State private var vm: CaptureViewModel?
    @State private var isDraining = false

    var body: some View {
        Group {
            if let vm {
                CaptureFlow(vm: vm, onClose: onClose)
                    .environment(\.accent, profiles.accent)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .task {
            let model = vm ?? CaptureFactory.makeViewModel(
                api: api, sync: sync, profiles: profiles, context: context, userId: userId,
                reachability: reachability)
            vm = model
            await drainQueues()
            if let stub {
                let lines = stub.rawText.split(separator: "\n").map {
                    RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
                }
                await model.onScanned(image: stub.image, lines: lines)
            }
        }
        // Stub seam: "Snap another" (`vm.reset()`) returns the flow to `.camera`, which
        // shows the real VisionKit scanner in production — but the simulator has no
        // camera, so the canned page must be re-fed. The initial `.task` already feeds
        // the FIRST scan; this re-delivers the same canned (image, rawText) only on a
        // genuine RETURN to `.camera` (a non-nil prior stage → `.camera`), so the
        // snap-another loop is observable hermetically without double-feeding on first
        // appear. No-op without a stub (production keeps the live camera). (Task 12 seam,
        // extended for J18.)
        .onChange(of: vm?.stage) { old, new in
            guard let stub, let model = vm, old != nil, new == .camera else { return }
            Task {
                let lines = stub.rawText.split(separator: "\n").map {
                    RecognizedLine(text: String($0), confidence: 1, boundingBox: .zero)
                }
                await model.onScanned(image: stub.image, lines: lines)
            }
        }
        .onChange(of: reachability.isOnline) { _, online in
            if online { Task { await drainQueues() } }
        }
    }

    private func drainQueues() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        await ReceiptUploadQueue(api: api, context: context).drain()
        await PendingExtractionReconciler(api: api, context: context, sync: sync).reconcile()
        ReceiptCleanupPass(context: context).run()
    }
}
