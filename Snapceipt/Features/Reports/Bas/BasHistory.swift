import Foundation

/// Pure builder for the BAS history hub (spec 2026-06-19). Given the profile's
/// engine-txns + a lodged-snapshot lookup, returns one `Row` per period from the
/// current period back to the earliest period with data, capped at ~3 years. No
/// SwiftData, no hidden `Date()` — fully unit-testable.
enum BasHistory {
    struct Row: Identifiable, Equatable {
        let id: String          // periodKey
        let offset: Int         // 0 = current, negative = past
        let periodKey: String
        let label: String       // e.g. "Apr–Jun 2026"
        let window: Period.Window
        let dueDate: Date
        let netGstCents: Int    // headline figure = 1A − 1B
        let status: Status
    }

    enum Status: Equatable {
        case lodged(atMs: Int, drifted: Bool)
        case due(Date)             // current / upcoming, not lodged — neutral
        case notMarkedLodged(Date) // past, not lodged — amber (NEVER "overdue")
    }

    /// 3-year window: 12 quarters / 36 months.
    static func cap(_ basPeriod: BasPeriod) -> Int { basPeriod == .quarterly ? 12 : 36 }
    private static func monthsPerPeriod(_ basPeriod: BasPeriod) -> Int { basPeriod == .quarterly ? 3 : 1 }

    private static var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private static func window(offset: Int, basPeriod: BasPeriod, startMonth: Int, now: Date) -> Period.Window {
        let anchor = utcCal.date(byAdding: .month, value: offset * monthsPerPeriod(basPeriod), to: now)!
        let p: Period = basPeriod == .quarterly ? .quarter : .month
        return p.window(now: anchor, startMonth: startMonth)
    }

    private static func inWindow(_ txns: [BasEngine.Txn], _ w: Period.Window) -> [BasEngine.Txn] {
        let iso = ExportDateFormatter.shared
        return txns.filter { iso.date(from: $0.txnDate).map { $0 >= w.start && $0 < w.end } ?? false }
    }

    /// Classify a period from its lodged snapshot, recomputed figures, due date, and `now`.
    /// Drift compares only the engine-recomputed GST figures (g1/1A/1B/net) — PAYG/total are
    /// per-period manual fields loaded separately, so excluding them avoids false drift.
    static func status(lodged: BasLocalStore.Snapshot?, result: BasEngine.Result,
                       dueDate: Date, now: Date) -> Status {
        if let s = lodged {
            let drifted = s.g1 != result.g1 || s.oneA != result.oneA
                || s.oneB != result.oneB || s.netGst != result.netGstCents
            return .lodged(atMs: s.lodgedAtMs, drifted: drifted)
        }
        return now <= dueDate ? .due(dueDate) : .notMarkedLodged(dueDate)
    }

    /// Furthest-back offset (≤ 0, ≥ capFloor) whose period has a txn or a lodged snapshot.
    /// `0` when there is no history within the cap.
    static func earliestOffset(txns: [BasEngine.Txn], lodged: (String) -> BasLocalStore.Snapshot?,
                               basPeriod: BasPeriod, startMonth: Int, now: Date) -> Int {
        let capFloor = -(cap(basPeriod) - 1)
        var deepest = 0
        for offset in stride(from: 0, through: capFloor, by: -1) {
            let w = window(offset: offset, basPeriod: basPeriod, startMonth: startMonth, now: now)
            let key = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
            if !inWindow(txns, w).isEmpty || lodged(key) != nil { deepest = offset }
        }
        return deepest
    }

    /// Contiguous rows `[0 … earliestOffset]`, most-recent first.
    static func build(txns: [BasEngine.Txn], lodged: (String) -> BasLocalStore.Snapshot?,
                      gstRegistered: Bool, basPeriod: BasPeriod, startMonth: Int, now: Date) -> [Row] {
        let floor = earliestOffset(txns: txns, lodged: lodged, basPeriod: basPeriod,
                                   startMonth: startMonth, now: now)
        var rows: [Row] = []
        for offset in stride(from: 0, through: floor, by: -1) {
            let w = window(offset: offset, basPeriod: basPeriod, startMonth: startMonth, now: now)
            let key = BasPeriodKey.make(window: w, basPeriod: basPeriod, startMonth: startMonth)
            let result = BasEngine.compute(txns: inWindow(txns, w), gstRegistered: gstRegistered,
                                           manual: BasEngine.Manual())
            let due = BasSchedule.dueDate(for: w, period: basPeriod)
            rows.append(Row(id: key, offset: offset, periodKey: key, label: w.label, window: w,
                            dueDate: due, netGstCents: result.netGstCents,
                            status: status(lodged: lodged(key), result: result, dueDate: due, now: now)))
        }
        return rows
    }
}
