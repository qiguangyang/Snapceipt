import Foundation
import CoreGraphics

/// Reconstruct visual rows from OCR observations: group observations that share a visual row
/// (vertical overlap), sort each row left-to-right, and join. Apple Vision emits an item's
/// left-column name and its right-column price as SEPARATE observations, so this pairs
/// "Flat White" + "5.00" into one row "Flat White 5.00" — essential before line-item
/// extraction and when building the text sent to the extractor. With no geometry (all boxes
/// `.zero`, e.g. PDF text already extracted in reading order) the texts are returned unchanged.
enum ReceiptRows {
    static func rows(from lines: [RecognizedLine]) -> [String] {
        guard lines.contains(where: { $0.boundingBox != .zero }) else {
            return lines.map { $0.text }
        }
        // Vision origin is bottom-left → larger midY = higher on the receipt.
        let sorted = lines.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[RecognizedLine]] = []
        for line in sorted {
            if let lastIdx = rows.indices.last,
               rows[lastIdx].contains(where: { sameRow($0.boundingBox, line.boundingBox) }) {
                rows[lastIdx].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .map { $0.text }
                .joined(separator: " ")
        }
    }

    /// Two boxes share a visual row when their vertical ranges overlap by more than 40% of
    /// the shorter box's height.
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let minHeight = min(a.height, b.height)
        return minHeight > 0 && overlap > 0.4 * minHeight
    }
}
