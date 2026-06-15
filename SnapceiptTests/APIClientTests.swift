import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct APIClientTests {
    /// A fresh AuthStore + LiveAPIClient over the mock session, with a known seeded session.
    private func makeClient(seedBearer: String? = "seed-access-token") -> (LiveAPIClient, AuthStore) {
        let auth = AuthStore()
        auth.clear()
        if let seedBearer {
            auth.save(SessionResponse(
                accessToken: seedBearer,
                refreshToken: "seed-refresh-token",
                expiresIn: 900,
                user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")
            ))
        }
        let client = LiveAPIClient(
            baseURL: URL(string: "https://api.test")!,
            auth: auth,
            session: MockURLProtocol.makeSession()
        )
        return (client, auth)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("magicLinkVerify decodes a SessionResponse")
    func magicLinkVerifyDecodes() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"accessToken":"acc.jwt.tok","refreshToken":"refresh-0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u1","email":"a@b.com","displayName":"Ada"}}
            """))
        }
        let session = try await client.magicLinkVerify(token: "magic-token")
        #expect(session.accessToken == "acc.jwt.tok")
        #expect(session.expiresIn == 900)
        #expect(session.user.id == "u1")
        #expect(session.user.email == "a@b.com")
        #expect(session.user.displayName == "Ada")
        // verify hit the right path/method
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/magic-link/verify")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test("SessionResponse tolerates null email/displayName")
    func sessionNullableUser() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"accessToken":"a","refreshToken":"r0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u9","email":null,"displayName":null}}
            """))
        }
        let session = try await client.magicLinkVerify(token: "t")
        #expect(session.user.email == nil)
        #expect(session.user.displayName == nil)
    }

    @Test("an error body decodes into APIError with the backend code + status")
    func errorEnvelopeDecodes() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (404, [:], self.json("""
            {"error":{"code":"NOT_FOUND","message":"missing","requestId":"req-123"}}
            """))
        }
        await #expect(throws: APIError.self) {
            _ = try await client.me()
        }
        do {
            _ = try await client.me()
            Issue.record("expected APIError")
        } catch let e as APIError {
            #expect(e.code == "NOT_FOUND")
            #expect(e.message == "missing")
            #expect(e.status == 404)
        }
    }

    @Test("syncPull decodes changes + nextCursor + hasMore + serverTime")
    func syncPullDecodes() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"changes":[
               {"type":"transaction","id":"t1","userId":"u1","profileId":"p1","createdAt":10,"updatedAt":20,
                "deletedAt":null,"rev":1,"lastEditedDeviceId":"d1","merchant":"The Grounds","amount_cents":-1250},
               {"type":"profile","id":"p1","userId":"u1","createdAt":1,"updatedAt":2,
                "deletedAt":null,"rev":1,"lastEditedDeviceId":null,"name":"Personal"}
             ],
             "nextCursor":"eyJ0cyI6MjAsImlkIjoidDEifQ","hasMore":false,"serverTime":99999}
            """))
        }
        let pull = try await client.syncPull(cursor: nil, limit: 500)
        #expect(pull.changes.count == 2)
        #expect(pull.nextCursor == "eyJ0cyI6MjAsImlkIjoidDEifQ")
        #expect(pull.hasMore == false)
        #expect(pull.serverTime == 99999)
        // the raw envelope keeps both camelCase + snake_case fields accessible
        #expect(pull.changes[0].type == "transaction")
        #expect(pull.changes[0].id == "t1")
        #expect(pull.changes[0].updatedAt == 20)
        #expect(pull.changes[0].deletedAt == nil)
        #expect(pull.changes[0].string("merchant") == "The Grounds")
        #expect(pull.changes[0].int("amount_cents") == -1250)
        // query string carries the limit
        let q = MockURLProtocol.lastRequest?.url?.query ?? ""
        #expect(q.contains("limit=500"))
    }

    @Test("authenticated requests attach the Bearer + X-Device-Id headers")
    func attachesAuthHeaders() async throws {
        let (client, auth) = makeClient(seedBearer: "the-access-token")
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"user":{"id":"u1","email":"a@b.com","displayName":"Ada"},"devices":[{"id":"d1"}]}
            """))
        }
        let me = try await client.me()
        #expect(me.user.id == "u1")
        #expect(me.devices.count == 1)
        #expect(me.devices.first?.id == "d1")
        let req = MockURLProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer the-access-token")
        #expect(req?.value(forHTTPHeaderField: "X-Device-Id") == auth.deviceId)
    }

    @Test("a 401 triggers a single refresh then a retry with the new token")
    func autoRefreshOn401() async throws {
        let (client, auth) = makeClient(seedBearer: "stale-token")
        var phase = 0
        MockURLProtocol.setHandler { req in
            switch phase {
            case 0:
                // first /auth/me with the stale token -> 401
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token")
                phase = 1
                return (401, [:], self.json("""
                {"error":{"code":"AUTH_INVALID_TOKEN","message":"expired","requestId":"r1"}}
                """))
            case 1:
                // refresh call -> new session
                #expect(req.url?.path == "/auth/refresh")
                phase = 2
                return (200, [:], self.json("""
                {"accessToken":"fresh-token","refreshToken":"fresh-refresh-0123456789abcdef0123456789ab","expiresIn":900,
                 "user":{"id":"u1","email":"a@b.com","displayName":"Ada"}}
                """))
            default:
                // retried /auth/me with the refreshed token -> 200
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
                return (200, [:], self.json("""
                {"user":{"id":"u1","email":"a@b.com","displayName":"Ada"},"devices":[]}
                """))
            }
        }
        let me = try await client.me()
        #expect(me.user.id == "u1")
        #expect(auth.bearer() == "Bearer fresh-token")
        #expect(phase == 2)
    }

    @Test("magicLinkRequest sends the email and returns on 202")
    func magicLinkRequestSucceeds() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.magicLinkRequest(email: "user@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/magic-link/request")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "user@example.com")
    }

    @Test("magicLinkRequestDev returns the devToken from the 202 body")
    func magicLinkRequestDevReturnsDevTokenFrom202Body() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (202, ["Content-Type": "application/json"], self.json(#"{"devToken":"dev-tok-123"}"#))
        }
        let token = try await client.magicLinkRequestDev(email: "dev@snapceipt.cc")
        #expect(token == "dev-tok-123")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/magic-link/request")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test("magicLinkRequestDev returns nil when the 202 body has no token")
    func magicLinkRequestDevReturnsNilWhenNoToken() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        let token = try await client.magicLinkRequestDev(email: "dev@snapceipt.cc")
        #expect(token == nil)
    }

    @Test("extract POSTs /extract with AUD/en-AU + a requestId and decodes the receipt")
    func extractPostsAndDecodes() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"requestId":"srv-1",
             "receipt":{"merchant":"The Grounds","date":"2026-05-28","currencyCode":"AUD",
               "total":42.50,"gst":3.86,"category":"meals","deductible":50,
               "lineItems":[{"name":"Flat White","price":9.00}],"confidence":0.98,"needsReview":false},
             "meta":{"model":"deepseek-chat","source":"scan","latencyMs":5,"attempts":1,"stub":false}}
            """))
        }
        let resp = try await client.extract(ocrText: "THE GROUNDS\nTOTAL 42.50",
                                            source: "scan", capturedAt: "2026-05-28")
        #expect(resp.receipt.categoryKey == "meals")
        #expect(resp.receipt.total == Decimal(string: "42.50"))
        #expect(MockURLProtocol.lastRequest?.url?.path == "/extract")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["ocrText"] as? String == "THE GROUNDS\nTOTAL 42.50")
        #expect(obj?["source"] as? String == "scan")
        #expect(obj?["defaultCurrency"] as? String == "AUD")
        #expect(obj?["locale"] as? String == "en-AU")
        #expect(obj?["capturedAt"] as? String == "2026-05-28")
        #expect((obj?["requestId"] as? String)?.isEmpty == false)
    }

    @Test("magicLinkRequest body includes the install deviceId")
    func magicLinkRequestSendsDeviceId() async throws {
        let (client, auth) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.magicLinkRequest(email: "user@example.com")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "user@example.com")
        #expect(obj?["deviceId"] as? String == auth.deviceId)
        // The header is still attached too (binding source of truth).
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Device-Id") == auth.deviceId)
    }

    @Test("otpRequest POSTs /auth/otp/request with the email")
    func otpRequestPosts() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.otpRequest(email: "code@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/otp/request")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "code@example.com")
    }

    @Test("otpVerify POSTs /auth/otp/verify and decodes a SessionResponse")
    func otpVerifyDecodes() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"accessToken":"a.b.c","refreshToken":"refresh-0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u1","email":"code@example.com","displayName":null}}
            """))
        }
        let session = try await client.otpVerify(email: "code@example.com", code: "123456")
        #expect(session.user.email == "code@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/otp/verify")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "code@example.com")
        #expect(obj?["code"] as? String == "123456")
    }

    @Test("uploadImage POSTs raw JPEG to /images with transactionId/width/height query params")
    func uploadImagePostsRawJPEG() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"imageKey":"u/u1/abc.jpg","getUrl":"/images/u/u1/abc.jpg","byteSize":1234}
            """))
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let out = try await client.uploadImage(jpeg: jpeg, transactionId: "t1", width: 1200, height: 1600)
        #expect(out.imageKey == "u/u1/abc.jpg")
        #expect(out.getUrl == "/images/u/u1/abc.jpg")
        #expect(out.byteSize == 1234)
        let req = MockURLProtocol.lastRequest
        #expect(req?.url?.path == "/images")
        #expect(req?.httpMethod == "POST")
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        let q = req?.url?.query ?? ""
        #expect(q.contains("transactionId=t1"))
        #expect(q.contains("width=1200"))
        #expect(q.contains("height=1600"))
        let sent = req?.httpBodyData() ?? Data()
        #expect(sent == jpeg)
    }
}

/// Test helper: URLProtocol strips httpBody into a stream, so read it back for assertions.
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
