import Foundation
import Testing
@testable import Snapceipt

@MainActor struct RouterTests {
    @Test func receiptDeepLinkOpensReview() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://receipt/txn123")!) == true)
        #expect(r.overlay == .emailInReview(id: "txn123"))
    }
    @Test func nonReceiptDeepLinkIgnored() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://budget/b1")!) == false)
        #expect(r.overlay == nil)
    }
    @Test func openEmailInReceiptSetsOverlay() {
        let r = Router()
        r.openEmailInReceipt("abc")
        #expect(r.overlay == .emailInReview(id: "abc"))
    }
}
