import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct ExportClientTests {
    private func makeClient() -> LiveAPIClient {
        let auth = AuthStore()
        auth.clear()
        auth.save(SessionResponse(accessToken: "acc", refreshToken: "refresh-0123456789abcdef0123456789abcdef",
                                  expiresIn: 900, user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")))
        return LiveAPIClient(baseURL: URL(string: "https://api.test")!, auth: auth,
                             session: MockURLProtocol.makeSession())
    }
    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("csv export decodes the download result + posts the right body")
    func csvDownload() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"],
             self.json(#"{"url":"/export/dl/tok123","expiresAt":1790000000000}"#))
        }
        let result = try await client.export(profileId: "p1", format: "csv",
                                              from: "2026-06-01", to: "2026-06-30", toEmail: nil)
        guard case let .download(url, expiresAt) = result else {
            Issue.record("expected .download"); return
        }
        #expect(url == "/export/dl/tok123")
        #expect(expiresAt == 1790000000000)
        #expect(MockURLProtocol.lastRequest?.url?.path == "/export")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        // Assert request body contains the expected keys and no toEmail (nil case)
        let bodyData = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let bodyObj = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        #expect(bodyObj?["profileId"] as? String == "p1")
        #expect(bodyObj?["format"] as? String == "csv")
        #expect(bodyObj?["from"] as? String == "2026-06-01")
        #expect(bodyObj?["to"] as? String == "2026-06-30")
        #expect(bodyObj?["toEmail"] == nil)
    }

    @Test("accountant export decodes the sent result")
    func accountantSent() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json(#"{"status":"sent","outboxId":"ob-9"}"#))
        }
        let result = try await client.export(profileId: "p1", format: "accountant",
                                             from: "2026-06-01", to: "2026-06-30", toEmail: "cpa@firm.au")
        guard case let .sent(status, outboxId) = result else {
            Issue.record("expected .sent"); return
        }
        #expect(status == "sent")
        #expect(outboxId == "ob-9")
    }

    @Test("a backend error surfaces as APIError")
    func validationError() async throws {
        let client = makeClient()
        MockURLProtocol.setHandler { _ in
            // Backend maps VALIDATION_FAILED -> 400 (src/lib/errors.ts); the
            // backend plan returns 400 for from > to. Match that contract here.
            (400, [:], self.json(#"{"error":{"code":"VALIDATION_FAILED","message":"from > to","requestId":"r1"}}"#))
        }
        do {
            _ = try await client.export(profileId: "p1", format: "csv",
                                        from: "2026-06-30", to: "2026-06-01", toEmail: nil)
            Issue.record("expected throw")
        } catch let e as APIError {
            #expect(e.code == "VALIDATION_FAILED")
            #expect(e.status == 400)
        }
    }
}

/// URLProtocol moves httpBody into a stream; this helper reads it back for assertions.
private extension URLRequest {
    func httpBodyData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
