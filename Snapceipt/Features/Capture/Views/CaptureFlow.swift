import SwiftUI

/// The full-screen capture container, switching on the view-model stage. Holds the
/// editable draft + the live profile mode binding. Under the stub seam (Task 12) it
/// starts at `.scanning` with a canned image so the simulator needs no camera.
struct CaptureFlow: View {
    @Bindable var vm: CaptureViewModel
    @Environment(\.accent) private var accent
    let onClose: () -> Void

    @State private var mode: String = ProfileType.personal.rawValue

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            switch vm.stage {
            case .camera:
                CameraStep(
                    onScanned: { image in
                        Task {
                            let lines = (try? await OCR.recognize(in: image)) ?? []
                            await vm.onScanned(image: image,
                                               rawText: lines.map(\.text).joined(separator: "\n"))
                        }
                    },
                    onClose: onClose)
            case .scanning:
                ScanStep(image: vm.capturedImage, draft: vm.draft, onClose: onClose)
            case .review:
                if let binding = draftBinding {
                    ReviewStep(draft: binding, mode: $mode, vm: vm, onSave: { vm.save() }, onClose: onClose)
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
        // Open the Review toggle on the active profile (the real save target) instead
        // of the hard-coded "personal" default — the previous self-assignment was a
        // no-op and always showed Personal even for a Business active profile.
        .onAppear { mode = vm.activeMode }
        // v1: the Review Personal/Business toggle is presentation-only — it re-skins
        // the card but is NOT the save target. `vm.save()` persists under
        // `profiles.activeProfile`, so `mode` here drives appearance only.
        .onChange(of: mode) { _, _ in /* re-skin handled by the toggle's accent */ }
    }

    /// Non-nil binding to the draft once it exists.
    private var draftBinding: Binding<ExtractedReceipt>? {
        guard vm.draft != nil else { return nil }
        return Binding(get: { vm.draft! }, set: { vm.draft = $0 })
    }
}
