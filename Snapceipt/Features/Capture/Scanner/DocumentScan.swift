import UIKit
import Vision
import CoreImage

/// Four corners of a detected document, in IMAGE pixel space (top-left origin, points).
/// Corners are kept individually so the edge-adjust UI can drag any of them.
struct DocumentQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// A quad inset slightly from the full image — the fallback when nothing is detected,
    /// so the user always has visible handles to drag onto the receipt.
    static func defaultInset(width: CGFloat, height: CGFloat) -> DocumentQuad {
        let ix = width * 0.08, iy = height * 0.08
        return DocumentQuad(
            topLeft: CGPoint(x: ix, y: iy),
            topRight: CGPoint(x: width - ix, y: iy),
            bottomRight: CGPoint(x: width - ix, y: height - iy),
            bottomLeft: CGPoint(x: ix, y: height - iy))
    }
}

enum DocumentScan {
    /// Detect the document quad in an upright (`.up`) image via Vision. Returns nil when
    /// nothing is found so the caller can fall back to a default inset quad.
    static func detect(in image: UIImage) -> DocumentQuad? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first else { return nil }
        // Vision normalized coords have a BOTTOM-left origin; convert to image px, top-left.
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
        return DocumentQuad(topLeft: pt(obs.topLeft), topRight: pt(obs.topRight),
                            bottomRight: pt(obs.bottomRight), bottomLeft: pt(obs.bottomLeft))
    }

    /// Perspective-correct (dewarp) the image onto the quad → a clean, deskewed scan.
    /// Returns nil when the filter can't run; callers fall back to the original image.
    static func dewarp(_ image: UIImage, quad: DocumentQuad) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let h = CGFloat(cg.height)
        let ci = CIImage(cgImage: cg)
        // CIPerspectiveCorrection uses a BOTTOM-left origin; our quad is top-left → flip Y.
        func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: h - p.y) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(v(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(v(quad.topRight), forKey: "inputTopRight")
        filter.setValue(v(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(v(quad.bottomLeft), forKey: "inputBottomLeft")
        guard let out = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgOut = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cgOut)
    }
}
