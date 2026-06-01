import Foundation

#if DEBUG
/// In-app deterministic APIClient for hermetic XCUITests (selected by -uiTestStub).
/// No network — returns fixed fixtures for the dev account.
final class StubAPIClient: APIClient {
    private func devSession() -> SessionResponse {
        SessionResponse(accessToken: "stub-access", refreshToken: "stub-refresh", expiresIn: 900,
                        user: SessionUser(id: DevAccount.userId, email: DevAccount.email, displayName: "Dev"))
    }
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse { devSession() }
    func magicLinkRequest(email: String) async throws {}
    func magicLinkRequestDev(email: String) async throws -> String? { "stub-dev-token" }
    func magicLinkVerify(token: String) async throws -> SessionResponse { devSession() }
    func refresh(refreshToken: String) async throws -> SessionResponse { devSession() }
    func signOut() async throws {}
    func me() async throws -> MeResponse { MeResponse(user: devSession().user, devices: []) }
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        PushResponse(results: mutations.map { PushResult(mutationId: $0.mutationId, status: "applied", reason: nil, entity: nil) },
                     serverTime: 0)
    }
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: 0)
    }
    func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        // Simulate the extraction round-trip so the `.scanning` stage is reliably
        // observable by XCUITest (otherwise the synchronous decode advances
        // .scanning -> .review in a single MainActor turn and SwiftUI never renders the
        // Scan frame; a sub-second window also slips between XCUITest's ~1s polls). The
        // 2s window sits comfortably inside the test's 5s scan-title / 8s Save waits.
        // DEBUG-only stub.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let json = """
        {"requestId":"stub-1",
         "receipt":{"merchant":"The Grounds","date":"\(capturedAt ?? "2026-05-28")","currencyCode":"AUD",
           "total":42.50,"gst":3.86,"category":"meals","deductible":50,
           "lineItems":[{"name":"Flat White x2","price":9.00},{"name":"Big Brekkie","price":24.00}],
           "confidence":0.92,"needsReview":false},
         "meta":{"model":"stub","source":"\(source)","latencyMs":1,"attempts":1,"stub":true}}
        """
        return try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }
    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        UploadedImage(imageKey: "u/\(DevAccount.userId)/stub.jpg",
                      getUrl: "/images/u/\(DevAccount.userId)/stub.jpg",
                      byteSize: jpeg.count)
    }
    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult {
        // Deterministic stub for the hermetic UI test (no network).
        if format == "accountant" {
            return .sent(status: "sent", outboxId: "stub-outbox")
        }
        return .download(url: "/export/dl/stub-token", expiresAt: 1_790_000_000_000)
    }
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        UpdateDeviceResponse(id: "stub-device")
    }
    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        SendQuoteResponse(number: "SN-0001", sentAt: 1_790_000_000_000, status: "sent",
                          subtotalCents: 40_000, gstCents: 4_000, totalCents: 44_000,
                          pdfUrl: "/quotes/dl/stub-token", expiresAt: 1_790_000_000_000, emailed: false)
    }
}
#endif
