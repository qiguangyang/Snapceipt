import SwiftUI
import SwiftData

/// Constructs the capture view-model with the production `ImageReducer`. Split out so
/// it is testable without SwiftUI environment plumbing.
enum CaptureFactory {
    @MainActor
    static func makeViewModel(api: APIClient, sync: any SyncEnqueuing,
                              profiles: ProfilesStore, context: ModelContext,
                              userId: String) -> CaptureViewModel {
        CaptureViewModel(api: api, reducer: ImageReducer(), sync: sync,
                         profiles: profiles, context: context, userId: userId)
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
                api: api, sync: sync, profiles: profiles, context: context, userId: userId)
            vm = model
            await drainQueues()
            if let stub {
                await model.onScanned(image: stub.image, rawText: stub.rawText)
            }
        }
        .onChange(of: reachability.isOnline) { _, online in
            if online { Task { await drainQueues() } }
        }
    }

    private func drainQueues() async {
        await ReceiptUploadQueue(api: api, context: context).drain()
        await PendingExtractionReconciler(api: api, context: context, sync: sync).reconcile()
    }
}
