import SwiftUI
import UIKit

/// Writes a UIImage to the user's photo library. Wraps the C
/// `UIImageWriteToSavedPhotosAlbum` API (which triggers the add-only Photos prompt,
/// backed by NSPhotoLibraryAddUsageDescription) and reports completion on the main thread.
final class ImageSaver: NSObject {
    private var onComplete: ((Error?) -> Void)?

    func save(_ image: UIImage, completion: @escaping (Error?) -> Void) {
        onComplete = completion
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(didFinish(_:error:contextInfo:)), nil)
    }

    @objc private func didFinish(_ image: UIImage, error: Error?, contextInfo: UnsafeRawPointer) {
        let cb = onComplete
        onComplete = nil
        DispatchQueue.main.async { cb?(error) }
    }
}

/// Full-screen receipt image viewer: pinch / double-tap to zoom, and a "Save to Photos"
/// action. Presented from ReceiptDetailView when the receipt image is tapped.
struct ReceiptImageViewer: View {
    let image: UIImage
    var onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saver = ImageSaver()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in scale = min(max(lastScale * value, 1), 5) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2.5
                        lastScale = scale
                    }
                }
                .accessibilityIdentifier(AccessibilityID.receiptImageViewer)

            VStack {
                HStack {
                    circleButton(system: "xmark", action: onClose)
                        .accessibilityIdentifier(AccessibilityID.receiptImageViewerClose)
                    Spacer()
                    Button(action: save) {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down").font(.system(size: 15, weight: .semibold))
                            }
                            Text("Save to Photos").font(.ui(14, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.white.opacity(0.18), in: Capsule())
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier(AccessibilityID.receiptImageSave)
                }
                .padding(16)

                Spacer()

                if let saveMessage {
                    Text(saveMessage)
                        .font(.ui(13.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 32)
                        .transition(.opacity)
                }
            }
        }
        .statusBarHidden(true)
    }

    private func circleButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.18), in: Circle())
        }
    }

    private func save() {
        isSaving = true
        saveMessage = nil
        saver.save(image) { error in
            isSaving = false
            withAnimation { saveMessage = error == nil ? "Saved to Photos" : "Couldn’t save — check Photos access in Settings." }
        }
    }
}
