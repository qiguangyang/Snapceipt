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
    var magicLinkVerifyHandler: ((String) async throws -> SessionResponse)?
    var refreshHandler: ((String) async throws -> SessionResponse)?
    var signOutHandler: (() async throws -> Void)?
    var meHandler: (() async throws -> MeResponse)?

    // MARK: Sync scripting

    /// Builds the push response for a given batch of mutations.
    var pushHandler: (([PushMutation]) -> PushResponse)?
    /// Pages returned by successive `syncPull` calls; the first is dequeued each call.
    var pullPages: [PullResponse] = []

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
}

/// Thrown when a scriptable mock method is called without a handler set.
enum MockAPIClientError: Error { case unscripted }
