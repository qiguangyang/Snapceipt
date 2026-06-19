import Testing
import Foundation
@testable import Snapceipt

@Suite("SendQuote response + mock")
struct SendQuoteResponseTests {
    @Test("SendQuoteResponse decodes the {url, emailed, number} send payload")
    func decode() throws {
        let json = """
        {"url":"https://api.snapceipt.cc/q/tok","emailed":true,"number":"SN-0001"}
        """
        let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
        #expect(r.url == "https://api.snapceipt.cc/q/tok")
        #expect(r.emailed == true)
        #expect(r.number == "SN-0001")
    }

    @Test("SendQuoteResponse tolerates a null url/number (email off, no link yet)")
    func decodeNulls() throws {
        let json = """
        {"url":null,"emailed":false,"number":null}
        """
        let r = try JSONDecoder().decode(SendQuoteResponse.self, from: Data(json.utf8))
        #expect(r.url == nil)
        #expect(r.number == nil)
        #expect(r.emailed == false)
    }

    @Test("MockAPIClient records the sendQuote call and returns the scripted response")
    func mockRecords() async throws {
        let mock = MockAPIClient()
        mock.sendQuoteHandler = { _ in
            SendQuoteResponse(url: nil, emailed: false, number: "SN-0007")
        }
        let r = try await mock.sendQuote("q-1")
        #expect(mock.sendQuoteCalls == ["q-1"])
        #expect(r.number == "SN-0007")
        #expect(r.emailed == false)
    }
}
