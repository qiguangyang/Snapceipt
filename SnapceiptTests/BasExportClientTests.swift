import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct BasExportClientTests {
    private func makeClient() -> LiveAPIClient {
        let auth = AuthStore(); auth.clear()
        auth.save(SessionResponse(accessToken: "acc", refreshToken: "refresh-0123456789abcdef0123456789abcdef",
                                  expiresIn: 900, user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")))
        return LiveAPIClient(baseURL: URL(string: "https://api.test")!, auth: auth,
                             session: MockURLProtocol.makeSession())
    }
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("bas export decodes the basPack result + posts the bas body")
    func basPack() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"],
             self.json(#"{"pdfUrl":"/export/dl/p","csvUrl":"/export/dl/c","expiresAt":1790000000000,"emailed":false,"bas":{"g1":1100000,"oneA":100000,"oneB":30000,"netGst":70000,"payg":0,"totalPayable":70000}}"#))
        }
        let result = try await client.exportBas(profileId: "p1", from: "2026-04-01", to: "2026-06-30",
                                                paygInstalmentCents: 0, toEmail: nil)
        guard case let .basPack(pdfUrl, csvUrl, expiresAt, emailed, bas) = result else {
            Issue.record("expected .basPack"); return
        }
        #expect(pdfUrl == "/export/dl/p")
        #expect(csvUrl == "/export/dl/c")
        #expect(expiresAt == 1790000000000)
        #expect(emailed == false)
        #expect(bas.oneA == 100000 && bas.netGst == 70000 && bas.totalPayable == 70000)
        // body assertions
        let bodyData = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(obj?["format"] as? String == "bas")
        #expect(obj?["from"] as? String == "2026-04-01")
        let basBody = obj?["bas"] as? [String: Any]
        #expect(basBody?["paygInstalmentCents"] as? Int == 0)
    }
}

private extension URLRequest {
    func httpBodyData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize); defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize); if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
