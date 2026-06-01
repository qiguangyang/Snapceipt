import Foundation
import SwiftData

@Observable
@MainActor
final class SmartRulesViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var rules: [SmartRule] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<SmartRule>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.createdAt)])
        rules = (try? context.fetch(d)) ?? []
    }

    @discardableResult
    func create(matchType: String, matcher: String, categoryId: String?, setDeductiblePct: Int?, setMode: String?) -> SmartRule {
        let r = SmartRule(userId: userId, profileId: profileId, matchType: matchType, matcher: matcher,
                          categoryId: categoryId, setDeductiblePct: setDeductiblePct, setMode: setMode)
        context.insert(r)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .smartRule, entity: r)
        return r
    }

    func update(_ rule: SmartRule, _ mutate: (SmartRule) -> Void) {
        mutate(rule)
        rule.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .smartRule, entity: rule)
    }

    func delete(_ rule: SmartRule) {
        rule.deletedAt = Epoch.nowMs()
        rule.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .smartRule, entity: rule)
    }
}
