import Foundation
import SwiftData

/// Drives the Categories & rules screen: lists the profile's built-in `Category`
/// rows (seeded lazily on init via `CategorySeeder`), derives a live receipt count
/// per category key, and edits each category's default deductible %.
/// `@MainActor`; deps injected, mirroring `BudgetListViewModel`.
@Observable
@MainActor
final class CategoriesViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var categories: [Category] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        CategorySeeder.ensure(profileId: profileId, userId: userId, context: context, sync: sync)
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Category>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.label)])
        categories = (try? context.fetch(d)) ?? []
    }

    /// Live receipt count for this profile by the category's `key` (manual +
    /// email_in + scan + import all count; only live rows).
    func receiptCount(_ cat: Category) -> Int {
        let pid = profileId
        let key = cat.key
        let d = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid && $0.catKey == key && $0.deletedAt == nil })
        return ((try? context.fetch(d)) ?? []).count
    }

    func setDefaultDeductible(_ cat: Category, pct: Int) {
        cat.defaultDeductiblePct = max(0, min(100, pct))
        cat.updatedAt = Epoch.nowMs()
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .category, entity: cat)
    }
}
