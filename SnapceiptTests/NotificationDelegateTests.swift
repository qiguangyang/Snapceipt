import Testing
import Foundation
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
        #expect(router.overlay == .emailInReview(id: "txn123"))
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
