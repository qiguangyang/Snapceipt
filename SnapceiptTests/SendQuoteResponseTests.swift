import Testing
import Foundation
@testable import Snapceipt

@Suite("SendQuote response + mock")
struct SendQuoteResponseTests {
    @Test("SendQuoteResponse decodes the camelCase send payload")
    func decode() throws {
        let json = """
        {"number":"SN-0001","sentAt":1717200000000,"status":"sent",
         "subtotalCents":40000,"gstCents":4000,"totalCents":44000,
         "pdfUrl":"/quotes/dl/tok","expiresAt":1717804800000,"emailed":true}
        """
        let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
        #expect(r.number == "SN-0001")
        #expect(r.sentAt == 1717200000000)
        #expect(r.status == "sent")
        #expect(r.subtotalCents == 40000)
        #expect(r.gstCents == 4000)
        #expect(r.totalCents == 44000)
        #expect(r.pdfUrl == "/quotes/dl/tok")
        #expect(r.expiresAt == 1717804800000)
        #expect(r.emailed == true)
    }

    @Test("SendQuoteResponse tolerates a null number/pdfUrl/expiresAt (email off)")
    func decodeNulls() throws {
        let json = """
        {"number":null,"sentAt":1,"status":"sent","subtotalCents":1,"gstCents":0,
         "totalCents":1,"pdfUrl":null,"expiresAt":null,"emailed":false}
        """
        let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
        #expect(r.number == nil)
        #expect(r.pdfUrl == nil)
        #expect(r.expiresAt == nil)
        #expect(r.emailed == false)
    }

    @Test("MockAPIClient records the sendQuote call and returns the scripted response")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.sendQuoteHandler = { _ in
            SendQuoteResponse(number: "SN-0007", sentAt: 5, status: "sent",
                              subtotalCents: 100, gstCents: 10, totalCents: 110,
                              pdfUrl: nil, expiresAt: nil, emailed: false)
        }
        let r = try await mock.sendQuote("q-1")
        #expect(mock.sendQuoteCalls == ["q-1"])
        #expect(r.number == "SN-0007")
        #expect(r.emailed == false)
    }
}
