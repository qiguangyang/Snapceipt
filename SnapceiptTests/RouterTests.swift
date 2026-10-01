import Foundation
import Testing
@testable import Snapceipt

@MainActor struct RouterTests {
    @Test func receiptDeepLinkOpensDetail() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://receipt/txn123")!) == true)
        #expect(r.overlay == .receiptDetail(id: "txn123"))
    }
    @Test func nonReceiptDeepLinkIgnored() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://budget/b1")!) == false)
        #expect(r.overlay == nil)
    }
    @Test func openEmailInReceiptSetsOverlay() {
        let r = Router()
        r.openEmailInReceipt("abc")
        #expect(r.overlay == .receiptDetail(id: "abc"))
    }
}

@MainActor struct ClientRouterTests {
    @Test func opensHubOrSelectedClient() {
        let r = Router(); r.openClient(nil)
        #expect(r.overlay == .clients(clientId: nil)); #expect(r.overlay?.id == "clients-all")
        r.openClient("c")
        #expect(r.overlay == .clients(clientId: "c")); #expect(r.overlay?.id == "clients-c")
    }
}
