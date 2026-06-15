import Testing
import Foundation
@testable import Snapceipt

struct ExtractionResponseTests {
    private func decode(_ s: String) throws -> ExtractionResponse {
        try JSONDecoder().decode(ExtractionResponse.self, from: Data(s.utf8))
    }

    @Test("decodes the /extract response and maps category -> categoryKey")
    func decodesResponse() throws {
        let resp = try decode("""
        {"requestId":"r1",
         "receipt":{"merchant":"The Grounds","date":"2026-05-28","currencyCode":"AUD",
           "total":42.50,"gst":3.86,"category":"meals","deductible":50,
           "lineItems":[{"name":"Flat White x2","price":9.00},{"name":"Big Brekkie","price":24.00}],
           "confidence":0.98,"needsReview":false},
         "meta":{"model":"deepseek-chat","source":"scan","latencyMs":812,"attempts":1,"stub":false}}
        """)
        #expect(resp.requestId == "r1")
        #expect(resp.receipt.merchant == "The Grounds")
        #expect(resp.receipt.categoryKey == "meals")
        #expect(resp.receipt.total == Decimal(string: "42.50"))
        #expect(resp.receipt.gst == Decimal(string: "3.86"))
        #expect(resp.receipt.deductible == 50)
        #expect(resp.receipt.lineItems.count == 2)
        #expect(resp.receipt.lineItems[0].name == "Flat White x2")
        #expect(resp.receipt.lineItems[0].price == Decimal(string: "9.00"))
        #expect(resp.meta.stub == false)
    }

    @Test("decodes a null gst")
    func decodesNullGST() throws {
        let resp = try decode("""
        {"requestId":"r2",
         "receipt":{"merchant":"Payout","date":"2026-05-01","currencyCode":"AUD",
           "total":0,"gst":null,"category":"income","deductible":null,
           "lineItems":[],"confidence":0.9,"needsReview":false},
         "meta":{"model":"stub","source":"scan","latencyMs":1,"attempts":1,"stub":true}}
        """)
        #expect(resp.receipt.gst == nil)
        #expect(resp.receipt.deductible == nil)
    }

    @Test("builds an editable draft from a successful response (status done)")
    func draftFromResponse() throws {
        let resp = try decode("""
        {"requestId":"r1",
         "receipt":{"merchant":"Cafe","date":"2026-05-28","currencyCode":"AUD",
           "total":10.00,"gst":0.91,"category":"meals","deductible":50,
           "lineItems":[{"name":"Latte","price":5.00}],"confidence":0.95,"needsReview":false},
         "meta":{"model":"deepseek-chat","source":"scan","latencyMs":5,"attempts":1,"stub":false}}
        """)
        let draft = ExtractedReceipt(response: resp)
        #expect(draft.merchant == "Cafe")
        #expect(draft.categoryKey == "meals")
        #expect(draft.extractionStatus == "done")
        #expect(draft.needsReview == false)
        #expect(draft.lineItems.count == 1)
    }

    @Test("decodes meta.capped and meta.smartScan when present")
    func decodesCappedMeta() throws {
        let resp = try decode("""
        {"requestId":"r3",
         "receipt":{"merchant":"Kmart","date":"2026-06-15","currencyCode":"AUD",
           "total":19.99,"gst":1.82,"category":"office","deductible":100,
           "lineItems":[],"confidence":0.45,"needsReview":true},
         "meta":{"model":"heuristic","source":"scan","latencyMs":2,"attempts":1,"stub":false,
                 "capped":true,"smartScan":{"used":10,"cap":10,"plan":"free"}}}
        """)
        #expect(resp.meta.capped == true)
        #expect(resp.meta.smartScan?.used == 10)
        #expect(resp.meta.smartScan?.cap == 10)
        #expect(resp.meta.smartScan?.plan == "free")
    }

    @Test("capped defaults to false and smartScan is nil when both fields are absent (stub/offline)")
    func cappedDefaultsFalseWhenAbsent() throws {
        let resp = try decode("""
        {"requestId":"r4",
         "receipt":{"merchant":"Stub","date":"2026-06-15","currencyCode":"AUD",
           "total":5.00,"gst":null,"category":"office","deductible":100,
           "lineItems":[],"confidence":0.4,"needsReview":true},
         "meta":{"model":"stub","source":"scan","latencyMs":1,"attempts":1,"stub":true}}
        """)
        #expect(resp.meta.capped == false)
        #expect(resp.meta.smartScan == nil)
    }

    @Test("builds an editable draft from a heuristic ParsedReceipt (status pending, needsReview)")
    func draftFromParsed() {
        var parsed = ParsedReceipt()
        parsed.merchant = "Woolworths"
        parsed.total = Decimal(string: "22.00")!
        parsed.tax = Decimal(string: "2.00")!
        // Pin the parsed date (UTC) so this test is date-deterministic. The parsed
        // date wins over capturedAt — `ymd(parsed.date) ?? capturedAt` only falls back
        // to capturedAt when ymd is nil, which never happens for a non-nil Date.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        parsed.date = cal.date(from: DateComponents(year: 2026, month: 5, day: 28, hour: 12))!
        let draft = ExtractedReceipt(parsed: parsed, capturedAt: "2026-05-30")
        #expect(draft.merchant == "Woolworths")
        #expect(draft.total == Decimal(string: "22.00"))
        #expect(draft.gst == Decimal(string: "2.00"))
        #expect(draft.categoryKey == "office")   // fallback default category
        #expect(draft.deductible == 100)         // fallback default deductible
        #expect(draft.extractionStatus == "pending")
        #expect(draft.needsReview == true)
        #expect(draft.date == "2026-05-28")   // parsed date wins over capturedAt
    }
}
