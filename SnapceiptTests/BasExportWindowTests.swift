import Foundation
import Testing
@testable import Snapceipt

/// Regression net for the BAS-pinned export window resolution (spec §4.7). Exercises the
/// EXTRACTED pure function (`BasExportWindow.resolve`) directly — not an inline recompute —
/// so it would FAIL if `RootView.exportWindow`'s pinned-vs-default branch ever regressed
/// back to defaulting a quarterly profile's BAS pack to the `.month` window.
@Suite("BasExportWindow")
struct BasExportWindowTests {
    // FY-Q4 (Apr–Jun 2026) of a quarterly profile, mid-quarter so month ≠ quarter.
    private let now = ExportDateFormatter.shared.date(from: "2026-05-15")!
    private let startMonth = 7

    @Test("pinned ⇒ the BAS (quarter) window, NOT the default-period (.month) window")
    func pinnedReturnsBasQuarterWindow() {
        let quarter = Period.quarter.window(now: now, startMonth: startMonth)
        let month = Period.month.window(now: now, startMonth: startMonth)

        let resolved = BasExportWindow.resolve(
            pinned: true, basWindow: quarter,
            defaultPeriod: .month, now: now, startMonth: startMonth)

        // Pinned ⇒ exactly the passed BAS (quarter) window.
        #expect(resolved == quarter)
        #expect(resolved.start == ExportDateFormatter.shared.date(from: "2026-04-01"))
        #expect(resolved.end == ExportDateFormatter.shared.date(from: "2026-07-01"))
        // And it genuinely DIFFERS from the .month default it must not drift to.
        #expect(resolved != month)
        #expect(resolved.start != month.start)
    }

    @Test("not pinned ⇒ the default-period window (here .month), not the BAS window")
    func defaultReturnsSelectedPeriodWindow() {
        let quarter = Period.quarter.window(now: now, startMonth: startMonth)
        let month = Period.month.window(now: now, startMonth: startMonth)

        let resolved = BasExportWindow.resolve(
            pinned: false, basWindow: quarter,
            defaultPeriod: .month, now: now, startMonth: startMonth)

        #expect(resolved == month)
        #expect(resolved != quarter)
    }
}
