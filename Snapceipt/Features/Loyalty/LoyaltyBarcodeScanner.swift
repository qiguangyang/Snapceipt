import SwiftUI
import VisionKit
import Vision

/// Wraps `DataScannerViewController` to scan a single loyalty barcode. On a recognized
/// barcode it calls `onCapture(value:format:)` (format nil for unsupported symbologies —
/// the value is still captured). The host presents this from the Add screen's Scan CTA;
/// when the scanner is unavailable / permission denied, the host shows manual entry.
struct LoyaltyBarcodeScanner: UIViewControllerRepresentable {
    let onCapture: (_ value: String, _ format: LoyaltyCard.BarcodeFormat?) -> Void

    /// Whether the device + permission support live scanning.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.code128, .ean13, .qr, .aztec, .pdf417])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCapture: (_ value: String, _ format: LoyaltyCard.BarcodeFormat?) -> Void
        private var didCapture = false
        init(onCapture: @escaping (String, LoyaltyCard.BarcodeFormat?) -> Void) {
            self.onCapture = onCapture
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item])
        }

        private func handle(_ items: [RecognizedItem]) {
            guard !didCapture else { return }
            for item in items {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue {
                    didCapture = true
                    let format = LoyaltyCard.BarcodeFormat(symbology: barcode.observation.symbology)
                    onCapture(value, format)
                    return
                }
            }
        }
    }
}
