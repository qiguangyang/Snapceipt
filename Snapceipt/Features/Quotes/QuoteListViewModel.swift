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

    /// Clone a quote (client, GST flags, line items) into a fresh DRAFT — new id, no
    /// number / invoice / PDF / sent state — so the user can quickly start a new quote
    /// from an existing one. Returns the new quote's id (to open its editor).
    @discardableResult
    func duplicate(_ quote: Quote) -> String? {
        let copy = Quote(
            userId: userId, profileId: profileId,
            clientName: quote.clientName, clientEmail: quote.clientEmail,
            gstEnabled: quote.gstEnabled, gstInclusive: quote.gstInclusive,
            subtotalCents: quote.subtotalCents, gstCents: quote.gstCents, totalCents: quote.totalCents,
            currency: quote.currency, status: "draft", validUntil: quote.validUntil,
            gstRateBp: quote.gstRateBp)
        context.insert(copy)

        let qid = quote.id
        let d = FetchDescriptor<QuoteLineItem>(
            predicate: #Predicate { $0.quoteId == qid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder)])
        let lines = (try? context.fetch(d)) ?? []
        var cloned: [QuoteLineItem] = []
        for (idx, line) in lines.enumerated() {
            let c = QuoteLineItem(userId: userId, quoteId: copy.id,
                                  itemDescription: line.itemDescription,
                                  quantity: line.quantity, unitPriceCents: line.unitPriceCents,
                                  sortOrder: idx)
            context.insert(c)
            cloned.append(c)
        }
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .quote, entity: copy)
        for c in cloned { sync.enqueue(op: "upsert", entityType: .quoteLineItem, entity: c) }
        return copy.id
    }
}
