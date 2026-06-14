import Foundation
import SwiftData
import Testing
@testable import Snapceipt

@MainActor
@Suite(.serialized)
struct BasViewModelTests {
    private func setup(gstRegistered: Bool, confirmedIncome: Bool = false)
        throws -> (BasViewModel, ModelContext, MockAPIClient, BasLocalStore) {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        let ctx = ModelContext(container)
        let api = MockAPIClient()
        let store = BasLocalStore(defaults: UserDefaults(suiteName: "sc.test.basvm.\(UUID().uuidString)")!)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let now = f.date(from: "2026-05-15")!   // Apr–Jun 2026 → Q4 FY2025-26
        func t(_ a: Int, gstFree: Bool = false, capital: Bool = false, incomeConfirmed: Bool = false) {
            ctx.insert(Transaction(userId: "u1", profileId: "p1", catKey: a > 0 ? "income" : "office",
                                   amountCents: a, txnDate: "2026-05-01",
                                   gstFree: gstFree, capital: capital,
                                   gstSource: a > 0 ? (incomeConfirmed ? "manual" : "derived") : "derived"))
        }
        t(1_100_000, incomeConfirmed: confirmedIncome)
        t(-110_000)
        t(-220_000, capital: true)
        t(-33_000, gstFree: true)
        try ctx.save()
        let vm = BasViewModel(context: ctx, api: api, store: store, userId: "u1", profileId: "p1",
                              gstRegistered: gstRegistered, basPeriod: .quarterly, startMonth: 7, now: now)
        return (vm, ctx, api, store)
    }

    @Test("computes the canonical worksheet for a registered profile")
    func registered() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        #expect(vm.result.g1 == 1_100_000)
        #expect(vm.result.oneA == 100_000)
        #expect(vm.result.oneB == 30_000)
        #expect(vm.result.netGstCents == 70_000)
        #expect(vm.periodKey == "2025Q4")
    }

    @Test("non-registered forces 1A = 0")
    func nonRegistered() throws {
        let (vm, _, _, _) = try setup(gstRegistered: false)
        #expect(vm.result.oneA == 0)
    }

    @Test("unconfirmed income keeps the headline Estimated; confirming flips it to firm")
    func confirmIncomeFlipsHeadline() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: false)
        #expect(vm.isHeadlineEstimated == true)
        #expect(vm.incomeToConfirmCount == 1)
        vm.confirmAllIncome()
        #expect(vm.incomeToConfirmCount == 0)
        #expect(vm.isHeadlineEstimated == false)
    }

    @Test("estimated-GST quick-fix to GST-free clears the estimated count")
    func estimatedQuickFix() throws {
        let (vm, _, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        // The three expenses are all gstSource=derived except the gst-free one.
        let before = vm.estimatedGstCount
        #expect(before >= 1)
        let firstEstimated = vm.reconcileItems.first { $0.amountCents < 0 && $0.gstSource == "derived" }!
        vm.fixEstimatedAsGstFree(itemId: firstEstimated.id)
        #expect(vm.estimatedGstCount == before - 1)
    }

    @Test("PAYG round-trips through the local store and feeds the total")
    func payg() throws {
        let (vm, _, _, store) = try setup(gstRegistered: true, confirmedIncome: true)
        vm.setPaygInstalmentCents(25_000)
        #expect(vm.result.totalPayableCents == 95_000)
        #expect(store.paygInstalmentCents(profileId: "p1", periodKey: "2025Q4") == 25_000)
    }

    @Test("mark-as-lodged writes a snapshot; later edit drifts")
    func lodged() throws {
        let (vm, ctx, _, _) = try setup(gstRegistered: true, confirmedIncome: true)
        vm.markAsLodged()
        #expect(vm.lodgedAtMs != nil)
        #expect(vm.hasDrifted == false)
        let income = try ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.amountCents > 0 })).first!
        income.amountCents = 1_200_000
        vm.recompute()
        #expect(vm.hasDrifted == true)
    }

    @Test("export calls exportBas with the window + payg and surfaces the pack")
    func export() async throws {
        let (vm, _, api, _) = try setup(gstRegistered: true, confirmedIncome: true)
        api.exportBasHandler = { _, _, _, payg, _ in
            .basPack(pdfUrl: "/p", csvUrl: "/c", expiresAt: 1, emailed: false,
                     bas: BasEcho(g1: 1_100_000, oneA: 100_000, oneB: 30_000,
                                  netGst: 70_000, payg: payg, totalPayable: 70_000 + payg))
        }
        vm.setPaygInstalmentCents(0)
        await vm.export(toEmail: nil)
        #expect(api.exportBasCalls.count == 1)
        #expect(api.exportBasCalls[0].from == "2026-04-01")
        #expect(api.exportBasCalls[0].to == "2026-06-30")
        #expect(vm.exportPdfUrl == "/p")
    }
}
