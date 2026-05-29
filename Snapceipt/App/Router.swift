import SwiftUI
import Observation

enum Tab: String, CaseIterable { case home, activity, snap, reports, profile }
enum Overlay: Equatable { case profilePicker, addProfile }   // more cases added in later phases

@Observable final class Router {
    var tab: Tab = .home
    var overlay: Overlay? = nil
    func go(_ tab: Tab) { self.tab = tab }
    func present(_ overlay: Overlay) { self.overlay = overlay }
    func dismissOverlay() { overlay = nil }
}
