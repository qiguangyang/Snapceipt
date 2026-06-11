import Foundation
import SwiftData
import Observation

/// Drives the AlertsSheet: derives the §4.7 feed from live budgets + their spend, filters
/// by the UserDefaults cache, and applies read/dismiss. `now` + cache injected for tests.
@Observable
@MainActor
final class AlertsViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let now: Date
    @ObservationIgnored private var cache: AlertCache

    private(set) var items: [AlertFeed.Item] = []

    init(context: ModelContext, userId: String, profileId: String,
         now: Date = Epoch.now(), cache: AlertCache = AlertCache()) {
        self.context = context
        self.userId = userId
        self.profileId = profileId
        self.now = now
        self.cache = cache
        reload()
    }

    func reload() {
        let pid = profileId
        let bd = FetchDescriptor<Budget>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let budgets = (try? context.fetch(bd)) ?? []
        let td = FetchDescriptor<Transaction>(predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let txns = ((try? context.fetch(td)) ?? []).map {
            BudgetSpend.Txn(txnDate: $0.txnDate, amountCents: $0.amountCents, categoryId: $0.categoryId)
        }
        let inputs = budgets.map { b in
            AlertFeed.Input(budgetId: b.id, label: b.label, capCents: b.capCents,
                            alertThresholdPct: b.alertThresholdPct,
                            spentCents: BudgetSpend.spent(budget: b, txns: txns, now: now),
                            alertSentAt: b.alertSentAt)
        }
        items = cache.visible(AlertFeed.items(inputs: inputs, now: now))
    }

    func isRead(_ id: String) -> Bool { cache.isRead(id) }
    func markRead(_ id: String) { cache.markRead(id); reload() }
    func dismiss(_ id: String) { cache.dismiss(id); reload() }
}
