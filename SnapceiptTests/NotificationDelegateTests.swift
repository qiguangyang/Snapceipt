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
}
