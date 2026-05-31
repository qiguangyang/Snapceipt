import Testing
import Foundation
@testable import Snapceipt

@MainActor
@Suite("Deep-link routing")
struct DeepLinkRoutingTests {
    @Test("parses a budget id from snapceipt://budget/<id>")
    func parses() {
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://budget/b-123")!) == "b-123")
    }

    @Test("non-budget / malformed urls return nil")
    func rejects() {
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://export")!) == nil)
        #expect(Router.parseBudgetDeepLink(URL(string: "https://snapceipt.app/budget/x")!) == nil)
        #expect(Router.parseBudgetDeepLink(URL(string: "snapceipt://budget/")!) == nil)
    }

    @Test("openBudget routes to the editor overlay for that id")
    func openBudget() {
        let r = Router()
        r.openBudget("b-9")
        #expect(r.overlay == .budgetEditor(id: "b-9"))
    }

    @Test("handleBudgetDeepLink opens the editor when the url is a budget link")
    func handleDeepLink() {
        let r = Router()
        let handled = r.handleBudgetDeepLink(URL(string: "snapceipt://budget/b-7")!)
        #expect(handled == true)
        #expect(r.overlay == .budgetEditor(id: "b-7"))
        #expect(r.handleBudgetDeepLink(URL(string: "snapceipt://export")!) == false)
    }
}
