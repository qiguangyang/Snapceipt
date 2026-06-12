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
        // J18b offline seam: throw a transport error BEFORE the canned result so the
        // capture flow falls back to HeuristicParser and enqueues the receipt (outbox).
        // NOTE: `-uiTestOffline` gates only extract/uploadImage — push/pull still succeed,
        // so the transaction row itself syncs; only the image upload + server re-extract
        // are genuinely queued. Reachability.isOnline also stays true (no reconnect flip is
        // simulated). "Offline" in the J18b/J18c names is therefore scoped to the
        // capture-extraction path, not a full network partition.
        if AppLaunch.current.offline {
            throw APIError.uiTestOffline
        }
        // Simulate the extraction round-trip so the `.scanning` stage is reliably
        // observable by XCUITest (otherwise the synchronous decode advances
        // .scanning -> .review in a single MainActor turn and SwiftUI never renders the
        // Scan frame; a sub-second window also slips between XCUITest's ~1s polls). The
        // 2s window sits comfortably inside the test's 5s scan-title / 8s Save waits.
        // DEBUG-only stub.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        // J14: a low-confidence canned variant drives the Review "Double-check…" banner
        // and hides the confidence badge. Bool interpolates as `true`/`false` already.
        let needsReview = AppLaunch.current.cannedNeedsReview
        let json = """
        {"requestId":"stub-1",
         "receipt":{"merchant":"The Grounds","date":"\(capturedAt ?? "2026-05-28")","currencyCode":"AUD",
           "total":42.50,"gst":3.86,"category":"meals","deductible":50,
           "lineItems":[{"name":"Flat White x2","price":9.00},{"name":"Big Brekkie","price":24.00}],
           "confidence":\(needsReview ? 0.40 : 0.92),"needsReview":\(needsReview)},
         "meta":{"model":"stub","source":"\(source)","latencyMs":1,"attempts":1,"stub":true}}
        """
        return try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }
    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        // J18b offline seam: the image upload also fails while offline (mirrors extract;
        // see the scope note on `extract`).
        if AppLaunch.current.offline {
            throw APIError.uiTestOffline
        }
        return UploadedImage(imageKey: "u/\(DevAccount.userId)/stub.jpg",
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
    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "stubtokeninitial",
                             address: "r.stubtokeninitial@in.snapceipt.cc")
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        InboxAddressResponse(profileId: profileId, token: "stubtokenrotated",
                             address: "r.stubtokenrotated@in.snapceipt.cc")
    }
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        EmailChangeRequested(sent: true, devCode: "000000")
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        AccountUser(id: DevAccount.userId, email: "new@example.com", displayName: "Dev", plan: "free")
    }
    func revokeDevice(id: String) async throws {}
    func deleteAccount() async throws {}
}
#endif
