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
                    ReviewStep(draft: binding, mode: $mode, onSave: { vm.save() }, onClose: onClose)
                }
            case .saved:
                SavedStep(total: vm.draft?.total ?? 0,
                          mode: mode,
                          deductible: vm.draft?.deductible,
                          onSnapAnother: { vm.reset() },
                          onDone: onClose)
            }
        }
        .onAppear { mode = activeMode }
        // v1: the Review Personal/Business toggle is presentation-only — it re-skins
        // the card but is NOT the save target. `vm.save()` persists under
        // `profiles.activeProfile`, so `mode` here drives appearance only.
        .onChange(of: mode) { _, _ in /* re-skin handled by the toggle's accent */ }
    }

    private var activeMode: String { mode }

    /// Non-nil binding to the draft once it exists.
    private var draftBinding: Binding<ExtractedReceipt>? {
        guard vm.draft != nil else { return nil }
        return Binding(get: { vm.draft! }, set: { vm.draft = $0 })
    }
}
