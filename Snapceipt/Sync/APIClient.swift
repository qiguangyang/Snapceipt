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
    func refresh(refreshToken: String) async throws -> SessionResponse
    func signOut() async throws
    func me() async throws -> MeResponse
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse
    func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse
    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage
    /// POST /export — generate a CSV/PDF (share via the returned download url) or
    /// email the accountant pack. Returns the normalized `ExportResult`. (spec §4.2)
    func export(profileId: String, format: String, from: String, to: String,
                toEmail: String?) async throws -> ExportResult
    /// PUT /devices/me — upsert this device's apns token / quiet-hours / timezone /
    /// push_enabled. Keyed by the X-Device-Id header (attached by makeRequest). (§4.2)
    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse
    /// POST /quotes/:id/send — recompute totals, assign SN-#### (if unset), render the
    /// PDF, email the client; returns the applied number/status/sentAt/totals. (§4.5)
    func sendQuote(_ id: String) async throws -> SendQuoteResponse
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
                                body: MagicLinkRequestBody(email: email), authenticated: false)
    }

    func magicLinkRequestDev(email: String) async throws -> String? {
        /// The 202 body only carries `devToken` when the backend runs with E2E_TEST_MODE=1.
        struct DevResp: Decodable { let devToken: String? }
        let data = try await perform("POST", "/auth/magic-link/request", query: [],
                                     body: MagicLinkRequestBody(email: email),
                                     authenticated: false, allowRefresh: false)
        guard !data.isEmpty else { return nil }
        return (try? decoder.decode(DevResp.self, from: data))?.devToken
    }

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        try await send("POST", "/auth/magic-link/verify",
                       body: MagicLinkVerifyBody(token: token), authenticated: false)
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

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        try await send("POST", "/sync/push",
                       body: PushBody(deviceId: deviceId, mutations: mutations), authenticated: true)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "/sync/pull", query: items,
                              body: NoBody(), authenticated: true)
    }

    func extract(ocrText: String, source: String, capturedAt: String?) async throws -> ExtractionResponse {
        #if DEBUG
        // J18c offline seam (test-only): when -uiTestOffline is set the live client also
        // throws a transport error so the capture flow falls back to HeuristicParser +
        // outbox queue against the REAL backend. Compiled out of Release entirely.
        if AppLaunch.current.offline {
            throw APIError(code: "TRANSPORT", message: "offline (uiTest seam)", status: 0)
        }
        #endif
        // iOS hard-codes AUD / en-AU and always sends a client-generated requestId
        // (UUIDv7 from the same `ID` helper the model inits use).
        let body = ExtractBody(ocrText: ocrText, source: source,
                               defaultCurrency: "AUD", locale: "en-AU",
                               capturedAt: capturedAt, requestId: ID.uuidv7())
        return try await send("POST", "/extract", body: body, authenticated: true)
    }

    func uploadImage(jpeg: Data, transactionId: String?, width: Int, height: Int) async throws -> UploadedImage {
        #if DEBUG
        // J18c offline seam (test-only): mirror extract — fail the image upload offline.
        if AppLaunch.current.offline {
            throw APIError(code: "TRANSPORT", message: "offline (uiTest seam)", status: 0)
        }
        #endif
        var items = [URLQueryItem(name: "width", value: String(width)),
                     URLQueryItem(name: "height", value: String(height))]
        if let transactionId { items.append(URLQueryItem(name: "transactionId", value: transactionId)) }
        let data = try await performRawJPEG("/images", query: items, jpeg: jpeg)
        do { return try decoder.decode(UploadedImage.self, from: data) }
        catch { throw APIError.decoding }
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

    func updateDevice(_ body: UpdateDeviceBody) async throws -> UpdateDeviceResponse {
        try await send("PUT", "/devices/me", body: body, authenticated: true)
    }

    func sendQuote(_ id: String) async throws -> SendQuoteResponse {
        try await send("POST", "/quotes/\(id)/send", body: NoBody(), authenticated: true)
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

    // MARK: - Request plumbing

    /// Send a request and decode a JSON body into `T`.
    private func send<T: Decodable, B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: B?,
        authenticated: Bool
    ) async throws -> T {
        let data = try await perform(method, path, query: query, body: body,
                                     authenticated: authenticated, allowRefresh: authenticated)
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
        allowRefresh: Bool
    ) async throws -> Data {
        let request = try makeRequest(method, path, query: query, body: body, authenticated: authenticated)
        let (data, response) = try await dataResponse(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }

        if http.statusCode == 401, allowRefresh, await tryRefresh() {
            // Rebuild with the fresh bearer and retry exactly once.
            let retry = try makeRequest(method, path, query: query, body: body, authenticated: authenticated)
            let (data2, response2) = try await dataResponse(for: retry)
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.transport }
            return try validate(data2, http2)
        }
        return try validate(data, http)
    }

    /// POST a raw `image/jpeg` body (no JSON encoding); refresh-on-401 like `perform`.
    private func performRawJPEG(_ path: String, query: [URLQueryItem], jpeg: Data) async throws -> Data {
        func makeImageRequest() throws -> URLRequest {
            var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                           resolvingAgainstBaseURL: false)
            if !query.isEmpty { components?.queryItems = query }
            guard let url = components?.url else { throw APIError.transport }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
            if let bearer = auth.bearer() {
                request.setValue(bearer, forHTTPHeaderField: "Authorization")
            }
            request.httpBody = jpeg
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
        authenticated: Bool
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.transport }

        var request = URLRequest(url: url)
        request.httpMethod = method
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
