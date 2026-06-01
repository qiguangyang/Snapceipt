import Foundation
@testable import Snapceipt

/// The single shared `APIClient` test double (reused by SyncEngine, auth, and shell
/// tests). Auth methods are scriptable closures; sync methods are scripted via a
/// push handler + a queue of pull pages, and every call is recorded for assertions.
///
/// `@unchecked Sendable`: instances are only ever touched on the MainActor in tests
/// (the SyncEngine is `@MainActor`), so the mutable recording arrays are not raced.
final class MockAPIClient: APIClient, @unchecked Sendable {

    // MARK: Auth scripting (unused by SyncEngine tests — default to a thrown error)

    var authAppleHandler: ((AppleAuthBody) async throws -> SessionResponse)?
    var magicLinkRequestHandler: ((String) async throws -> Void)?
    var magicLinkRequestDevHandler: ((String) async throws -> String?)?
    var magicLinkVerifyHandler: ((String) async throws -> SessionResponse)?
    var refreshHandler: ((String) async throws -> SessionResponse)?
    var signOutHandler: (() async throws -> Void)?
    var meHandler: (() async throws -> MeResponse)?

    // MARK: Sync scripting

    /// Builds the push response for a given batch of mutations.
    var pushHandler: (([PushMutation]) -> PushResponse)?
    /// Pages returned by successive `syncPull` calls; the first is dequeued each call.
    var pullPages: [PullResponse] = []

    // MARK: Capture scripting

    var extractHandler: ((_ ocrText: String, _ source: String, _ capturedAt: String?) async throws -> ExtractionResponse)?
    var uploadImageHandler: ((_ jpeg: Data, _ transactionId: String?, _ width: Int, _ height: Int) async throws -> UploadedImage)?
    var exportHandler: ((_ profileId: String, _ format: String, _ from: String, _ to: String, _ toEmail: String?) async throws -> ExportResult)?
    var updateDeviceHandler: ((UpdateDeviceBody) async throws -> UpdateDeviceResponse)?
    var sendQuoteHandler: ((String) async throws -> SendQuoteResponse)?

    private(set) var extractCalls: [(ocrText: String, source: String, capturedAt: String?)] = []
    private(set) var uploadCalls: [(transactionId: String?, width: Int, height: Int, byteCount: Int)] = []
    private(set) var exportCalls: [(profileId: String, format: String, from: String, to: String, toEmail: String?)] = []
    private(set) var updateDeviceCalls: [UpdateDeviceBody] = []
    private(set) var sendQuoteCalls: [String] = []

    // MARK: Recorded calls

    private(set) var pushCalls: [[PushMutation]] = []
    private(set) var pullCursors: [String?] = []

    init() {}

    // MARK: APIClient

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse {
        guard let h = authAppleHandler else { throw MockAPIClientError.unscripted }
        return try await h(body)
    }

    func magicLinkRequest(email: String) async throws {
        guard let h = magicLinkRequestHandler else { throw MockAPIClientError.unscripted }
        try await h(email)
    }

    func magicLinkRequestDev(email: String) async throws -> String? {
        guard let h = magicLinkRequestDevHandler else { throw MockAPIClientError.unscripted }
        return try await h(email)
    }

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        guard let h = magicLinkVerifyHandler else { throw MockAPIClientError.unscripted }
        return try await h(token)
    }

    func refresh(refreshToken: String) async throws -> SessionResponse {
        guard let h = refreshHandler else { throw MockAPIClientError.unscripted }
        return try await h(refreshToken)
    }

    func signOut() async throws {
        if let h = signOutHandler { try await h() }
    }

    func me() async throws -> MeResponse {
        guard let h = meHandler else { throw MockAPIClientError.unscripted }
        return try await h()
    }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        pushCalls.append(mutations)
        guard let h = pushHandler else { return PushResponse(results: [], serverTime: 0) }
        return h(mutations)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        pullCursors.append(cursor)
        guard !pullPages.isEmpty else {
            return PullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false, serverTime: 0)
        }
        return pullPages.removeFirst()
    }

    func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        extractCalls.append((ocrText, source, capturedAt))
        guard let h = extractHandler else { throw MockAPIClientError.unscripted }
        return try await h(ocrText, source, capturedAt)
    }

    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        uploadCalls.append((transactionId, width, height, jpeg.count))
        guard let h = uploadImageHandler else { throw MockAPIClientError.unscripted }
        return try await h(jpeg, transactionId, width, height)
    }

    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult {
        exportCalls.append((profileId, format, from, to, toEmail))
        guard let h = exportHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, format, from, to, toEmail)
    }

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        updateDeviceCalls.append(body)
        guard let h = updateDeviceHandler else { throw MockAPIClientError.unscripted }
        return try await h(body)
    }

    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        sendQuoteCalls.append(id)
        guard let h = sendQuoteHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }
}

/// Thrown when a scriptable mock method is called without a handler set.
enum MockAPIClientError: Error { case unscripted }
