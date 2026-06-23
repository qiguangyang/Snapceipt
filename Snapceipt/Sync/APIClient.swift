import Foundation

/// Network boundary the SyncEngine + auth view-models depend on.
/// All methods are async-throwing; non-2xx responses surface as `APIError`.
protocol APIClient {
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse
    func magicLinkRequest(email: String) async throws
    /// Dev-only: POST /auth/magic-link/request and return the `devToken` the backend
    /// includes only when E2E_TEST_MODE=1 (nil otherwise). Used by the dev sign-in button.
    func magicLinkRequestDev(email: String) async throws -> String?
    func magicLinkVerify(token: String) async throws -> SessionResponse
    /// POST /auth/otp/request — request a 6-digit sign-in code (cross-device fallback).
    func otpRequest(email: String) async throws
    /// POST /auth/otp/verify — confirm the 6-digit code and start a session.
    func otpVerify(email: String, code: String) async throws -> SessionResponse
    func refresh(refreshToken: String) async throws -> SessionResponse
    func signOut() async throws
    func me() async throws -> MeResponse
    /// GET /auth/me, decoding only the plan ("free" | "pro").
    func mePlan() async throws -> String
    /// POST /me/subscription — send the StoreKit 2 signed transaction JWS
    /// (`Transaction.jwsRepresentation`). The backend VERIFIES Apple's signature +
    /// cert chain (AppleRootCA-G3), asserts our bundle id + a Pro product id, and
    /// derives originalTransactionId/expiry from the verified payload before
    /// flipping plan to "pro". The App Store Server Notifications webhook (also
    /// verified) provides authoritative lifecycle status thereafter.
    func recordPurchase(signedTransaction: String) async throws
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse
    func extract(ocrText: String, layoutText: String?, source: String, capturedAt: String?) async throws -> ExtractionResponse
    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage
    /// GET /images/by-transaction/<txnId> — fetch the receipt JPEG from R2 by transaction
    /// id (the local copy is reclaimed after upload). Returns nil when none exists (404).
    func fetchReceiptImage(transactionId: String) async throws -> Data?
    /// POST /export — generate a CSV/PDF (share via the returned download url) or
    /// email the accountant pack. Returns the normalized `ExportResult`. (spec §4.2)
    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult
    /// POST /export {format:"bas"} — render the BAS pack (PDF + CSV to R2, optional
    /// accountant email) and return both links + the echoed cents summary. (spec §4.4)
    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult
    /// PUT /devices/me — upsert this device's apns token / quiet-hours / timezone /
    /// push_enabled. Keyed by the X-Device-Id header (attached by makeRequest). (§4.2)
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse
    /// POST /quotes/:id/send — recompute totals, assign SN-#### (if unset), email the
    /// client the hosted HTML quote; returns the link + email status + minted number. (§4.5)
    func sendQuote(_ id: String) async throws -> SendQuoteResponse
    /// POST /quotes/:id/link — mint (or re-mint) the hosted HTML quote link + number. (spec §4)
    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse
    /// POST /profile/logo — upload the profile logo PNG; returns the stored R2 key. (spec §5)
    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse
    /// POST /invoices/:id/issue — mint number, build tax-invoice PDF → R2, set
    /// issued + dates + pdf_r2_key. (spec §4.2)
    func issueInvoice(_ id: String) async throws -> IssueInvoiceResponse
    /// POST /invoices/:id/send — ensure PDF, email client (reuse quote email path). (spec §4.5)
    func sendInvoice(_ id: String) async throws -> SendInvoiceResponse
    /// POST /invoices/:id/pdf — (re)build/return the invoice PDF for share. (spec §6)
    func invoicePdf(_ id: String) async throws -> InvoicePdfResponse
    /// GET /profiles/:id/inbox — the per-profile email-in alias (minted on first read). (§3.1)
    func profileInbox(profileId: String) async throws -> InboxAddressResponse
    /// POST /profiles/:id/inbox/rotate — replace the alias; the old token stops resolving. (§3.1)
    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse
    /// POST /users/me/email — issue a 6-digit code to `newEmail`. (§8.1)
    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested
    /// POST /users/me/email/verify — confirm the code; returns the updated user. (§8.1)
    func verifyEmailChange(code: String) async throws -> AccountUser
    /// DELETE /devices/:id — soft-delete + revoke that device's sessions. (§8.2)
    func revokeDevice(id: String) async throws
    /// DELETE /account — immediate hard purge of the user's data. (§8.3)
    func deleteAccount() async throws
    /// POST /crash-reports — upload one MetricKit diagnostic (crash/hang). Best-effort;
    /// callers ignore failures (diagnostics are not critical-path). (ops)
    func reportDiagnostic(_ body: DiagnosticReportBody) async throws
}

extension APIClient {
    /// Default: no remote receipt image. Live client overrides; stubs/previews/mocks
    /// inherit this (their receipts display from the local file or not at all).
    func fetchReceiptImage(transactionId: String) async throws -> Data? { nil }
}

/// URLSession-backed APIClient. Attaches the bearer + device id, decodes the backend
/// error envelope into `APIError`, and refreshes the access token once on a 401.
final class LiveAPIClient: APIClient {
    private let baseURL: URL
    private let auth: AuthStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// Coalesces concurrent 401-triggered refreshes into a single shared call so two
    /// in-flight requests can't both spend the rotating refresh token (which the
    /// backend's reuse-detection would treat as a stolen token → spurious logout).
    private let refreshCoordinator = RefreshCoordinator()

    init(baseURL: URL, auth: AuthStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: APIClient

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse {
        try await send("POST", "/auth/apple", body: body, authenticated: false)
    }

    func magicLinkRequest(email: String) async throws {
        try await sendNoContent("POST", "/auth/magic-link/request",
                                body: MagicLinkRequestBody(email: email, deviceId: auth.deviceId),
                                authenticated: false)
    }

    func magicLinkRequestDev(email: String) async throws -> String? {
        /// The 202 body only carries `devToken` when the backend runs with E2E_TEST_MODE=1.
        struct DevResp: Decodable { let devToken: String? }
        let data = try await perform("POST", "/auth/magic-link/request", query: [],
                                     body: MagicLinkRequestBody(email: email, deviceId: auth.deviceId),
                                     authenticated: false, allowRefresh: false)
        guard !data.isEmpty else { return nil }
        return (try? decoder.decode(DevResp.self, from: data))?.devToken
    }

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        try await send("POST", "/auth/magic-link/verify",
                       body: MagicLinkVerifyBody(token: token), authenticated: false)
    }

    func otpRequest(email: String) async throws {
        try await sendNoContent("POST", "/auth/otp/request",
                                body: OTPRequestBody(email: email), authenticated: false)
    }

    func otpVerify(email: String, code: String) async throws -> SessionResponse {
        try await send("POST", "/auth/otp/verify",
                       body: OTPVerifyBody(email: email, code: code), authenticated: false)
    }

    func refresh(refreshToken: String) async throws -> SessionResponse {
        try await send("POST", "/auth/refresh",
                       body: RefreshBody(refreshToken: refreshToken), authenticated: false)
    }

    func signOut() async throws {
        try await sendNoContent("POST", "/auth/signout", body: NoBody(), authenticated: true)
    }

    func me() async throws -> MeResponse {
        try await send("GET", "/auth/me", body: NoBody(), authenticated: true)
    }

    func mePlan() async throws -> String {
        let resp: MePlanResponse = try await send("GET", "/auth/me", body: NoBody(), authenticated: true)
        return resp.user.plan
    }

    func recordPurchase(signedTransaction: String) async throws {
        try await sendNoContent("POST", "/me/subscription",
                                body: RecordPurchaseBody(signedTransaction: signedTransaction),
                                authenticated: true)
    }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        #if DEBUG
        // J23c crash-recovery seam (test-only): park the push indefinitely. SyncEngine
        // has already marked the batch `inflight` and saved it to the on-disk store
        // (SyncEngine.swift:104-105), so app.terminate() while this is parked strands a
        // persisted `inflight` outbox row. On the next (clean) launch
        // requeueStrandedInflight() re-marks it `pending` and the push drains it.
        // Compiled out of Release entirely; mirrors the -uiTestOffline seam.
        if AppLaunch.current.pushStall {
            // Park ~1h (well past any terminate the test issues) — long enough that the
            // batch stays `inflight` until app.terminate() strands it.
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        }
        #endif
        let resp: PushResponse = try await send("POST", "/sync/push",
                       body: PushBody(deviceId: deviceId, mutations: mutations), authenticated: true)
        return resp
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "/sync/pull", query: items,
                              body: NoBody(), authenticated: true)
    }

    func extract(ocrText: String, layoutText: String?, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        #if DEBUG
        // J18c offline seam (test-only): when -uiTestOffline is set the live client also
        // throws a transport error so the capture flow falls back to the queued-for-the-
        // cloud path (empty draft + outbox queue) against the REAL backend — on-device AI
        // if available, else queued for the cloud reconciler. Compiled out of Release entirely.
        // Seam scope: only extract/uploadImage are gated — push/pull still reach the live
        // Worker, so the transaction row syncs while just the image + re-extract queue.
        if AppLaunch.current.offline {
            throw APIError.uiTestOffline
        }
        #endif
        // iOS hard-codes AUD / en-AU and always sends a client-generated requestId
        // (UUIDv7 from the same `ID` helper the model inits use).
        let body = ExtractBody(ocrText: ocrText, layoutText: layoutText, source: source,
                               defaultCurrency: "AUD", locale: "en-AU",
                               capturedAt: capturedAt, requestId: ID.uuidv7())
        // 35s cap: long enough to WAIT for the AI inline (the server is bounded to ~30s —
        // 2 attempts × 15s — see deepseek.ts), so the normal scan lands the AI result on
        // Review instead of falling back. The "Review now" button (ScanStep) is the escape
        // hatch for impatience; a genuine transport failure still falls back to the
        // on-device heuristic + a pending receipt the reconciler re-extracts later.
        return try await send("POST", "/extract", body: body, authenticated: true, timeout: 35)
    }

    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        #if DEBUG
        // J18c offline seam (test-only): mirror extract — fail the image upload offline.
        if AppLaunch.current.offline {
            throw APIError.uiTestOffline
        }
        #endif
        var items = [URLQueryItem(name: "width", value: String(width)),
                     URLQueryItem(name: "height", value: String(height))]
        if let transactionId { items.append(URLQueryItem(name: "transactionId", value: transactionId)) }
        let data = try await performRawImage("/images", query: items, bytes: jpeg, contentType: "image/jpeg")
        do { return try decoder.decode(UploadedImage.self, from: data) }
        catch { throw APIError.decoding }
    }

    func fetchReceiptImage(transactionId: String) async throws -> Data? {
        do {
            return try await perform("GET", "/images/by-transaction/\(transactionId)",
                                     query: [], body: NoBody(), authenticated: true, allowRefresh: true)
        } catch let error as APIError where error.status == 404 {
            return nil   // no receipt image linked to this txn
        }
    }

    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult {
        let body = ExportRequestBody(profileId: profileId, format: format,
                                     from: from, to: to, toEmail: toEmail)
        let resp: ExportResponse = try await send("POST", "/export", body: body, authenticated: true)
        if let url = resp.url, let expiresAt = resp.expiresAt {
            return .download(url: url, expiresAt: expiresAt)
        }
        if let status = resp.status, let outboxId = resp.outboxId {
            return .sent(status: status, outboxId: outboxId)
        }
        throw APIError.decoding
    }

    func exportBas(profileId: String, from: String, to: String,
                   paygInstalmentCents: Int, toEmail: String?) async throws -> ExportResult {
        let body = BasExportRequestBody(profileId: profileId, format: "bas", from: from, to: to,
                                        bas: .init(paygInstalmentCents: paygInstalmentCents),
                                        toEmail: toEmail)
        let resp: BasExportResponse = try await send("POST", "/export", body: body, authenticated: true)
        return .basPack(pdfUrl: resp.pdfUrl, csvUrl: resp.csvUrl, expiresAt: resp.expiresAt,
                        emailed: resp.emailed, bas: resp.bas)
    }

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        try await send("PUT", "/devices/me", body: body, authenticated: true)
    }

    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        try await send("POST", "/quotes/\(id)/send", body: NoBody(), authenticated: true)
    }

    func quoteShareLink(_ id: String) async throws -> QuoteShareLinkResponse {
        try await send("POST", "/quotes/\(id)/link", body: NoBody(), authenticated: true)
    }

    func uploadProfileLogo(profileId: String, png: Data) async throws -> UploadProfileLogoResponse {
        // `ImageReducer` emits JPEG bytes (the `png` arg is historically named); send the
        // matching content-type so the backend stores + serves the real type.
        let data = try await performRawImage("/profile/logo",
                                             query: [URLQueryItem(name: "profileId", value: profileId)],
                                             bytes: png, contentType: "image/jpeg")
        do { return try decoder.decode(UploadProfileLogoResponse.self, from: data) }
        catch { throw APIError.decoding }
    }

    func issueInvoice(_ id: String) async throws -> IssueInvoiceResponse {
        try await send("POST", "/invoices/\(id)/issue", body: NoBody(), authenticated: true)
    }

    func sendInvoice(_ id: String) async throws -> SendInvoiceResponse {
        try await send("POST", "/invoices/\(id)/send", body: NoBody(), authenticated: true)
    }

    func invoicePdf(_ id: String) async throws -> InvoicePdfResponse {
        try await send("POST", "/invoices/\(id)/pdf", body: NoBody(), authenticated: true)
    }

    func profileInbox(profileId: String) async throws -> InboxAddressResponse {
        try await send("GET", "/profiles/\(profileId)/inbox", body: NoBody(), authenticated: true)
    }

    func rotateProfileInbox(profileId: String) async throws -> InboxAddressResponse {
        try await send("POST", "/profiles/\(profileId)/inbox/rotate", body: NoBody(), authenticated: true)
    }

    func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested {
        try await send("POST", "/users/me/email", body: EmailChangeBody(newEmail: newEmail), authenticated: true)
    }

    func verifyEmailChange(code: String) async throws -> AccountUser {
        let wrap: AccountUserResponse = try await send("POST", "/users/me/email/verify", body: VerifyCodeBody(code: code), authenticated: true)
        return wrap.user
    }

    func revokeDevice(id: String) async throws {
        try await sendNoContent("DELETE", "/devices/\(id)", body: NoBody(), authenticated: true)
    }

    func deleteAccount() async throws {
        try await sendNoContent("DELETE", "/account", body: NoBody(), authenticated: true)
    }

    func reportDiagnostic(_ body: DiagnosticReportBody) async throws {
        try await sendNoContent("POST", "/crash-reports", body: body, authenticated: true)
    }

    // MARK: - Request plumbing

    /// Send a request and decode a JSON body into `T`.
    private func send<T: Decodable, B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: B?,
        authenticated: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let data = try await perform(method, path, query: query, body: body,
                                     authenticated: authenticated, allowRefresh: authenticated,
                                     timeout: timeout)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// Send a request that has no useful response body (202/200 with empty/ignored body).
    private func sendNoContent<B: Encodable>(
        _ method: String,
        _ path: String,
        body: B?,
        authenticated: Bool
    ) async throws {
        _ = try await perform(method, path, query: [], body: body,
                              authenticated: authenticated, allowRefresh: authenticated)
    }

    /// Build + execute the request; on a 401 (when allowed) refresh once and retry.
    private func perform<B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: B?,
        authenticated: Bool,
        allowRefresh: Bool,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let request = try makeRequest(method, path, query: query, body: body,
                                      authenticated: authenticated, timeout: timeout)
        let (data, response) = try await dataResponse(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }

        if http.statusCode == 401, allowRefresh, await tryRefresh() {
            // Rebuild with the fresh bearer and retry exactly once.
            let retry = try makeRequest(method, path, query: query, body: body,
                                        authenticated: authenticated, timeout: timeout)
            let (data2, response2) = try await dataResponse(for: retry)
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.transport }
            return try validate(data2, http2)
        }
        return try validate(data, http)
    }

    /// POST a raw image body (no JSON encoding) with the given `contentType`; refresh-on-401
    /// like `perform`. Shared by the JPEG receipt upload + the PNG profile-logo upload.
    private func performRawImage(_ path: String, query: [URLQueryItem], bytes: Data,
                                 contentType: String) async throws -> Data {
        func makeImageRequest() throws -> URLRequest {
            var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                           resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw APIError.transport }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
            if let bearer = auth.bearer() {
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = bytes
            return request
        }
        let (data, response) = try await dataResponse(for: try makeImageRequest())
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }
        if http.statusCode == 401, await tryRefresh() {
            let (data2, response2) = try await dataResponse(for: try makeImageRequest())
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.transport }
            return try validate(data2, http2)
        }
        return try validate(data, http)
    }

    /// Map a response to its body (2xx) or throw a decoded `APIError`.
    private func validate(_ data: Data, _ http: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(http.statusCode) { return data }
        if let envelope = try? decoder.decode(ApiErrorEnvelope.self, from: data) {
            throw APIError(code: envelope.error.code,
                           message: envelope.error.message,
                           status: http.statusCode)
        }
        throw APIError(code: "HTTP_\(http.statusCode)",
                       message: "Request failed",
                       status: http.statusCode)
    }

    /// Refresh the access token, coalescing concurrent callers onto one shared refresh
    /// (see `refreshCoordinator`). Returns true if a new session was saved.
    private func tryRefresh() async -> Bool {
        await refreshCoordinator.refresh { [weak self] in
            await self?.performRefresh() ?? false
        }
    }

    /// Do the actual token refresh using the stored refresh token. Returns true if a
    /// new session was saved. Refresh failures (no token / 401) clear the session.
    private func performRefresh() async -> Bool {
        guard let refreshToken = auth.session?.refreshToken else { return false }
        do {
            let req = try makeRequest("POST", "/auth/refresh", query: [],
                                      body: RefreshBody(refreshToken: refreshToken),
                                      authenticated: false)
            let (data, response) = try await dataResponse(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                auth.clear()
                return false
            }
            let session = try decoder.decode(SessionResponse.self, from: data)
            auth.save(session)
            return true
        } catch {
            auth.clear()
            return false
        }
    }

    /// Construct a URLRequest with JSON body + auth/device headers.
    private func makeRequest<B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: B?,
        authenticated: Bool,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.transport }

        var request = URLRequest(url: url)
        request.httpMethod = method
        // Per-request idle timeout (e.g. /extract): if no response arrives within this
        // window the request fails -> transport error -> the caller's heuristic fallback,
        // instead of spinning to URLSession's 60s default. Nil leaves the default.
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
        if authenticated, let bearer = auth.bearer() {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        if let body, !(body is NoBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    /// `URLSession.data(for:)` shim — explicit so tests using a mock URLProtocol work.
    private func dataResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw APIError.transport
        }
    }
}

/// Explicit "no request body" marker. Encodes to nothing; `makeRequest` skips the
/// body + Content-Type when the body is a `NoBody`, so a GET/empty POST never emits
/// a stray JSON `null`.
struct NoBody: Encodable {
    func encode(to encoder: Encoder) throws {}
}

/// POST /extract request body. iOS hard-codes AUD/en-AU and always sends a requestId.
private struct ExtractBody: Encodable {
    let ocrText: String
    let layoutText: String?       // visual-row text for the line-item parser (nil → server uses ocrText)
    let source: String            // "scan" | "email_in"
    let defaultCurrency: String   // "AUD"
    let locale: String            // "en-AU"
    let capturedAt: String?       // "YYYY-MM-DD"
    let requestId: String
}

/// Serializes token refreshes so that N concurrent 401s trigger at most one refresh
/// network call. Callers arriving while a refresh is in flight await the same Task
/// and observe its result, rather than each spending the rotating refresh token.
private actor RefreshCoordinator {
    private var inFlight: Task<Bool, Never>?

    func refresh(_ work: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await work() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

/// POST /crash-reports request body — a MetricKit diagnostic reduced to the
/// server envelope. `payload` is the raw MXDiagnostic dictionary as JSON.
struct DiagnosticReportBody: Encodable {
    let kind: String            // "crash" | "hang"
    let appVersion: String
    let osVersion: String
    let deviceModel: String
    let occurredAt: Int         // epoch ms
    let payload: [String: AnyCodable]
}

/// Minimal type-erased JSON value so an arbitrary MXDiagnostic dictionary encodes.
struct AnyCodable: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}
