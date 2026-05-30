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
}
#endif
