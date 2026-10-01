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
    @ObservationIgnored private let repeatWork: RepeatWorkService
    @ObservationIgnored private let clock: () -> Date
    private(set) var isCreatingDraft = false
    var errorMessage: String?

    /// Active profile's live quotes, newest first.
    private(set) var quotes: [Quote] = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
         clock: @escaping () -> Date = { Date() }) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.repeatWork = RepeatWorkService(context: context, sync: sync, userId: userId, profileId: profileId, persist: persist)
        self.clock = clock
        reload()
    }

    func reload() {
        let uid = userId, pid = profileId
        let d = FetchDescriptor<Quote>(
            predicate: #Predicate { $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil },
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

    /// Hold the guard through the saved-draft review prompt and navigation.
    /// Cancellation calls finishCreatingDraft(); returning from the editor creates a new list model.
    @discardableResult
    func duplicate(_ quote: Quote) -> String? {
        guard !isCreatingDraft else { return nil }
        isCreatingDraft = true
        errorMessage = nil
        do {
            let id: String
            if quote.clientId != nil {
                id = try repeatWork.repeatQuote(sourceId: quote.id, now: clock())
            } else {
                id = try repeatWork.duplicateLegacyQuote(sourceId: quote.id, now: clock())
            }
            reload()
            return id
        } catch {
            isCreatingDraft = false
            errorMessage = (error as? RepeatWorkService.ValidationError)?.errorDescription
                ?? "Couldn’t create the draft. Try again."
            return nil
        }
    }

    /// End presentation after cancellation; the committed draft remains in the list.
    func finishCreatingDraft() { isCreatingDraft = false }
}
