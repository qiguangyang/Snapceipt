import SwiftUI

/// Full-bleed VisionKit scanner with a single Close affordance. The shutter,
/// auto-capture, edge detection, dewarp, and flash are all native to
/// VNDocumentCameraViewController — we do not rebuild them.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DocumentScannerView { result in
                switch result {
                case .failure:
                    onClose()
                case .success(let images):
                    guard let first = images.first else { onClose(); return }  // cancelled
                    onScanned(first)
                }
            }
            .ignoresSafeArea()

            Button(action: onClose) {
                Icon(name: "close", size: 18, color: .white)
                    .padding(12)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .padding(.top, 12)
            .accessibilityIdentifier(AccessibilityID.captureClose)
        }
    }
}
