import Foundation

/// Network boundary the SyncEngine + auth view-models depend on.
/// All methods are async-throwing; non-2xx responses surface as `APIError`.
protocol APIClient {
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse
    func magicLinkRequest(email: String) async throws
    func magicLinkVerify(token: String) async throws -> SessionResponse
    func refresh(refreshToken: String) async throws -> SessionResponse
    func signOut() async throws
    func me() async throws -> MeResponse
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse
}

/// URLSession-backed APIClient. Attaches the bearer + device id, decodes the backend
/// error envelope into `APIError`, and refreshes the access token once on a 401.
final class LiveAPIClient: APIClient {
    private let baseURL: URL
    private let auth: AuthStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

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

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        try await send("POST", "/auth/magic-link/verify",
                       body: MagicLinkVerifyBody(token: token), authenticated: false)
    }

    func refresh(refreshToken: String) async throws -> SessionResponse {
        try await send("POST", "/auth/refresh",
                       body: RefreshBody(refreshToken: refreshToken), authenticated: false)
    }

    func signOut() async throws {
        try await sendNoContent("POST", "/auth/signout", body: Optional<String>.none, authenticated: true)
    }

    func me() async throws -> MeResponse {
        try await send("GET", "/auth/me", body: Optional<String>.none, authenticated: true)
    }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        try await send("POST", "/sync/push",
                       body: PushBody(deviceId: deviceId, mutations: mutations), authenticated: true)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "/sync/pull", query: items,
                              body: Optional<String>.none, authenticated: true)
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

    /// Refresh the access token using the stored refresh token. Returns true if a new
    /// session was saved. Refresh failures (no token / 401) clear the session.
    private func tryRefresh() async -> Bool {
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
        if let body, !(body is _NoBody) {
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

/// Sentinel for "no body" so `Optional<String>.none` does not serialize a JSON `null`.
private protocol _NoBody {}
extension Optional: _NoBody where Wrapped == String {}
