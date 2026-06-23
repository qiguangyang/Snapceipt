import Testing
import Foundation
@testable import Snapceipt

@MainActor
struct OnDeviceGuardsTests {
    private func receipt(total: Decimal, gst: Decimal?) -> ExtractedReceipt {
        ExtractedReceipt(merchant: "M", date: "2026-06-20", total: total, gst: gst,
                         categoryKey: "meals", deductible: 50, lineItems: [],
                         confidence: 0.9, needsReview: false)
    }

    @Test("honors a printed GST even slightly above total/11 (surcharge)")
    func honorsPrintedGst() {
        let out = OnDeviceGuards.reconcile(receipt(total: 117.23, gst: 99),
                                           ocrText: "Subtotal 115.50\nGST 11.55\nTotal 117.23")
        #expect(out.gst == Decimal(string: "11.55"))
    }

    @Test("clamps a hallucinated GST to total/11 when no printed GST line")
    func clampsGst() {
        let out = OnDeviceGuards.reconcile(receipt(total: 110.0, gst: 88), ocrText: "Total 110.00")
        #expect(out.gst == Decimal(string: "10.0")) // 110/11
    }

    @Test("empty() yields a blank pending draft dated capturedAt")
    func emptyDraft() {
        let e = ExtractedReceipt.empty(capturedAt: "2026-06-24", extractionStatus: "pending")
        #expect(e.merchant == "")
        #expect(e.total == 0)
        #expect(e.date == "2026-06-24")
        #expect(e.extractionStatus == "pending")
        #expect(e.needsReview == true)
        #expect(e.lineItems.isEmpty)
    }

    @Test("total == 0 yields nil GST")
    func zeroTotalNilGst() {
        let out = OnDeviceGuards.reconcile(receipt(total: 0, gst: 5), ocrText: "GST 5.00\nTotal 0.00")
        #expect(out.gst == nil)
        #expect(out.total == 0)
    }

    @Test("FMReceipt maps to ExtractedReceipt (Double->Decimal exact, nil date backfills to capturedAt) under guards")
    func fmMapping() {
        let mapped = FoundationModelMapping.toReceipt(
            merchant: "Cafe", date: nil, total: 10.0, gst: 0.91,
            category: "meals", deductible: 50,
            items: [("Latte", 5.0), ("Tart", 5.0)], confidence: 0.85,
            capturedAt: "2026-06-24",
            ocrText: "Cafe\nGST 0.91\nTotal 10.00")
        #expect(mapped.merchant == "Cafe")
        #expect(mapped.date == "2026-06-24")          // nil date backfills to capturedAt
        #expect(mapped.total == Decimal(string: "10.00"))
        #expect(mapped.gst == Decimal(string: "0.91"))
        #expect(mapped.lineItems.count == 2)
        #expect(mapped.confidence == 0.85)
        #expect(mapped.needsReview == false)          // confidence 0.85 >= 0.8
    }
}
