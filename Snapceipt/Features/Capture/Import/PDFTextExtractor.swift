import Foundation
import PDFKit

/// Extracts the embedded digital text of a PDF (all pages). PDF receipts/invoices carry
/// perfect selectable text — using it directly is far more accurate than rendering the page
/// to an image and re-OCRing it (which garbles dense line items + drops layout). Returns nil
/// for locked, image-only (scanned) or empty PDFs so the caller can fall back to OCR.
enum PDFTextExtractor {
    static func text(_ data: Data) -> String? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var parts: [String] = []
        for i in 0..<document.pageCount {
            if let s = document.page(at: i)?.string,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(s)
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }
}
