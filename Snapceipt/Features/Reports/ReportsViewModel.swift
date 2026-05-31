import Foundation
import SwiftData
import Observation
import SwiftUI

/// Drives the Reports tab: loads the active profile's transactions + F1 logbook
/// claims, then exposes chart data + card values + the insight for the selected
/// `Period`. `@MainActor`; deps injected for tests. `now` is injected (no hidden
/// `Date()`) so windows are deterministic. (spec §5)
@Observable
@MainActor
final class ReportsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let startMonth: Int
    @ObservationIgnored private let now: Date

    /// Selected period; setting it recomputes the period-scoped outputs.
    var period: Period = .month { didSet { recompute() } }

    /// True when the active profile is anything other than "personal".
    private(set) var isBusiness: Bool = false

    // Period-scoped outputs.
    private(set) var netCents: Int = 0
    private(set) var incomeCents: Int = 0
    private(set) var expenseCents: Int = 0
    private(set) var donutSegments: [DonutSegment] = []
    private(set) var legend: [(catKey: String, spendCents: Int)] = []
    private(set) var donutTotalCents: Int = 0
    private(set) var insight: String = ""

    // Fixed / FY-to-date outputs.
    private(set) var barData: [BarPairDatum] = []
    private(set) var deductibleYTDCents: Int = 0
    private(set) var gstYTDCents: Int = 0

    /// Active-profile FY logbook hero numbers for the logbook rows.
    private(set) var vehicleClaimCents: Int = 0
    private(set) var wfhClaimCents: Int = 0

    private var txns: [TransactionQuery.Txn] = []

    init(context: ModelContext, userId: String, profileId: String,
         startMonth: Int, now: Date = Date()) {
        self.context = context
        self.userId = userId
        self.profileId = profileId
        self.startMonth = startMonth
        self.now = now
        load()
    }

    /// The trend-card caption ("This month" / "This quarter" / "FY2025-26").
    var headline: String { period.headline(now: now, startMonth: startMonth) }
    /// The current period's range label (for the donut + export).
    var periodLabel: String { period.window(now: now, startMonth: startMonth).label }
    /// FY start year for the active profile's FY claims.
    var fyStartYear: Int { FinancialYear.of(now, startMonth: startMonth).startYear }

    func load() {
        let pid = profileId
        // Profile type -> layout flag.
        var pd = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == pid })
        pd.fetchLimit = 1
        isBusiness = ((try? context.fetch(pd))?.first?.type ?? "personal") != "personal"

        // Transactions for this profile.
        let td = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let rows = (try? context.fetch(td)) ?? []
        txns = rows.map {
            TransactionQuery.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents,
                                 catKey: $0.catKey, deductiblePct: $0.deductiblePct,
                                 gstCents: $0.gstCents)
        }

        // F1 vehicle-year claims for the active profile + current FY.
        let fy = fyStartYear
        let vd = FetchDescriptor<VehicleYear>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil && $0.fyStartYear == fy })
        let vehicleClaims = ((try? context.fetch(vd)) ?? []).compactMap { $0.claimCents }
        vehicleClaimCents = vehicleClaims.reduce(0, +)

        // F1 WFH claims for the active profile (FY-filtered below via deductibleYTD).
        let wd = FetchDescriptor<WFHLog>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let wfhLogs = (try? context.fetch(wd)) ?? []
        let fyWindow = Period.fy.window(now: now, startMonth: startMonth)
        let wfhClaimsInFY: [Int] = wfhLogs.compactMap { log in
            guard FinancialYear.isIn(log.logDate, fyStartYear: fy, startMonth: startMonth) else { return nil }
            return log.claimCents
        }
        wfhClaimCents = wfhClaimsInFY.reduce(0, +)

        // FY-to-date pills (period-independent).
        deductibleYTDCents = TransactionQuery.deductibleYTD(
            txns, fyWindow: fyWindow, vehicleYearClaims: vehicleClaims, wfhClaims: wfhClaimsInFY)
        gstYTDCents = TransactionQuery.gstYTD(txns, fyWindow: fyWindow)

        // Fixed rolling-5 trend.
        barData = TransactionQuery.monthlyTrend(txns, now: now)

        recompute()
    }

    /// Recompute the period-scoped outputs (net headline, donut, insight).
    private func recompute() {
        let window = period.window(now: now, startMonth: startMonth)
        let net = TransactionQuery.netSaved(txns, window: window)
        netCents = net.netCents
        incomeCents = net.incomeCents
        expenseCents = net.expenseCents

        legend = TransactionQuery.byCategory(txns, window: window)
        donutTotalCents = legend.reduce(0) { $0 + $1.spendCents }
        donutSegments = legend.prefix(5).map { row in
            DonutSegment(id: row.catKey, value: Double(row.spendCents), tint: tint(row.catKey))
        }

        // Prior window = the same period one step earlier (for the delta).
        let prevNow = prevAnchor(window: window)
        let prevWindow = period.window(now: prevNow, startMonth: startMonth)
        insight = InsightBuilder.insight(mode: isBusiness ? .business : .personal,
                                         txns: txns, window: window, prevWindow: prevWindow,
                                         periodWord: period.word)
    }

    /// An anchor date inside the immediately-prior period (one day before this
    /// window's start), so `Period.window(now:)` resolves the previous window.
    private func prevAnchor(window: Period.Window) -> Date {
        window.start.addingTimeInterval(-86_400)
    }

    private func tint(_ catKey: String) -> Color {
        if let ck = CategoryKey(rawValue: catKey), let meta = CATS[ck] { return meta.tint }
        return Palette.ink3
    }
}
