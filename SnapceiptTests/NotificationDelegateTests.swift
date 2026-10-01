import Testing
import Foundation
import SwiftData
@testable import Snapceipt

actor RefreshSpy { var count = 0; func mark() { count += 1 } }

@MainActor struct NotificationDelegateTests {
    @Test func emailInPushOpensReceiptAndRefreshes() async {
        let router = Router()
        let spy = RefreshSpy()
        await NotificationDelegate.route(
            userInfo: ["type": "email_in", "transactionId": "txn123"],
            router: router, refresh: { await spy.mark() })
        let c = await spy.count
        #expect(c == 1)
        #expect(router.overlay == .receiptDetail(id: "txn123"))
    }

    @Test func emailInPushNoTxnFallsBackToList() async {
        let router = Router()
        await NotificationDelegate.route(userInfo: ["type": "email_in"], router: router, refresh: nil)
        #expect(router.overlay == .emailIn)
    }

    @Test func budgetPushStillRoutes() async {
        let router = Router()
        await NotificationDelegate.route(userInfo: ["budgetId": "b1"], router: router, refresh: nil)
        #expect(router.overlay == .budgetEditor(id: "b1"))
    }

    @Test func apnsEnvironmentIsDevelopmentInDebugBuilds() {
        // The test target compiles in Debug, mirroring the dev build's aps-environment=development.
        #expect(NotificationDelegate.apnsEnvironment == "development")
    }

    @Test func updateDeviceBodyEncodesApnsEnvironmentOnlyWhenSet() throws {
        let withEnv = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(UpdateDeviceBody(apnsToken: "t", apnsEnvironment: "development"))
        ) as? [String: Any]
        #expect(withEnv?["apnsEnvironment"] as? String == "development")

        // A quiet-hours-only update omits the key, so the server COALESCE preserves the stored value.
        let withoutEnv = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(UpdateDeviceBody(quietHoursStartMin: 60))
        ) as? [String: Any]
        #expect(withoutEnv?["apnsEnvironment"] == nil)
    }
}

@MainActor struct ClientNotificationDelegateTests {
    @Test func malformedClientReminderDoesNotFallThroughToBudget() async {
        let r = Router()
        await NotificationDelegate.route(userInfo: ["type": "client_follow_up", "budgetId": "b"], router: r, refresh: nil)
        #expect(r.overlay == nil)
    }
}

@MainActor struct ClientNotificationRoutingIntegrationTests {
    @Test func typedReminderQueuesBeforeBudgetFallbackAndOpensOnlyAfterRestore() async throws {
        let context = ModelContext(try ModelContainer.makeSnapceiptContainer(inMemory: true))
        let profile = Profile(id: "p", userId: "u", name: "Work", type: "business", accent1: "a", accent2: "b", accent3: "c")
        let client = Client(userId: "u", profileId: "p", name: "Private")
        let followUp = ClientFollowUp(userId: "u", profileId: "p", clientId: client.id, title: "Private", dueAt: 1, timezone: "UTC")
        context.insert(profile); context.insert(client); context.insert(followUp); try context.save()
        let profiles = ProfilesStore(context: context, sync: MockSyncEngine(), userId: "u")
        let router = Router()
        let coordinator = ClientReminderRouteCoordinator(context: context, profiles: profiles, router: router, currentUser: { "u" })
        await NotificationDelegate.route(userInfo: ["type": "client_follow_up", "userId": "u", "profileId": "p", "clientId": client.id, "followUpId": followUp.id, "budgetId": "b"], router: router, refresh: nil, clientReminders: coordinator)
        #expect(router.overlay == nil)
        #expect(coordinator.pendingRoute?.clientId == client.id)
        await coordinator.resumeAfterSessionRestoration()
        #expect(router.overlay == .clients(clientId: client.id))
    }
}
