import Testing
import Foundation
import CoreGraphics
@testable import Snapceipt

/// e2e-style test of the on-device receipt reconstruction using the REAL OCR geometry captured from
/// the "Yakitori Yurippi" receipt (normalized 0…1 Vision coords). The names column sits slightly
/// ABOVE its price column, so a single vertical-gap threshold can't split rows — this pins the
/// column-aware pairing (ReceiptRows.layoutGrid) + the geometric total/GST backstops to the
/// receipt's ground truth, so the layout fed to the model is correct without a device.
struct ReceiptLayoutGridTests {

    /// (text, midY, height, minX) — normalized. Names ~0.10, amounts ~0.78, qty ~0.03, labels ~0.05.
    private static let obs: [(String, Double, Double, Double)] = [
        ("Qty Description", 0.528, 0.018, 0.05), ("Amt ($)", 0.530, 0.017, 0.75),
        // items: qty / name / amount per visual row (name center is a touch above its price)
        ("2", 0.490, 0.015, 0.03), ("Orion", 0.490, 0.015, 0.10), ("27.00", 0.490, 0.018, 0.78),
        ("Kawa", 0.473, 0.013, 0.10), ("11.00", 0.472, 0.016, 0.78),
        ("Tebasaki", 0.459, 0.015, 0.10), ("10.00", 0.455, 0.015, 0.78),
        ("Butabara", 0.445, 0.013, 0.10), ("11.50", 0.439, 0.015, 0.78),
        ("Gyu-tan", 0.431, 0.013, 0.10), ("14.50", 0.424, 0.016, 0.78),
        ("Harami", 0.416, 0.015, 0.10), ("15.00", 0.408, 0.016, 0.78),
        ("1", 0.403, 0.016, 0.03), ("Unagi", 0.398, 0.017, 0.10), ("15.00", 0.390, 0.016, 0.78),
        ("1", 0.383, 0.013, 0.03), ("Yamituki Cabbage", 0.380, 0.023, 0.10), ("11.50", 0.373, 0.016, 0.78),
        // totals
        ("Subtotal (9)", 0.343, 0.020, 0.05), ("115.50", 0.335, 0.019, 0.78),
        ("GST", 0.324, 0.017, 0.05), ("11.55", 0.314, 0.017, 0.78),
        ("VISA", 0.304, 0.017, 0.05), ("1.73", 0.294, 0.017, 0.78),
        ("Total", 0.252, 0.031, 0.05), ("117.23", 0.246, 0.036, 0.78),
        ("Zeller", 0.223, 0.017, 0.05), ("117.23", 0.217, 0.022, 0.78),
        ("Change", 0.201, 0.021, 0.05), ("0.00", 0.196, 0.021, 0.78),
    ]

    private static func fixture() -> [RecognizedLine] {
        obs.map { (text, y, h, x) in
            RecognizedLine(text: text, confidence: 1,
                           boundingBox: CGRect(x: x, y: y - h / 2, width: 0.14, height: h))
        }
    }

    @Test("layoutGrid pairs every item name with its own price (column-aware)")
    func itemsPairCorrectly() {
        let grid = ReceiptRows.layoutGrid(from: Self.fixture())
        let rows = grid.split(separator: "\n").map(String.init)
        func paired(_ name: String, _ amount: String) -> Bool {
            rows.contains { $0.contains(name) && $0.contains(amount) }
        }
        #expect(paired("Orion", "27.00"))
        #expect(paired("Kawa", "11.00"))
        #expect(paired("Tebasaki", "10.00"))
        #expect(paired("Butabara", "11.50"))
        #expect(paired("Gyu-tan", "14.50"))
        #expect(paired("Harami", "15.00"))
        #expect(paired("Unagi", "15.00"))
        #expect(paired("Yamituki Cabbage", "11.50"))
        // No item name should land on the Subtotal/GST/Total rows.
        #expect(!rows.contains { $0.contains("Subtotal") && $0.contains("Orion") })
    }

    @Test("deterministic line items parse from the layout (language-independent FM fallback)")
    func fallbackLineItems() {
        let grid = ReceiptRows.layoutGrid(from: Self.fixture())
        let items = OnDeviceGuards.lineItems(fromLayout: grid, total: Decimal(string: "117.23")!)
        let names = items.map(\.name)
        // All 8 food items, each with its own price; quantities stripped from the name.
        #expect(names.contains("Orion"))
        #expect(items.first { $0.name == "Orion" }?.price == Decimal(string: "27.00"))
        #expect(names.contains("Gyu-tan"))
        #expect(items.first { $0.name == "Yamituki Cabbage" }?.price == Decimal(string: "11.50"))
        // Totals / tax / payment / change rows are NOT items.
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("subtotal") })
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("gst") })
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("total") })
        #expect(!names.contains { $0.localizedCaseInsensitiveContains("zeller") })
        #expect(items.count == 8)
    }

    @Test("geometric total + GST read the printed values")
    func totalAndGst() {
        let f = Self.fixture()
        #expect(OnDeviceGuards.geometricTotal(lines: f) == Decimal(string: "117.23"))
        #expect(OnDeviceGuards.geometricGst(lines: f, total: Decimal(string: "117.23")!) == Decimal(string: "11.55"))
    }
}
