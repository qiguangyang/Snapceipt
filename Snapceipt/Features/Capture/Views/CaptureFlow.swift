import SwiftUI

/// The full-screen capture container, switching on the view-model stage. Holds the
/// editable draft + the live profile mode binding. Under the stub seam (Task 12) it
/// starts at `.scanning` with a canned image so the simulator needs no camera.
struct CaptureFlow: View {
    @Bindable var vm: CaptureViewModel
    @Environment(\.accent) private var accent
    @Environment(\.scenePhase) private var scenePhase
    let onClose: () -> Void

    @State private var selectedProfileId: String = ""

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            switch vm.stage {
            case .camera:
                // A live capture goes to the edge-adjust/dewarp step first; OCR is deferred
                // to "Confirm scan". Imports (Photos/Files) skip dewarp and go straight to
                // extract — PDFs pass their embedded text so OCR is skipped entirely.
                CameraStep(
                    onScanned: { image in vm.presentCapture(image: image) },
                    onImported: { image, text in Task { await vm.ingestImport(image: image, text: text) } },
                    onClose: onClose)
            case .confirm:
                if let image = vm.capturedImage {
                    EdgeAdjustView(
                        image: image,
                        onConfirm: { cleaned in
                            Task {
                                let lines = (try? await OCR.recognize(in: cleaned)) ?? []
                                await vm.onScanned(image: cleaned, lines: lines)
                            }
                        },
                        onRetake: { vm.retake() },
                        onClose: onClose)
                }
            case .scanning:
                // Closing DURING scanning auto-saves the scan as a pending receipt (it
                // upgrades to the AI result later), so leaving never loses the scan. The
                // "Review now" button drops to Review immediately with the on-device result.
                ScanStep(image: vm.capturedImage, draft: vm.draft,
                         onClose: { vm.autosaveOnExitIfScanning(); onClose() },
                         onUseOnDevice: { vm.reviewNow() })
            case .review:
                if let binding = draftBinding {
                    // Closing Review without saving cancels any still-running AI extraction
                    // (e.g. after "Review now") so it doesn't keep working in the background.
                    ReviewStep(draft: binding, selectedProfileId: $selectedProfileId, vm: vm,
                               onSave: { vm.save(toProfileId: selectedProfileId) },
                               onClose: { vm.cancelExtraction(); onClose() })
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
        // "Exit the app won't pause the processing": if the user backgrounds the app while a
        // scan is still extracting, persist it as a pending receipt (no-op outside .scanning)
        // so a force-kill never loses it — the reconciler upgrades it to the AI result on
        // return.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.autosaveOnExitIfScanning() }
        }
    }

    /// Non-nil binding to the draft once it exists. Writes go through `editDraft` so a user
    /// edit marks the draft user-owned (a late AI result then won't overwrite it).
    private var draftBinding: Binding<ExtractedReceipt>? {
        guard vm.draft != nil else { return nil }
        return Binding(get: { vm.draft! }, set: { vm.editDraft($0) })
    }
}
