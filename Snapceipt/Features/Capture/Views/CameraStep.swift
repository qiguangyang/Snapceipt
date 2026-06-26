import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Single-shot camera: one tap of the shutter captures a still and routes it straight to the
/// Confirm/Retake step (no multi-page scanner loop). An import affordance (Photo Library /
/// Files) resolves to a single `UIImage` (PDF → first page) and calls the SAME `onScanned`
/// closure, so OCR → extract → review → save is identical to a live capture.
///
/// Device-only: `AVCaptureSession` needs a real camera, so under the hermetic test seam the
/// preview is a neutral placeholder and the controller is never started.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    /// An imported file (Photos or Files). `text` is the PDF's embedded text when available
    /// (skip OCR); nil for images. A nil-text import (photo / image-only PDF) is document-scanned
    /// (edge-adjust + dewarp) like a live capture.
    let onImported: (UIImage, String?) -> Void
    let onClose: () -> Void

    @Environment(ToastCenter.self) private var toasts
    @State private var camera = CameraController()
    @State private var flashOn = false
    @State private var accessDenied = false
    @State private var liveQuad: NormalizedQuad?
    @State private var bufferSize: CGSize = .zero
    @State private var showingChooser = false
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photoItem: PhotosPickerItem?

    private static let importFailureMessage = "Couldn't read that file."

    var body: some View {
        cameraLayer
            .ignoresSafeArea()
            .overlay { controls }
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
                        onImported(image, nil)
                    } else {
                        toasts.show(Self.importFailureMessage, kind: .error)
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

    // MARK: Camera / placeholder

    /// The live preview — or, under the hermetic camera seam, a neutral placeholder
    /// (`AVCaptureSession` is unsupported in the simulator).
    @ViewBuilder private var cameraLayer: some View {
        #if DEBUG
        if AppLaunch.current.captureCamera {
            Color.black
        } else {
            livePreview
        }
        #else
        livePreview
        #endif
    }

    private var livePreview: some View {
        CameraPreview(session: camera.session, quad: liveQuad, bufferSize: bufferSize)
            .onAppear {
                camera.onCapture = { onScanned($0) }
                camera.onAccessDenied = { accessDenied = true }
                camera.onLiveQuad = { quad, size in liveQuad = quad; bufferSize = size }
                camera.start()
            }
            .onDisappear { camera.stop(); liveQuad = nil }
    }

    // MARK: Controls overlay

    @ViewBuilder private var controls: some View {
        ZStack {
            VStack {
                HStack {
                    circleButton("xmark", action: onClose)
                        .accessibilityIdentifier(AccessibilityID.captureClose)
                    Spacer()
                    circleButton(flashOn ? "bolt.fill" : "bolt.slash.fill") { flashOn.toggle() }
                }
                .padding(.horizontal, 18).padding(.top, 12)
                Spacer()
            }

            VStack {
                Spacer()
                ZStack {
                    HStack { importButton; Spacer() }
                    shutterButton
                }
                .padding(.horizontal, 24).padding(.bottom, 40)
            }

            if accessDenied { accessDeniedOverlay }
        }
    }

    private var shutterButton: some View {
        Button { camera.capture(flashOn: flashOn) } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.captureShutter)
        .accessibilityLabel("Capture receipt")
    }

    private func circleButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var accessDeniedOverlay: some View {
        VStack(spacing: 12) {
            Text("Camera access is off")
                .font(.ui(16, .semibold)).foregroundStyle(.white)
            Text("Enable the camera in Settings, or import a receipt instead.")
                .font(.ui(13.5)).foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.ui(14, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white.opacity(0.2), in: Capsule())
        }
        .padding(28)
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
    /// pipeline; toast on an unreadable/unsupported file. Stays on the camera on cancel.
    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            toasts.show(Self.importFailureMessage, kind: .error); return
        }
        // A cloud-provider URL may lack a `.pdf` extension, so don't key off pathExtension:
        // try PDF first (firstPage returns nil for non-PDF data), then fall back to a bitmap.
        // The importer already restricts selection to images + PDFs.
        if let pdfImage = PDFImageRenderer.firstPage(data) {
            // PDF: use the embedded digital text directly (skip lossy render→OCR) when present;
            // scanned/image-only PDFs return nil text and fall back to OCR on the render.
            onImported(pdfImage, PDFTextExtractor.text(data))
            return
        }
        if let image = UIImage(data: data) {
            onImported(image, nil)
            return
        }
        toasts.show(Self.importFailureMessage, kind: .error)
    }
}
