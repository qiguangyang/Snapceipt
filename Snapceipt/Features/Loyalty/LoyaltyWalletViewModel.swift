import Foundation
import SwiftData
import Observation

/// Drives the loyalty wallet. Loads the active profile's live cards (sorted by
/// sortOrder then createdAt), soft-deletes through the sync seam. `@MainActor`;
/// deps injected for tests. Mirrors BudgetListViewModel.
@Observable
@MainActor
final class LoyaltyWalletViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// Active profile's live loyalty cards.
    private(set) var cards: [LoyaltyCard] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<LoyaltyCard>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        cards = (try? context.fetch(d)) ?? []
    }

    /// Soft-delete (set deletedAt) + enqueue a delete.
    func delete(_ card: LoyaltyCard) {
        card.deletedAt = Epoch.nowMs()
        card.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .loyaltyCard, entity: card)
    }

    /// New card sortOrder = (max existing sortOrder for the profile) + 1, else 0.
    func nextSortOrder() -> Int {
        (cards.map(\.sortOrder).max().map { $0 + 1 }) ?? 0
    }
}
