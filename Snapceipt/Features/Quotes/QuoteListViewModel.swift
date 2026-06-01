import Foundation
import SwiftData
import Observation

/// Drives the quotes list. Loads the active profile's live quotes (newest first),
/// soft-deletes through the sync seam. `@MainActor`; deps injected for tests.
/// Mirrors LoyaltyWalletViewModel.
@Observable
@MainActor
final class QuoteListViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    /// Active profile's live quotes, newest first.
    private(set) var quotes: [Quote] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Quote>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        quotes = (try? context.fetch(d)) ?? []
    }

    /// Soft-delete (set deletedAt) + enqueue a delete. (Line items tombstone with
    /// the quote server-side; the local rows are orphaned harmlessly.)
    func delete(_ quote: Quote) {
        quote.deletedAt = Epoch.nowMs()
        quote.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .quote, entity: quote)
    }
}
