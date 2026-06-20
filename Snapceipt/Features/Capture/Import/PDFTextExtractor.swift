import Foundation
import PDFKit
import CoreGraphics

/// Extracts the embedded digital text of a PDF in READING ORDER (all pages). PDF
/// receipts/invoices carry perfect selectable text, but `PDFPage.string` flattens a
/// multi-column layout out of order — it mashes a block of item names together and splits
/// their right-aligned prices onto separate lines, so the LLM (and parsers) can't pair
/// name↔price. Instead we use PDFKit's per-line selections and merge the ones that sit on
/// the same visual row (the price column is otherwise a separate "line"), giving faithful
/// rows like "0.977 kg NET @ $10.90/kg  10.65". Returns nil for locked / image-only
/// (scanned) / empty PDFs so the caller can fall back to OCR.
enum PDFTextExtractor {
    static func text(_ data: Data) -> String? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var rows: [String] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i) { rows.append(contentsOf: visualRows(of: page)) }
        }
        let joined = rows.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    /// Reconstruct one string per visual row, top-to-bottom, left-to-right.
    private static func visualRows(of page: PDFPage) -> [String] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else {
            return page.string?.split(separator: "\n").map(String.init) ?? []
        }
        struct Line { let text: String; let box: CGRect }
        var lines = selection.selectionsByLine()
            .map { Line(text: ($0.string ?? "").trimmingCharacters(in: .whitespaces),
                        box: $0.bounds(for: page)) }
            .filter { !$0.text.isEmpty }
        guard !lines.isEmpty else {
            return page.string?.split(separator: "\n").map(String.init) ?? []
        }
        lines.sort { $0.box.midY > $1.box.midY }   // PDF origin is bottom-left → top first

        // Merge consecutive selections that share a visual row (same Y), e.g. a left-column
        // description and its right-column price split by PDFKit.
        var grouped: [[Line]] = []
        for line in lines {
            if let rep = grouped.last?.first,
               abs(rep.box.midY - line.box.midY) <= max(2, rep.box.height * 0.5) {
                grouped[grouped.count - 1].append(line)
            } else {
                grouped.append([line])
            }
        }
        return grouped.map { row in
            row.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: "  ")
        }
    }
}
