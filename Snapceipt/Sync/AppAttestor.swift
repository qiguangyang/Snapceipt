import Foundation
import DeviceCheck
import CryptoKit

/// Produces DeviceCheck App Attest headers for the six auth-bootstrap requests so the
/// backend can bind each request to a genuine, un-jailbroken install of this app.
///
/// Fails **OPEN**: `headers(forBody:)` returns `[:]` on the Simulator, on unsupported
/// hardware, or on ANY thrown error. The unattested request still goes through and the
/// server's attest policy decides whether to accept it — attestation hardens, it never
/// blocks the client on its own.
///
/// The attested key is generated once and its `keyId` persisted in the Keychain **only
/// after** the backend verifies the attestation. Keychain presence therefore encodes
/// "already attested" — App Attest keys can be attested exactly once, so a later launch
/// reuses the stored key for per-request assertions instead of re-attesting.
actor AppAttestor {
    private let baseURL: URL
    private let deviceId: String
    private let keychain: Keychain
    private let session: URLSession
    private let service = DCAppAttestService.shared
    /// In-memory cache of the attested keyId (mirrors the Keychain) to skip a Keychain
    /// read per request within a process.
    private var cachedKeyId: String?

    init(baseURL: URL,
         deviceId: String,
         keychain: Keychain = Keychain(),
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceId = deviceId
        self.keychain = keychain
        self.session = session
    }

    /// Attest headers for a request whose encoded body is `body`, or `[:]` when
    /// unsupported / on any failure (fail-open). The client-data hash binds the
    /// assertion to BOTH a fresh server challenge and the exact request body, so a
    /// captured assertion can't be replayed against a different body.
    func headers(forBody body: Data) async -> [String: String] {
        guard service.isSupported else { return [:] }
        do {
            let keyId = try await ensureAttestedKey()
            let challenge = try await fetchChallenge()
            let bodyHash = Data(SHA256.hash(data: body))
            var clientData = Data(challenge.utf8)
            clientData.append(bodyHash)
            let clientDataHash = Data(SHA256.hash(data: clientData))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            return [
                "X-Attest-Key-Id": keyId,
                "X-Attest-Assertion": assertion.base64URLEncodedString(),
                "X-Attest-Challenge": challenge,
                "X-App-Build": Self.appBuild,
            ]
        } catch {
            return [:]
        }
    }

    // MARK: - Key lifecycle

    /// The attested keyId: the in-memory cache, else the persisted (already-attested)
    /// keyId, else generate a new key and attest it end-to-end (challenge → attestKey →
    /// server verify) before persisting. Only persists AFTER the server accepts, so a
    /// stored keyId is always a verified one.
    private func ensureAttestedKey() async throws -> String {
        if let cachedKeyId { return cachedKeyId }
        if let stored = keychain.string(.appAttestKeyId) {
            cachedKeyId = stored
            return stored
        }
        let keyId = try await service.generateKey()
        let challenge = try await fetchChallenge()
        // Attestation binds the key to a fresh server challenge (hashed).
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        try await postVerify(keyId: keyId, attestation: attestation, challenge: challenge)
        keychain.set(keyId, .appAttestKeyId)
        cachedKeyId = keyId
        return keyId
    }

    // MARK: - HTTP (attest challenge / verify)

    private struct ChallengeResponse: Decodable { let challenge: String }

    /// `GET /attest/challenge` → a fresh one-time challenge string.
    private func fetchChallenge() async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("attest/challenge"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, response) = try await session.data(for: request)
        try Self.assert2xx(response)
        return try JSONDecoder().decode(ChallengeResponse.self, from: data).challenge
    }

    /// `POST /attest/verify` — hand the raw attestation object to the backend, which
    /// validates Apple's certificate chain and records the public key for this keyId.
    private func postVerify(keyId: String, attestation: Data, challenge: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("attest/verify"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "keyId": keyId,
            "attestation": attestation.base64URLEncodedString(),
            "challenge": challenge,
        ])
        let (_, response) = try await session.data(for: request)
        try Self.assert2xx(response)
    }

    private static func assert2xx(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    /// `CFBundleVersion` (the build number), sent as `X-App-Build`.
    private static let appBuild: String =
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
}

private extension Data {
    /// Base64URL (RFC 4648 §5): `+`→`-`, `/`→`_`, no `=` padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
