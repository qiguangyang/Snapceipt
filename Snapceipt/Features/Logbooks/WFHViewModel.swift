import Foundation
import SwiftData
import Observation

/// Drives the WFH screen: loads the active profile's logs, computes FY hero + the
/// this-week chart, and upserts one log per day. `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class WFHViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored let rateCentsPerHour: Int
    @ObservationIgnored private let startMonth: Int

    /// Active profile's live logs, newest-first.
    private(set) var logs: [WFHLog] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
         profileId: String, rateCentsPerHour: Int, startMonth: Int) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.rateCentsPerHour = rateCentsPerHour
        self.startMonth = startMonth
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<WFHLog>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.logDate, order: .reverse)])
        logs = (try? context.fetch(d)) ?? []
    }

    /// The live log for a date, or nil. Drives the sheet's pre-fill/edit.
    func existingLog(for date: String) -> WFHLog? {
        logs.first(where: { $0.logDate == date })
    }

    private func entries() -> [WFHCalc.Entry] {
        logs.map { WFHCalc.Entry(logDate: $0.logDate, minutes: $0.minutes, claimCents: $0.claimCents ?? 0) }
    }

    func hero(fyStartYear: Int) -> WFHCalc.Hero {
        WFHCalc.hero(entries: entries(), fyStartYear: fyStartYear, startMonth: startMonth)
    }

    func thisWeekMinutes(today: Date = Date()) -> [Int] {
        WFHCalc.thisWeekMinutes(entries: entries(), today: today)
    }

    /// Upsert a WFH log for `date` (one-per-day). Snapshots the rate + claim.
    func logHours(date: String, minutes: Int, note: String?) {
        let claim = WFHCalc.claimCents(minutes: minutes, rateCentsPerHour: rateCentsPerHour)
        if let existing = existingLog(for: date) {
            existing.minutes = minutes
            existing.note = note
            existing.rateCentsPerHour = rateCentsPerHour
            existing.claimCents = claim
            existing.updatedAt = Epoch.nowMs()
            try? context.save()
            reload()
            sync.enqueue(op: "upsert", entityType: .wfhLog, entity: existing)
        } else {
            let log = WFHLog(userId: userId, profileId: profileId, logDate: date,
                             minutes: minutes, note: note,
                             rateCentsPerHour: rateCentsPerHour, claimCents: claim)
            context.insert(log)
            try? context.save()
            reload()
            sync.enqueue(op: "upsert", entityType: .wfhLog, entity: log)
        }
    }
}
