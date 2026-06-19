import Foundation
import SwiftData

/// Drives `BasView` (spec §4.6/§4.7). Fetches in-window non-deleted txns for the
/// active profile, runs `BasEngine`, derives reconciliation, persists PAYG + the
/// Mark-as-lodged snapshot via `BasLocalStore`, and calls `exportBas`. It also owns
/// the per-txn quick-fix mutations (confirm income, mark gst-free, type manual GST),
/// all routed through `GstTreatment` and re-running `recompute()`. `now` is injected
/// (no hidden Date()).
@Observable
@MainActor
final class BasViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let store: BasLocalStore
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let profileId: String
    @ObservationIgnored private let gstRegistered: Bool
    @ObservationIgnored private let basPeriod: BasPeriod
    @ObservationIgnored private let startMonth: Int
    @ObservationIgnored private var now: Date

    private(set) var window: Period.Window
    private(set) var periodKey: String
    private(set) var periodOffset: Int = 0
    private(set) var earliestOffset: Int = 0
    private(set) var result: BasEngine.Result
    private(set) var reconcileItems: [BasReconciliation.Item]
    private(set) var lodgedAtMs: Int?
    private(set) var exportInProgress = false
    private(set) var exportError: String?
    private(set) var exportPdfUrl: String?
    private(set) var exportCsvUrl: String?
    private(set) var exportEmailed = false

    private(set) var paygInstalmentCents: Int

    init(context: ModelContext, api: APIClient, store: BasLocalStore, userId: String,
         profileId: String, gstRegistered: Bool, basPeriod: BasPeriod, startMonth: Int, now: Date) {
        self.context = context; self.api = api; self.store = store
        self.userId = userId; self.profileId = profileId; self.gstRegistered = gstRegistered
        self.basPeriod = basPeriod; self.startMonth = startMonth; self.now = now
        let p: Period = (basPeriod == .quarterly) ? .quarter : .month
        let w = p.window(now: now, startMonth: startMonth)
        self.window = w
        self.periodKey = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
        self.paygInstalmentCents = 0
        self.result = BasEngine.compute(txns: [], gstRegistered: gstRegistered, manual: BasEngine.Manual())
        self.reconcileItems = []
        self.lodgedAtMs = nil
        self.paygInstalmentCents = store.paygInstalmentCents(profileId: profileId, periodKey: periodKey)
        self.lodgedAtMs = store.lodgedSnapshot(profileId: profileId, periodKey: periodKey)?.lodgedAtMs
        self.earliestOffset = BasHistory.earliestOffset(
            txns: Self.engineTxns(context: context, profileId: profileId),
            lodged: { store.lodgedSnapshot(profileId: profileId, periodKey: $0) },
            basPeriod: basPeriod, startMonth: startMonth, now: now)
        recompute()
    }

    /// "yyyy-MM-dd" UTC for the inclusive window end (end is exclusive → minus one day).
    var fromISO: String { ExportDateFormatter.shared.string(from: window.start) }
    var toISO: String { ExportDateFormatter.shared.string(from: window.end.addingTimeInterval(-86_400)) }

    var isHeadlineEstimated: Bool { BasReconciliation.isHeadlineEstimated(reconcileItems) }
    var estimatedGstCount: Int { BasReconciliation.estimatedGstCount(reconcileItems) }
    var incomeToConfirmCount: Int { BasReconciliation.incomeToConfirmCount(reconcileItems) }
    var printedDiscrepancyCount: Int { BasReconciliation.printedDiscrepancyCount(reconcileItems) }

    var hasDrifted: Bool {
        store.hasDrifted(current: currentSnapshot(), profileId: profileId, periodKey: periodKey)
    }

    /// In-window non-deleted txns for the active profile.
    private func windowTxns() -> [Transaction] {
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        let iso = ExportDateFormatter.shared
        return rows.filter {
            iso.date(from: $0.txnDate).map { $0 >= window.start && $0 < window.end } ?? false
        }
    }

    func recompute() {
        let inWindow = windowTxns()
        let engineTxns = inWindow.map {
            BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                          capital: $0.capital, txnDate: $0.txnDate)
        }
        result = BasEngine.compute(txns: engineTxns, gstRegistered: gstRegistered,
                                   manual: BasEngine.Manual(paygInstalmentCents: paygInstalmentCents))
        reconcileItems = inWindow.map {
            // Income is "confirmed" once the user has reviewed it — signalled by a
            // user-touched provenance (gstSource == "manual", written by
            // GstTreatment.confirmIncome) OR an explicit gst-free flag. Derived income
            // (the capture default) is unconfirmed until the user taps Confirm.
            BasReconciliation.Item(id: $0.id, amountCents: $0.amountCents, gstFree: $0.gstFree,
                                   gstSource: $0.gstSource, gstCents: $0.gstCents,
                                   incomeConfirmed: $0.gstFree || $0.gstSource == "manual")
        }
    }

    // MARK: - Period navigation (the history cursor)

    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private var monthsPerPeriod: Int { basPeriod == .quarterly ? 3 : 1 }

    /// The selected period's lodge due date (not the global next-due).
    var periodDueDate: Date { BasSchedule.dueDate(for: window, period: basPeriod) }

    var canGoForward: Bool { periodOffset < 0 }      // 0 = current; never the future
    var canGoBack: Bool { periodOffset > earliestOffset }

    /// True when the selected period's lodge deadline has already passed (drives the soft
    /// "Not marked as lodged" line). `periodDueDate` reads the observed `window`, so the
    /// header re-renders on navigation; pairing it with the observed `lodgedAtMs` in the
    /// view avoids a stale status. (The history list classifies via `BasHistory.status`.)
    var isPastDue: Bool { now > periodDueDate }

    func goToPrevious() { guard canGoBack else { return }; moveTo(periodOffset - 1) }
    func goToNext() { guard canGoForward else { return }; moveTo(periodOffset + 1) }
    func select(offset: Int) { moveTo(min(0, max(earliestOffset, offset))) }

    private func moveTo(_ offset: Int) {
        periodOffset = offset
        let anchor = Self.utcCal.date(byAdding: .month, value: offset * monthsPerPeriod, to: now)!
        let p: Period = basPeriod == .quarterly ? .quarter : .month
        window = p.window(now: anchor, startMonth: startMonth)
        periodKey = BasPeriodKey.make(window: window, basPeriod: basPeriod, startMonth: startMonth)
        paygInstalmentCents = store.paygInstalmentCents(profileId: profileId, periodKey: periodKey)
        lodgedAtMs = store.lodgedSnapshot(profileId: profileId, periodKey: periodKey)?.lodgedAtMs
        recompute()
    }

    /// All non-deleted txns for the profile, mapped to engine txns (history + bounds span
    /// every period, not just the current window).
    private static func engineTxns(context: ModelContext, profileId: String) -> [BasEngine.Txn] {
        let pid = profileId
        let rows = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil }))) ?? []
        return rows.map { BasEngine.Txn(amountCents: $0.amountCents, gstFree: $0.gstFree,
                                        capital: $0.capital, txnDate: $0.txnDate) }
    }

    func history() -> [BasHistory.Row] {
        BasHistory.build(txns: Self.engineTxns(context: context, profileId: profileId),
                         lodged: { store.lodgedSnapshot(profileId: profileId, periodKey: $0) },
                         gstRegistered: gstRegistered, basPeriod: basPeriod,
                         startMonth: startMonth, now: now)
    }

    // MARK: - Reconciliation quick-fixes (mutate the txn, then recompute)

    private func txn(_ id: String) -> Transaction? {
        windowTxns().first { $0.id == id }
    }

    private func persist(_ row: Transaction) {
        row.updatedAt = Epoch.nowMs()
        try? context.save()
        recompute()
    }

    /// Confirm a single income row as reviewed (stamps provenance manual).
    func confirmIncome(itemId: String) {
        guard let row = txn(itemId), row.amountCents > 0 else { return }
        let r = GstTreatment.confirmIncome()
        row.gstSource = r.gstSource
        persist(row)
    }

    /// Confirm ALL unreviewed income in the window in one tap (the strip's quick-fix).
    func confirmAllIncome() {
        var changed = false
        for row in windowTxns() where row.amountCents > 0 && !(row.gstFree || row.gstSource == "manual") {
            row.gstSource = GstTreatment.confirmIncome().gstSource
            row.updatedAt = Epoch.nowMs()
            changed = true
        }
        if changed { try? context.save() }
        recompute()
    }

    /// Quick-fix an estimated expense as GST-free (zeroes GST, clears provenance).
    func fixEstimatedAsGstFree(itemId: String) {
        guard let row = txn(itemId), row.amountCents < 0 else { return }
        row.gstFree = true
        let r = GstTreatment.applyGstFree(true, totalCents: -row.amountCents)
        row.gstCents = r.gstCents; row.gstSource = r.gstSource
        persist(row)
    }

    /// Quick-fix an expense with an exact typed GST amount (manual provenance).
    func setManualGst(itemId: String, cents: Int) {
        guard let row = txn(itemId), row.amountCents < 0 else { return }
        row.gstFree = false
        let r = GstTreatment.applyManualGst(cents)
        row.gstCents = r.gstCents; row.gstSource = r.gstSource
        persist(row)
    }

    func setPaygInstalmentCents(_ cents: Int) {
        paygInstalmentCents = max(0, cents)
        store.setPaygInstalmentCents(paygInstalmentCents, profileId: profileId, periodKey: periodKey)
        recompute()
    }

    private func currentSnapshot() -> BasLocalStore.Snapshot {
        BasLocalStore.Snapshot(g1: result.g1, oneA: result.oneA, oneB: result.oneB,
                               netGst: result.netGstCents, payg: result.paygCents,
                               total: result.totalPayableCents, lodgedAtMs: lodgedAtMs ?? 0)
    }

    func markAsLodged() {
        let ms = Epoch.nowMs()
        let snap = BasLocalStore.Snapshot(g1: result.g1, oneA: result.oneA, oneB: result.oneB,
                                          netGst: result.netGstCents, payg: result.paygCents,
                                          total: result.totalPayableCents, lodgedAtMs: ms)
        store.markLodged(snap, profileId: profileId, periodKey: periodKey)
        lodgedAtMs = ms
    }

    func export(toEmail: String?) async {
        exportInProgress = true; exportError = nil
        do {
            let r = try await api.exportBas(profileId: profileId, from: fromISO, to: toISO,
                                            paygInstalmentCents: paygInstalmentCents, toEmail: toEmail)
            if case let .basPack(pdfUrl, csvUrl, _, emailed, _) = r {
                exportPdfUrl = pdfUrl; exportCsvUrl = csvUrl; exportEmailed = emailed
            }
            exportInProgress = false
        } catch let e as APIError {
            exportError = e.message; exportInProgress = false
        } catch {
            exportError = "Export failed. Try again."; exportInProgress = false
        }
    }
}
