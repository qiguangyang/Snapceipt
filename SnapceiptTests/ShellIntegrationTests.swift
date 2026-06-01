import Testing
import Foundation
import SwiftData
@testable import Snapceipt

/// End-to-end shell integration: wires the real `AuthStore` + `ProfilesStore` +
/// `SyncEngine` against an in-memory SwiftData stack and the shared `MockAPIClient`,
/// simulates a signed-in user with one profile, pushes a local profile upsert (the
/// mock applies it) then pulls a NEW server-authored profile, and asserts the store
/// reflects BOTH. Also exercises `Router` tab/overlay transitions and `ToastCenter`.
@MainActor
@Suite(.serialized)
struct ShellIntegrationTests {

    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    private func signedInAuth() -> AuthStore {
        let auth = AuthStore(keychain: Keychain(service: "app.snapceipt.tests." + UUID().uuidString))
        auth.save(SessionResponse(
            accessToken: "a", refreshToken: "r", expiresIn: 900,
            user: SessionUser(id: "u1", email: "u@x.com", displayName: "U")
        ))
        return auth
    }

    /// Build a server entity envelope (`PullChange`) by decoding a JSON object through
    /// `PullChange`'s real `Decodable` path (it has a custom `init(from:)`).
    private func envelope(
        type: String, id: String, userId: String = "u1",
        rev: Int, updatedAt: Int, extra: [String: Any] = [:]
    ) -> PullChange {
        var fields: [String: Any] = [
            "type": type, "id": id, "userId": userId, "rev": rev,
            "createdAt": updatedAt, "updatedAt": updatedAt,
            "deletedAt": NSNull(), "lastEditedDeviceId": NSNull(),
        ]
        for (k, v) in extra { fields[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(PullChange.self, from: data)
    }

    // MARK: - Push → Pull round-trip

    @Test("push then pull: the store reflects the local upsert and the server-pulled profile")
    func pushThenPull() async throws {
        let context = try makeContext()
        let api = MockAPIClient()
        let auth = signedInAuth()
        let toast = ToastCenter()
        let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
        let store = ProfilesStore(context: context, sync: engine, userId: "u1")
        UserDefaults.standard.removeObject(forKey: "sc.syncCursor")

        // Simulate a signed-in user with one local profile. `add` inserts, enqueues an
        // upsert through the engine, and activates it.
        let local = Profile(
            userId: "u1", name: "Personal", type: "personal",
            accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A"
        )
        store.add(local)
        #expect(store.activeProfileId == local.id)

        // A pending outbox row exists for the upsert before push.
        let pendingBefore = try context.fetch(
            FetchDescriptor<OutboxMutation>(predicate: #Predicate { $0.status == "pending" })
        )
        #expect(pendingBefore.contains { $0.entityId == local.id })

        // The mock applies every pushed mutation (echoes it back with a bumped rev).
        api.pushHandler = { muts in
            let results = muts.map { m in
                PushResult(
                    mutationId: m.mutationId, status: "applied", reason: nil,
                    entity: self.envelope(type: m.entityType, id: m.entityId,
                                          rev: (m.baseRev ?? 0) + 1, updatedAt: 9_000)
                )
            }
            return PushResponse(results: results, serverTime: 9_000)
        }

        await engine.push()

        // The mock received the mutation and the outbox drained to non-pending.
        #expect(api.pushCalls.flatMap { $0 }.contains { $0.entityId == local.id })
        let pendingAfterPush = try context.fetch(
            FetchDescriptor<OutboxMutation>(predicate: #Predicate { $0.status == "pending" })
        )
        #expect(pendingAfterPush.isEmpty)

        // Pull a NEW server-authored "Business" profile.
        let serverProfileId = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [
                    envelope(type: "profile", id: serverProfileId, rev: 1, updatedAt: 10_000,
                             extra: [
                                "name": "Business",
                                "profileType": "business",
                                "accent1": "#0E7C72", "accent2": "#DCF0ED", "accent3": "#0A5950",
                             ])
                ],
                nextCursor: "c1", hasMore: false, serverTime: 10_000
            )
        ]
        await engine.pull()
        store.reload()

        // Both profiles present: the local "Personal" (acked) and the pulled "Business".
        #expect(store.profiles.contains { $0.id == local.id })
        #expect(store.profiles.contains { $0.id == serverProfileId })
        #expect(store.profiles.contains { $0.name == "Business" })
        #expect(store.profiles.count == 2)

        // The acked local row carries the server-bumped rev.
        let localRow = try context.fetch(
            FetchDescriptor<Profile>(predicate: #Predicate { $0.name == "Personal" })
        ).first
        #expect(localRow?.rev == 1)
    }

    // MARK: - Router navigation

    @Test("Router.go switches tab and raises/dismisses overlays; Snap never becomes the active tab")
    func routerNavigation() {
        let router = Router()
        #expect(router.tab == .home)
        #expect(router.overlay == nil)

        router.go(.tab(.reports))
        #expect(router.tab == .reports)

        // Snap routes to the capture overlay and must NOT change the active tab.
        router.go(.tab(.snap))
        #expect(router.tab == .reports)
        #expect(router.overlay == .capture)

        router.dismissOverlay()
        #expect(router.overlay == nil)

        router.go(.overlay(.profilePicker))
        #expect(router.overlay == .profilePicker)

        // The profile picker can hand off to add-profile without leaving the overlay stack.
        router.go(.overlay(.addProfile))
        #expect(router.overlay == .addProfile)

        router.dismissOverlay()
        #expect(router.overlay == nil)
    }

    // MARK: - ToastCenter

    @Test("ToastCenter.show publishes the current toast; clear removes it")
    func toastCenter() {
        let center = ToastCenter()
        #expect(center.current == nil)
        center.show("Updated on another device", kind: .info)
        #expect(center.current?.message == "Updated on another device")
        #expect(center.current?.kind == .info)
        center.clear()
        #expect(center.current == nil)
    }
}
