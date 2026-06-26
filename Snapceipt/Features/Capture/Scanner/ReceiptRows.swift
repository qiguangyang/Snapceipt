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

    /// A monospace, COLUMN-ALIGNED reconstruction of the receipt for the LLM: each observation is
    /// placed at its real horizontal position (padded with spaces) on its visual row, so the model
    /// sees the receipt's 2D layout — item names in the left column, prices in the right — instead of
    /// a flat token stream. Rows are split on a real vertical gap (gap from the previous observation
    /// > ~0.6 median glyph height); within a row, tokens are laid out by X. With no geometry (PDF
    /// text already in reading order) the texts are returned newline-joined unchanged.
    static func layoutGrid(from lines: [RecognizedLine], columns: Int = 52) -> String {
        guard lines.contains(where: { $0.boundingBox != .zero }) else {
            return lines.map { $0.text }.joined(separator: "\n")
        }
        let minX = lines.map { $0.boundingBox.minX }.min() ?? 0
        let maxX = lines.map { $0.boundingBox.maxX }.max() ?? 1
        let xRange = max(maxX - minX, 1)
        let heights = lines.compactMap { $0.boundingBox.height > 0 ? $0.boundingBox.height : nil }.sorted()
        // Vision boundingBoxes are NORMALIZED (0…1) — thresholds MUST be relative to the median
        // glyph height (an absolute pixel floor spans the whole receipt and collapses every row).
        let medianH = heights.isEmpty ? 0.02 : heights[heights.count / 2]
        let tol = medianH * 0.8
        // A price shares its name's row or sits just BELOW it (per-column baseline offset); an amount
        // clearly ABOVE a name is the PREVIOUS row's price, so don't let a name grab it on a tie.
        let aboveSlack = medianH * 0.3

        // Column-aware rows: the AMOUNT column is cleanly Y-separated, but a name's center sits a
        // little ABOVE its price (per-column baseline offset), so a single vertical-gap threshold
        // can't split rows. Anchor each row on an amount, then attach every other token to the
        // NEAREST amount within `tol`; tokens far from any amount (headers) stand on their own row.
        let amountRegex = try! Regex(#"\d[\d,]*\.\d{2}"#)
        let amountYs = lines.compactMap { $0.text.firstMatch(of: amountRegex) != nil ? $0.boundingBox.midY : nil }
        var rows: [(y: CGFloat, items: [RecognizedLine])] = []
        for line in lines {
            let y = line.boundingBox.midY
            var nearest: (d: CGFloat, y: CGFloat)?
            for ay in amountYs where ay <= y + aboveSlack {
                let d = abs(ay - y)
                if d <= tol, nearest == nil || d < nearest!.d { nearest = (d, ay) }
            }
            let anchorY = nearest?.y ?? y
            if let i = rows.firstIndex(where: { abs($0.y - anchorY) < 0.0001 }) {
                rows[i].items.append(line)
            } else {
                rows.append((anchorY, [line]))
            }
        }
        // Render rows top-to-bottom (larger normalized Y = higher); tokens padded to their X-column.
        return rows.sorted { $0.y > $1.y }.map { row in
            var s = ""
            for tok in row.items.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
                let col = Int(((tok.boundingBox.minX - minX) / xRange) * CGFloat(columns))
                if s.count < col { s += String(repeating: " ", count: col - s.count) }
                s += tok.text + " "
            }
            return s
        }.joined(separator: "\n")
    }
}
