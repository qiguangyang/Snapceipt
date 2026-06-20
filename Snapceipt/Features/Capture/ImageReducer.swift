import UIKit

/// Seam over the receipt-image size reducer so the view-model is unit-testable.
protocol ImageReducing {
    /// Downscale + recompress to a bounded JPEG. Pure (no I/O).
    func reduce(_ image: UIImage) -> Data
}

/// Bounds receipt uploads on-device: longest edge <= 1600 px (aspect preserved),
/// then JPEG quality 0.5 stepping 0.4/0.3/0.25 until bytes <= 800_000 or the floor.
/// OCR runs on the full-res capture BEFORE this, so the upload is display/archive only —
/// kept small to cut upload time + server storage while staying legible when zoomed.
struct ImageReducer: ImageReducing {
    private let maxEdge: CGFloat = 1600
    private let maxBytes = 800_000
    private let qualitySteps: [CGFloat] = [0.5, 0.4, 0.3, 0.25]

    func reduce(_ image: UIImage) -> Data {
        let scaled = downscaled(image)
        var data = scaled.jpegData(compressionQuality: qualitySteps[0]) ?? Data()
        for q in qualitySteps {
            guard let d = scaled.jpegData(compressionQuality: q) else { continue }
            data = d
            if d.count <= maxBytes { break }
        }
        return data
    }

    /// Scale so the longest edge is <= maxEdge; never upscale. Renders at scale 1 so
    /// the resulting bitmap's pixel dimensions match its point dimensions — the JPEG we
    /// emit is decoded back at scale 1, so `UIImage(data:).size` reflects true pixels.
    private func downscaled(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        let factor = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: (w * factor).rounded(), height: (h * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
