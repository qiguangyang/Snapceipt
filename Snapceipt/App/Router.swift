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

    var id: Self { self }
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
}
