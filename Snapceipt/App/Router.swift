import SwiftUI
import Observation

/// The 5 bottom-bar tabs. `.snap` is the raised center FAB — selecting it never
/// becomes the active tab; it opens Capture (a placeholder until P1).
enum Tab: String, CaseIterable { case home, activity, snap, reports, profile }

/// Modal overlays the shell can present. `profilePicker` + `addProfile` are wired
/// this phase (Tasks 11/13); `capture` is a "coming soon" placeholder (capture is
/// P1). More cases land in later phases.
enum Overlay: Equatable, Identifiable {
    case profilePicker
    case addProfile
    case capture
    case mileage
    case wfh
    case export
    case budgets
    case budgetEditor(id: String?)   // nil id = add a new budget
    case alerts
    case notificationSettings
    case loyalty
    case loyaltyAdd
    case loyaltyCard(id: String)
    case quotes
    case bas
    case quoteEditor(id: String?)   // nil id = create a new quote
    case invoices
    case invoiceEditor(id: String?)   // nil id = create a new invoice
    case emailIn
    case emailInReview(id: String)
    case tax
    case categories
    case ruleEditor(id: String?)   // nil = new rule
    case profileDetail(id: String)
    case receiptDetail(id: String)   // view a saved receipt
    case manual(editId: String?)      // add (nil) or edit an existing transaction manually
    case account
    case privacy
    case changeEmail

    var id: String {
        switch self {
        case .profilePicker: return "profilePicker"
        case .addProfile: return "addProfile"
        case .capture: return "capture"
        case .mileage: return "mileage"
        case .wfh: return "wfh"
        case .export: return "export"
        case .budgets: return "budgets"
        case .budgetEditor(let id): return "budgetEditor-\(id ?? "new")"
        case .alerts: return "alerts"
        case .notificationSettings: return "notificationSettings"
        case .loyalty: return "loyalty"
        case .loyaltyAdd: return "loyaltyAdd"
        case .loyaltyCard(let id): return "loyaltyCard-\(id)"
        case .quotes: return "quotes"
        case .bas: return "bas"
        case .quoteEditor(let id): return "quoteEditor-\(id ?? "new")"
        case .invoices: return "invoices"
        case .invoiceEditor(let id): return "invoiceEditor-\(id ?? "new")"
        case .emailIn: return "emailIn"
        case .emailInReview(let id): return "emailInReview-\(id)"
        case .tax: return "tax"
        case .categories: return "categories"
        case .ruleEditor(let id): return "ruleEditor-\(id ?? "new")"
        case .profileDetail(let id): return "profileDetail-\(id)"
        case .receiptDetail(let id): return "receiptDetail-\(id)"
        case .manual(let editId): return "manual-\(editId ?? "new")"
        case .account: return "account"
        case .privacy: return "privacy"
        case .changeEmail: return "changeEmail"
        }
    }
}

/// Routes the shell understands. Tab routes swap the active tab; overlay routes
/// raise a cover/sheet. `.tab(.snap)` is special-cased to the capture overlay.
enum Route: Equatable {
    case tab(Tab)
    case overlay(Overlay)
}

/// Single source of navigation truth for the authed shell. `@Observable` so SwiftUI
/// re-renders on tab/overlay change.
@Observable final class Router {
    /// Active bottom tab. In-memory only this phase (no localStorage parity needed).
    var tab: Tab = .home
    /// Currently presented overlay, if any.
    var overlay: Overlay? = nil

    /// Navigate. Tab routes switch the active tab (re-keying the screen replays the
    /// enter animation in RootView). Overlay routes raise a cover/sheet. The center
    /// Snap button calls `go(.tab(.snap))` and must NOT change `tab` — it opens Capture.
    func go(_ route: Route) {
        switch route {
        case .tab(let t):
            if t == .snap {
                overlay = .capture
            } else {
                tab = t
            }
        case .overlay(let o):
            overlay = o
        }
    }

    /// Switch the active tab directly (convenience for non-Route callers).
    func go(_ tab: Tab) { go(.tab(tab)) }

    /// Raise an overlay directly (convenience for non-Route callers).
    func present(_ overlay: Overlay) { self.overlay = overlay }

    /// Dismiss any presented overlay.
    func dismissOverlay() { overlay = nil }

    /// Open the budget editor for `id` (nil = add). Used by row taps + tapped pushes.
    func openBudget(_ id: String?) { overlay = .budgetEditor(id: id) }

    /// Open the quote editor for `id` (nil = create a new quote).
    func openQuote(_ id: String?) { overlay = .quoteEditor(id: id) }

    /// Open the invoice editor for `id` (nil = create a new invoice).
    func openInvoice(_ id: String?) { overlay = .invoiceEditor(id: id) }

    /// Parse `snapceipt://budget/<id>` -> the budget id, or nil for any other URL.
    static func parseBudgetDeepLink(_ url: URL) -> String? {
        guard url.scheme == "snapceipt", url.host == "budget" else { return nil }
        let id = url.pathComponents.first(where: { $0 != "/" })
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// If `url` is a budget deep-link, route to its editor and return true.
    @discardableResult
    func handleBudgetDeepLink(_ url: URL) -> Bool {
        guard let id = Router.parseBudgetDeepLink(url) else { return false }
        openBudget(id)
        return true
    }

    /// Open the email-in review editor for transaction `id` (tapped push / receipt deep-link).
    func openEmailInReceipt(_ id: String) { overlay = .emailInReview(id: id) }

    /// Parse `snapceipt://receipt/<id>` -> the transaction id, or nil for any other URL.
    static func parseReceiptDeepLink(_ url: URL) -> String? {
        guard url.scheme == "snapceipt", url.host == "receipt" else { return nil }
        let id = url.pathComponents.first(where: { $0 != "/" })
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// If `url` is a receipt deep-link, open its review editor and return true.
    @discardableResult
    func handleReceiptDeepLink(_ url: URL) -> Bool {
        guard let id = Router.parseReceiptDeepLink(url) else { return false }
        openEmailInReceipt(id)
        return true
    }
}
