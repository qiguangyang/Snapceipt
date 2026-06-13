import Foundation
import SwiftData
import Observation

/// Drives budget CRUD + the Home tracker. Loads the active profile's live budgets,
/// computes per-budget spend via the pure `BudgetSpend` helper (injected `now`), and
/// upserts/soft-deletes through the sync seam. `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class BudgetListViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let now: Date

    /// Active profile's live budgets.
    private(set) var budgets: [Budget] = []

    /// A budget plus its computed spend, for the tracker/list rows.
    struct Row: Identifiable {
        let budget: Budget
        let spentCents: Int
        var id: String { budget.id }
        var overCap: Bool { spentCents > budget.capCents }
    }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String,
         profileId: String, now: Date = Epoch.now()) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.now = now
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.capCents, order: .reverse), SortDescriptor(\.createdAt)])
        budgets = (try? context.fetch(d)) ?? []
    }

    /// Snapshot the active profile's expenses for the spend math (categoryId-linked).
    private func txns() -> [BudgetSpend.Txn] {
        let pid = profileId
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        return ((try? context.fetch(d)) ?? []).map {
            BudgetSpend.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents, categoryId: $0.categoryId)
        }
    }

    /// All budgets as rows (with spend), preserving the cap-desc reload order.
    func rows() -> [Row] {
        let snaps = txns()
        return budgets.map { Row(budget: $0, spentCents: BudgetSpend.spent(budget: $0, txns: snaps, now: now)) }
    }

    /// The active profile's top-3 monthly budgets (cap desc) for the Home tracker.
    func top3() -> [Row] { Array(rows().prefix(3)) }

    /// Create (existing == nil) or update a budget, then enqueue an upsert.
    func save(existing: Budget?, categoryId: String?, catKey: String?, label: String,
              capCents: Int, alertThresholdPct: Int) {
        let row: Budget
        if let existing {
            existing.categoryId = categoryId
            existing.catKey = catKey
            existing.label = label
            existing.capCents = capCents
            existing.alertThresholdPct = alertThresholdPct
            existing.updatedAt = Epoch.nowMs()
            row = existing
        } else {
            row = Budget(userId: userId, profileId: profileId, categoryId: categoryId,
                         catKey: catKey, label: label, period: "monthly",
                         capCents: capCents, alertThresholdPct: alertThresholdPct)
            context.insert(row)
        }
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .budget, entity: row)
    }

    /// Soft-delete (set deletedAt) + enqueue a delete.
    func delete(_ budget: Budget) {
        budget.deletedAt = Epoch.nowMs()
        budget.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .budget, entity: budget)
    }
}
