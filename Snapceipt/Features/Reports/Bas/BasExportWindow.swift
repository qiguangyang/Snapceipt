import Foundation

/// Pure resolver for the export date window (spec §4.7). Pinned ⇒ the BAS pack window
/// (`basWindowForActive` — the SAME window that keys the PAYG instalment and drives the
/// on-screen Simpler-BAS spine); otherwise the Reports-selected period's window. Extracted
/// from `RootView.exportWindow` so the pinned-vs-default branch is a unit-testable function
/// (the real regression net for "a quarterly profile must export the whole quarter, not the
/// `.month` default"), rather than an inline ternary only reachable through the SwiftUI shell.
enum BasExportWindow {
    /// - Parameters:
    ///   - pinned: the next `.export` sheet is the BAS-pinned pack (`basExportPinned`).
    ///   - basWindow: the active profile's BAS-period window (quarter for quarterly profiles).
    ///   - defaultPeriod: the Reports-selected period to fall back to when not pinned.
    ///   - now: injected clock (no hidden `Date()`).
    ///   - startMonth: the active profile's financial-year start month.
    static func resolve(pinned: Bool, basWindow: Period.Window,
                        defaultPeriod: Period, now: Date, startMonth: Int) -> Period.Window {
        pinned ? basWindow : defaultPeriod.window(now: now, startMonth: startMonth)
    }
}
