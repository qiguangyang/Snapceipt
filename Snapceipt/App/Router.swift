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
    case quoteEditor(id: String?)   // nil id = create a new quote

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
        case .quoteEditor(let id): return "quoteEditor-\(id ?? "new")"
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
}
