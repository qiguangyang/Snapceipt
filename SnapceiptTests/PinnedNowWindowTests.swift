import XCTest
import SwiftData
@testable import Snapceipt

/// Proves the view-layer "now" seams honor the Epoch pin: a ReportsViewModel
/// built with no `now:` argument (default = Epoch.now()) computes its Month
/// window around the PINNED instant, so a transaction in the pinned month is
/// counted — exactly what the tour relies on. `period` defaults to `.month`
/// and `load()` is called in init, so no extra call is needed.
final class PinnedNowWindowTests: XCTestCase {
    override func tearDown() { Epoch.override = nil; super.tearDown() }

    @MainActor func test_reportsMonthWindow_followsEpochPin() throws {
        Epoch.override = 1_768_478_400_000   // 15 Jan 2026 12:00 UTC (the tour pin)
        let container = try ModelContainer(
            for: Transaction.self, Profile.self, VehicleYear.self, WFHLog.self, Budget.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        ctx.insert(Profile(id: "p1", userId: "u1", name: "Biz", type: "business",
                           initials: "B", accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950",
                           sortOrder: 0, isDefault: true))
        // A spend dated to the pinned month (10 Jan 2026), scoped to profile "p1".
        ctx.insert(Transaction(userId: "u1", profileId: "p1", merchant: "Cafe",
                               catKey: "meals", amountCents: -50_00, txnDate: "2026-01-10"))
        try ctx.save()
        // No `now:` argument — exercises the default = Epoch.now(); init calls load().
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1", startMonth: 7)
        // The default .month period centered on the pin must include the 10 Jan txn.
        XCTAssertEqual(vm.expenseCents, 50_00,
            "Reports Month window must follow the Epoch pin, not the wall clock")
    }
}
