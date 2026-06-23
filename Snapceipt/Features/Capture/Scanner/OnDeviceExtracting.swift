import Foundation

/// On-device extraction engine seam. The real implementation is Foundation Models (iOS 26+);
/// the view-model holds an optional one (nil on non-FM devices) so the router stays testable.
protocol OnDeviceExtracting {
    /// Extract a receipt fully on-device. The returned draft's `confidence` drives the
    /// FM-low-confidence → cloud-upgrade decision in the router.
    func extract(ocrText: String, layoutText: String, capturedAt: String) async throws -> ExtractedReceipt
}
