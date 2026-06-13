import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Full-bleed VisionKit scanner with an import affordance overlaid bottom-leading.
/// The scanner's own chrome (shutter, flash, filters, Cancel/Done) is native to
/// VNDocumentCameraViewController and untouched. The import button opens a chooser
/// (Photo Library / Files); each source resolves to a single `UIImage` (PDF → first
/// page) and calls the SAME `onScanned(UIImage)` closure the scanner uses, so OCR →
/// extract → review → save is identical to a live scan.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    let onClose: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var showingChooser = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        scannerLayer
            .ignoresSafeArea()
            .overlay(alignment: .bottomLeading) {
                importButton
                    // Bottom padding clears the home indicator and sits left of the
                    // scanner's centered control cluster. Final value tuned on-device
                    // (the simulator can't render the real scanner chrome).
                    .padding(.leading, 20)
                    .padding(.bottom, 40)
            }
            .confirmationDialog("Add a receipt", isPresented: $showingChooser, titleVisibility: .visible) {
                // Defer the present-bool flip to the next runloop tick so the dialog's
                // own dismissal doesn't swallow the picker/importer presentation.
                Button("Photo Library") { DispatchQueue.main.async { showingPhotos = true } }
                    .accessibilityIdentifier(AccessibilityID.captureImportPhotos)
                Button("Files") { DispatchQueue.main.async { showingFiles = true } }
                    .accessibilityIdentifier(AccessibilityID.captureImportFiles)
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onScanned(image)
                    } else {
                        toasts.show("Couldn't read that file.", kind: .error)
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $showingFiles,
                          allowedContentTypes: [.image, .pdf],
                          allowsMultipleSelection: false) { result in
                handleFileImport(result)
            }
    }

    // MARK: Scanner / placeholder

    /// The live scanner — or, under the hermetic camera seam, a neutral placeholder
    /// (`VNDocumentCameraViewController` is unsupported in the simulator).
    @ViewBuilder private var scannerLayer: some View {
        #if DEBUG
        if AppLaunch.current.captureCamera {
            Color.black
        } else {
            scanner
        }
        #else
        scanner
        #endif
    }

    private var scanner: some View {
        DocumentScannerView { result in
            switch result {
            case .failure:
                onClose()
            case .success(let images):
                guard let first = images.first else { onClose(); return }  // cancelled
                onScanned(first)
            }
        }
    }

    // MARK: Import affordance

    private var importButton: some View {
        Button { showingChooser = true } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureImport)
        .accessibilityLabel("Import a receipt from Photos or Files")
    }

    /// Resolve a Files selection to a single `UIImage` (PDF → first page) and feed the
    /// pipeline; toast on an unreadable/unsupported file. Stays on the scanner on cancel.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            toasts.show("Couldn't read that file.", kind: .error); return
        }
        let isPDF = UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
        let image = isPDF ? PDFImageRenderer.firstPage(data) : UIImage(data: data)
        if let image {
            onScanned(image)
        } else {
            toasts.show("Couldn't read that file.", kind: .error)
        }
    }
}
