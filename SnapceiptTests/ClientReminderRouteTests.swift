import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor struct ClientReminderRouteTests {
    @MainActor final class Session { var user: String? = "u" }
    func fixture() throws -> (ModelContext, ProfilesStore, Router, Session, ClientReminderRoute, ClientReminderRouteCoordinator) {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        for id in ["p", "other"] { context.insert(Profile(id: id, userId: "u", name: id, type: "business", accent1: "a", accent2: "b", accent3: "c")) }
        let c = Client(userId: "u", profileId: "other", name: "Private")
        let f = ClientFollowUp(userId: "u", profileId: "other", clientId: c.id, title: "Private", dueAt: 1, timezone: "Australia/Sydney")
        context.insert(c); context.insert(f); try context.save()
        let profiles = ProfilesStore(context: context, sync: MockSyncEngine(), userId: "u")
        profiles.setActive("p")
        let router = Router(), session = Session()
        let route = ClientReminderRoute(userId: "u", profileId: "other", clientId: c.id, followUpId: f.id)
        let coordinator = ClientReminderRouteCoordinator(context: context, profiles: profiles, router: router, currentUser: { session.user })
        return (context, profiles, router, session, route, coordinator)
    }
    @Test func validOtherProfileSwitchAndSameProfileTap() async throws {
        let (_, profiles, router, _, route, coordinator) = try fixture()
        coordinator.receive(route); await coordinator.resumeAfterSessionRestoration()
        #expect(profiles.activeProfileId == "other")
        #expect(router.overlay == .clients(clientId: route.clientId))
        router.dismissOverlay()
        coordinator.receive(route); await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == .clients(clientId: route.clientId))
    }
    @Test func coldLaunchSameUserAndDifferentUser() async throws {
        let (_, _, router, session, route, coordinator) = try fixture()
        session.user = nil; coordinator.receive(route)
        await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == nil)
        session.user = "u"; coordinator.sessionChanged(to: "u")
        await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == .clients(clientId: route.clientId))
        router.dismissOverlay(); session.user = nil; coordinator.sessionChanged(to: nil); coordinator.receive(route)
        session.user = "foreign"; coordinator.sessionChanged(to: "foreign")
        await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == nil)
    }
    @Test(arguments: ["client", "profile", "followUp", "completed", "personal", "foreign"])
    func staleOrForeignRowsNeverSwitch(_ kind: String) async throws {
        let (context, profiles, router, _, route, coordinator) = try fixture()
        let client = try #require(context.fetch(FetchDescriptor<Client>()).first)
        let followUp = try #require(context.fetch(FetchDescriptor<ClientFollowUp>()).first)
        let profile = try #require(context.fetch(FetchDescriptor<Profile>()).first { $0.id == "other" })
        switch kind {
        case "client": client.deletedAt = 1
        case "profile": profile.deletedAt = 1
        case "followUp": followUp.deletedAt = 1
        case "completed": followUp.completedAt = 1
        case "personal": profile.type = "personal"
        default: client.userId = "foreign"
        }
        try context.save()
        coordinator.receive(route); await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == nil); #expect(profiles.activeProfileId == "p")
    }
    @Test func signOutBeforeAsyncRestoreFinishes() async throws {
        let (context, profiles, router, session, route, _) = try fixture()
        var continuation: CheckedContinuation<Void, Never>?
        let coordinator = ClientReminderRouteCoordinator(context: context, profiles: profiles, router: router, currentUser: { session.user }, restore: { await withCheckedContinuation { continuation = $0 } })
        coordinator.receive(route)
        let task = Task { await coordinator.resumeAfterSessionRestoration() }
        while continuation == nil { await Task.yield() }
        session.user = nil; coordinator.sessionChanged(to: nil)
        continuation?.resume(); await task.value
        #expect(router.overlay == nil); #expect(profiles.activeProfileId == "p")
    }
    @Test func unsavedDeletionOrOwnershipChangeNeverRoutes() async throws {
        let (context, profiles, router, _, route, coordinator) = try fixture()
        context.autosaveEnabled = false
        let client = try #require(context.fetch(FetchDescriptor<Client>()).first)
        client.userId = "foreign"
        coordinator.receive(route); await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == nil); #expect(profiles.activeProfileId == "p")
    }
    @Test func malformedPayloadRejected() {
        #expect(ClientReminderRoute(userInfo: ["type": "client_follow_up", "userId": "u"]) == nil)
        #expect(ClientReminderRoute(userInfo: ["type": "client_follow_up", "userId": "u", "profileId": "p", "clientId": " ", "followUpId": "f"]) == nil)
    }
}
