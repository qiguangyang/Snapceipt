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
    var otpRequestHandler: ((String) async throws -> Void)?
    var otpVerifyHandler: ((_ email: String, _ code: String) async throws -> SessionResponse)?
    private(set) var otpRequestedEmails: [String] = []
    private(set) var otpVerifiedCodes: [(email: String, code: String)] = []
    var refreshHandler: ((String) async throws -> SessionResponse)?
    var signOutHandler: (() async throws -> Void)?
    var meHandler: (() async throws -> MeResponse)?

    // MARK: Sync scripting

    /// Builds the push response for a given batch of mutations (or throws, e.g. an
    /// `APIError`, to script a transport/HTTP failure).
    var pushHandler: (([PushMutation]) throws -> PushResponse)?
    /// Pages returned by successive `syncPull` calls; the first is dequeued each call.
    var pullPages: [PullResponse] = []

    // MARK: Capture scripting

    var extractHandler: ((_ ocrText: String, _ source: String, _ capturedAt: String?) async throws -> ExtractionResponse)?
    var uploadImageHandler: ((_ jpeg: Data, _ transactionId: String?, _ width: Int, _ height: Int) async throws -> UploadedImage)?
    var exportHandler: ((_ profileId: String, _ format: String, _ from: String, _ to: String, _ toEmail: String?) async throws -> ExportResult)?
    var exportBasHandler: ((_ profileId: String, _ from: String, _ to: String, _ paygInstalmentCents: Int, _ toEmail: String?) async throws -> ExportResult)?
    var updateDeviceHandler: ((UpdateDeviceBody) async throws -> UpdateDeviceResponse)?
    var sendQuoteHandler: ((String) async throws -> SendQuoteResponse)?
    var quoteShareLinkHandler: ((String) async throws -> QuoteShareLinkResponse)?
    var uploadProfileLogoHandler: ((String, Data) async throws -> UploadProfileLogoResponse)?
    var issueInvoiceHandler: ((String) async throws -> IssueInvoiceResponse)?
    var sendInvoiceHandler: ((String) async throws -> SendInvoiceResponse)?
    var invoicePdfHandler: ((String) async throws -> InvoicePdfResponse)?
    var profileInboxHandler: ((String) async throws -> InboxAddressResponse)?
    var rotateProfileInboxHandler: ((String) async throws -> InboxAddressResponse)?

    // MARK: Account scripting

    var requestEmailChangeHandler: (() async throws -> EmailChangeRequested)?
    var verifyEmailChangeHandler: ((String) async throws -> AccountUser)?
    private(set) var requestEmailChangeCalls: [String] = []
    private(set) var verifyEmailChangeCalls: [String] = []
    private(set) var revokeDeviceCalls: [String] = []
    private(set) var deleteAccountCallCount = 0

    private(set) var extractCalls: [(ocrText: String, source: String, capturedAt: String?)] = []
    private(set) var uploadCalls: [(transactionId: String?, width: Int, height: Int, byteCount: Int)] = []
    private(set) var exportCalls: [(profileId: String, format: String, from: String, to: String, toEmail: String?)] = []
    private(set) var exportBasCalls: [(profileId: String, from: String, to: String, paygInstalmentCents: Int, toEmail: String?)] = []
    private(set) var updateDeviceCalls: [UpdateDeviceBody] = []
    private(set) var sendQuoteCalls: [String] = []
    private(set) var quoteShareLinkCalls: [String] = []
    private(set) var uploadProfileLogoCalls: [(profileId: String, bytes: Int)] = []
    private(set) var issueInvoiceCalls: [String] = []
    private(set) var sendInvoiceCalls: [String] = []
    private(set) var invoicePdfCalls: [String] = []
    private(set) var profileInboxCalls: [String] = []
    private(set) var rotateProfileInboxCalls: [String] = []

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

    func otpRequest(email: String) async throws {
        otpRequestedEmails.append(email)
        guard let h = otpRequestHandler else { throw MockAPIClientError.unscripted }
        try await h(email)
    }

    func otpVerify(email: String, code: String) async throws -> SessionResponse {
        otpVerifiedCodes.append((email, code))
        guard let h = otpVerifyHandler else { throw MockAPIClientError.unscripted }
        return try await h(email, code)
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

    var mePlanHandler: (() async throws -> String)?
    func mePlan() async throws -> String {
        if let h = mePlanHandler { return try await h() }
        return "free"
    }
    func recordPurchase(signedTransaction: String) async throws {}
    func reportDiagnostic(_ body: DiagnosticReportBody) async throws {}

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        pushCalls.append(mutations)
        guard let h = pushHandler else { return PushResponse(results: [], serverTime: 0) }
        return try h(mutations)
    }

    /// Optional scripted pull (e.g. throw a transient error then succeed). When nil the
    /// `pullPages` queue is used, preserving existing tests.
    var pullHandler: ((_ cursor: String?, _ limit: Int) throws -> PullResponse)?

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        pullCursors.append(cursor)
        if let h = pullHandler { return try h(cursor, limit) }
        guard !pullPages.isEmpty else {
            return PullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false, serverTime: 0)
        }
        return pullPages.removeFirst()
    }

    func extract(ocrText: String, layoutText: String?, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        extractCalls.append((ocrText, source, capturedAt))
        guard let h = extractHandler else { throw MockAPIClientError.unscripted }
        return try await h(ocrText, source, capturedAt)
    }

    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        uploadCalls.append((transactionId, width, height, jpeg.count))
        guard let h = uploadImageHandler else { throw MockAPIClientError.unscripted }
        return try await h(jpeg, transactionId, width, height)
    }

    var fetchReceiptImageHandler: ((_ transactionId: String) async throws -> Data?)?
    func fetchReceiptImage(transactionId: String) async throws -> Data? {
        guard let h = fetchReceiptImageHandler else { return nil }
        return try await h(transactionId)
    }

    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult {
        exportCalls.append((profileId, format, from, to, toEmail))
        guard let h = exportHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, format, from, to, toEmail)
    }

    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        exportBasCalls.append((profileId, from, to, paygInstalmentCents, toEmail))
        guard let h = exportBasHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, from, to, paygInstalmentCents, toEmail)
    }

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        updateDeviceCalls.append(body)
        guard let h = updateDeviceHandler else { throw MockAPIClientError.unscripted }
        return try await h(body)
    }
    func testPush() async throws -> TestPushResponse {
        TestPushResponse(deviceCount: 0, detail: "mock")
    }
    func simulateEmailIn(jpeg: Data, profileId: String) async throws -> SimulateInboundResponse {
        SimulateInboundResponse(transactionId: "mock-txn", extraction: "done", merchant: "Mock", deviceCount: 0)
    }

    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        sendQuoteCalls.append(id)
        guard let h = sendQuoteHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }

    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        quoteShareLinkCalls.append(id)
        guard let h = quoteShareLinkHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }

    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        uploadProfileLogoCalls.append((profileId, png.count))
        guard let h = uploadProfileLogoHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId, png)
    }

    func issueInvoice(_ id: String) async throws -> IssueInvoiceResponse {
        issueInvoiceCalls.append(id)
        guard let h = issueInvoiceHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }
    func sendInvoice(_ id: String) async throws -> SendInvoiceResponse {
        sendInvoiceCalls.append(id)
        guard let h = sendInvoiceHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }
    func invoicePdf(_ id: String) async throws -> InvoicePdfResponse {
        invoicePdfCalls.append(id)
        guard let h = invoicePdfHandler else { throw MockAPIClientError.unscripted }
        return try await h(id)
    }

    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        profileInboxCalls.append(profileId)
        guard let h = profileInboxHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId)
    }
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        rotateProfileInboxCalls.append(profileId)
        guard let h = rotateProfileInboxHandler else { throw MockAPIClientError.unscripted }
        return try await h(profileId)
    }

    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        requestEmailChangeCalls.append(newEmail)
        guard let h = requestEmailChangeHandler else { throw MockAPIClientError.unscripted }
        return try await h()
    }
    func verifyEmailChange(code: String) async throws -> AccountUser {
        verifyEmailChangeCalls.append(code)
        guard let h = verifyEmailChangeHandler else { throw MockAPIClientError.unscripted }
        return try await h(code)
    }
    func revokeDevice(id: String) async throws { revokeDeviceCalls.append(id) }
    func deleteAccount() async throws { deleteAccountCallCount += 1 }
}

/// Thrown when a scriptable mock method is called without a handler set.
enum MockAPIClientError: Error { case unscripted }
