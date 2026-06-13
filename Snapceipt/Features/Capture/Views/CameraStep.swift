import SwiftUI

/// Full-bleed VisionKit scanner. The shutter, auto-capture, edge detection,
/// dewarp, flash, AND the Cancel/Done chrome are all native to
/// VNDocumentCameraViewController — we do not rebuild (or overlay) any of them.
/// Native Cancel routes through the scanner delegate as an empty-pages success,
/// which maps to `onClose()` below.
struct CameraStep: View {
    let onScanned: (UIImage) -> Void
    let onClose: () -> Void

    var body: some View {
        scannerLayer
            .ignoresSafeArea()
    }

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
}
