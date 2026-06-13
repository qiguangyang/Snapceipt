import UIKit
import PDFKit

/// Renders the FIRST page of a PDF document to a `UIImage` for OCR + the capture
/// pipeline. Single-receipt model: only page 0 is used. Returns nil when the data
/// is not a readable PDF, has no pages, or is password-protected.
enum PDFImageRenderer {
    static func firstPage(_ data: Data, maxDimension: CGFloat = 2000) -> UIImage? {
        guard let document = PDFDocument(data: data),
              !document.isLocked,
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // PDFPage.thumbnail handles the PDF→UIKit coordinate flip and white backing.
        return page.thumbnail(of: size, for: .mediaBox)
    }
}
