import SwiftUI

/// The full-screen capture container, switching on the view-model stage. Holds the
/// editable draft + the live profile mode binding. Under the stub seam (Task 12) it
/// starts at `.scanning` with a canned image so the simulator needs no camera.
struct CaptureFlow: View {
    @Bindable var vm: CaptureViewModel
    @Environment(\.accent) private var accent
    let onClose: () -> Void

    @State private var selectedProfileId: String = ""

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            switch vm.stage {
            case .camera:
                // A capture (scan or import) goes to the Confirm/Retake step first; OCR is
                // deferred to Confirm so a misframed shot can be retaken without processing.
                CameraStep(
                    onScanned: { image in vm.presentCapture(image: image) },
                    onClose: onClose)
            case .confirm:
                ConfirmStep(
                    image: vm.capturedImage,
                    onConfirm: {
                        guard let image = vm.capturedImage else { return }
                        Task {
                            let lines = (try? await OCR.recognize(in: image)) ?? []
                            await vm.onScanned(image: image, lines: lines)
                        }
                    },
                    onRetake: { vm.retake() },
                    onClose: onClose)
            case .scanning:
                ScanStep(image: vm.capturedImage, draft: vm.draft, onClose: onClose)
            case .review:
                if let binding = draftBinding {
                    ReviewStep(draft: binding, selectedProfileId: $selectedProfileId, vm: vm,
                               onSave: { vm.save(toProfileId: selectedProfileId) }, onClose: onClose)
                }
            case .saved:
                // The summary names the ACTUAL save target (`vm.savedMode`, captured
                // from `profiles.activeProfile` in `save()`), never the cosmetic Review
                // toggle — so it can never claim the wrong profile.
                SavedStep(total: vm.draft?.total ?? 0,
                          mode: vm.savedMode,
                          deductible: vm.draft?.deductible,
                          queued: vm.isQueued,
                          onSnapAnother: { vm.reset() },
                          onDone: onClose)
            }
        }
        // Default the "Assign to profile" picker to the active profile; the user can
        // pick any profile by name and the receipt is saved under that choice
        // (`vm.save(toProfileId:)`).
        .onAppear { selectedProfileId = vm.activeProfileId }
    }

    /// Non-nil binding to the draft once it exists.
    private var draftBinding: Binding<ExtractedReceipt>? {
        guard vm.draft != nil else { return nil }
        return Binding(get: { vm.draft! }, set: { vm.draft = $0 })
    }
}
