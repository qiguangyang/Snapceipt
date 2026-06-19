import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite("InvoiceTotals")
struct InvoiceTotalsTests {
    private func lines(_ ctx: ModelContext, _ specs: [(Int, Int)]) -> [InvoiceLineItem] {
        specs.map { (qty, unit) in
            let l = InvoiceLineItem(userId: "u1", invoiceId: "inv1",
                                    itemDescription: "x", quantity: qty, unitPriceCents: unit)
            ctx.insert(l); return l
        }
    }

    @Test("exclusive GST: gst added on top")
    func exclusive() throws {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let t = InvoiceTotals.compute(lineItems: lines(ctx, [(2, 100_00)]), gstEnabled: true)
        #expect(t.subtotal == 200_00)
        #expect(t.gst == 20_00)
        #expect(t.total == 220_00)
    }

    @Test("inclusive GST: total stays the entered sum, gst is embedded")
    func inclusive() throws {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let t = InvoiceTotals.compute(lineItems: lines(ctx, [(1, 165_00), (1, 45_00)]),
                                      gstEnabled: true, gstInclusive: true)
        #expect(t.total == 210_00)
        #expect(t.gst == 19_09)
        #expect(t.subtotal == 190_91)
    }

    @Test("gst off zeroes the gst component")
    func off() throws {
        let ctx = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let t = InvoiceTotals.compute(lineItems: lines(ctx, [(1, 100_00)]), gstEnabled: false)
        #expect(t.gst == 0)
        #expect(t.total == 100_00)
    }
}
