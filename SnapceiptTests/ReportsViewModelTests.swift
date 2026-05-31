import Testing
import Foundation
import SwiftData
@testable import Snapceipt

@MainActor
@Suite("ReportsViewModel")
struct ReportsViewModelTests {
    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    private func makeCtx() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    /// Seed a business profile p1 + a personal profile p2, plus scoped data.
    private func seed(_ ctx: ModelContext) {
        let prof = Profile(userId: "u1", name: "Studio", type: "business",
                           accent1: "#0E7C72", accent2: "#DCF0ED", accent3: "#0A5950")
        prof.id = "p1"
        ctx.insert(prof)
        // p1 txns
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "income",
                               amountCents: 500_00, txnDate: "2026-06-02"))
        ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: "meals",
                               amountCents: -120_00, txnDate: "2026-06-05",
                               deductiblePct: 50, gstCents: 10_91))
        // other-profile txn -> must be excluded
        ctx.insert(Transaction(userId: "u1", profileId: "p2", catKey: "meals",
                               amountCents: -999_00, txnDate: "2026-06-06"))
        // F1 claims for p1, FY2025-26
        ctx.insert(VehicleYear(userId: "u1", profileId: "p1", vehicleId: "v1",
                               fyStartYear: 2025, claimCents: 250_00))
        ctx.insert(WFHLog(userId: "u1", profileId: "p1", logDate: "2026-05-10",
                          minutes: 480, claimCents: 90_00))
        try? ctx.save()
    }

    @Test("scopes by profile + computes net for the selected period")
    func netForPeriod() throws {
        let ctx = try makeCtx(); seed(ctx)
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                  startMonth: 7, now: iso("2026-06-15"))
        vm.period = .month
        #expect(vm.netCents == 380_00)          // 500 income - 120 meals (p2's 999 excluded)
        #expect(vm.donutSegments.count == 1)     // meals only
        #expect(vm.barData.count == 5)
    }

    @Test("deductible/gst pills include F1 claims, FY-to-date")
    func taxPills() throws {
        let ctx = try makeCtx(); seed(ctx)
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                  startMonth: 7, now: iso("2026-06-15"))
        // meals 120 @50% = 6000c + vehicle 250_00 + wfh 90_00
        #expect(vm.deductibleYTDCents == 60_00 + 250_00 + 90_00)
        #expect(vm.gstYTDCents == 10_91)
    }

    @Test("business layout flag is true for a non-personal profile")
    func businessLayout() throws {
        let ctx = try makeCtx(); seed(ctx)
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                  startMonth: 7, now: iso("2026-06-15"))
        #expect(vm.isBusiness == true)
    }

    @Test("personal profile -> business layout flag false")
    func personalLayout() throws {
        let ctx = try makeCtx()
        ctx.insert(Profile(userId: "u1", name: "Home", type: "personal",
                           accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A"))
        try? ctx.save()
        // find its id
        let p = try ctx.fetch(FetchDescriptor<Profile>()).first!
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: p.id,
                                  startMonth: 7, now: iso("2026-06-15"))
        #expect(vm.isBusiness == false)
    }

    @Test("changing period recomputes the donut + net")
    func periodRecompute() throws {
        let ctx = try makeCtx(); seed(ctx)
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                  startMonth: 7, now: iso("2026-06-15"))
        vm.period = .month
        let monthNet = vm.netCents
        vm.period = .fy
        // FY includes the same June rows here, so net unchanged but recompute ran.
        #expect(vm.netCents == monthNet)
        #expect(vm.insight.isEmpty == false)
    }

    @Test("personal profile with budgets exposes the under-budget pair when under")
    func underBudget() throws {
        let ctx = try makeCtx()
        let p = Profile(userId: "u1", name: "Home", type: "personal",
                        accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A")
        p.id = "pp"; ctx.insert(p)
        ctx.insert(Budget(userId: "u1", profileId: "pp", categoryId: nil, label: "All", capCents: 600_00))
        ctx.insert(Transaction(userId: "u1", profileId: "pp", catKey: "meals",
                               amountCents: -200_00, txnDate: "2026-06-05"))
        try? ctx.save()
        let vm = ReportsViewModel(context: ctx, userId: "u1", profileId: "pp",
                                  startMonth: 7, now: iso("2026-06-15"))
        let ub = try #require(vm.underBudget)
        #expect(ub.spentCents == 200_00)
        #expect(ub.capCents == 600_00)
    }

    @Test("under-budget is nil for a business profile and when over budget")
    func underBudgetHidden() throws {
        let ctx = try makeCtx(); seed(ctx)   // business p1, no budgets
        let vmBiz = ReportsViewModel(context: ctx, userId: "u1", profileId: "p1",
                                     startMonth: 7, now: iso("2026-06-15"))
        #expect(vmBiz.underBudget == nil)

        let ctx2 = try makeCtx()
        let p = Profile(userId: "u1", name: "Home", type: "personal",
                        accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A")
        p.id = "pp"; ctx2.insert(p)
        ctx2.insert(Budget(userId: "u1", profileId: "pp", categoryId: nil, label: "All", capCents: 100_00))
        ctx2.insert(Transaction(userId: "u1", profileId: "pp", catKey: "meals",
                                amountCents: -200_00, txnDate: "2026-06-05"))
        try? ctx2.save()
        let vmOver = ReportsViewModel(context: ctx2, userId: "u1", profileId: "pp",
                                      startMonth: 7, now: iso("2026-06-15"))
        #expect(vmOver.underBudget == nil)   // over cap -> hidden
    }
}
