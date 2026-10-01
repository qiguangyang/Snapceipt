import Foundation
import SwiftData

/// Creates committed drafts from saved snapshots without saving or rolling back editor input.
@MainActor
final class RepeatWorkService {
    enum ValidationError: LocalizedError {
        case sourceUnavailable, clientUnavailable, emptySource, profileUnavailable
        var errorDescription: String? {
            switch self {
            case .sourceUnavailable: "This document is no longer available in this business. Choose another document."
            case .clientUnavailable: "Select a live client in this business before creating again."
            case .emptySource: "Add at least one item to the original document before creating again."
            case .profileUnavailable: "Select a live business profile before creating a draft."
            }
        }
    }

    private let context: ModelContext
    private let sync: any SyncEnqueuing
    private let userId: String
    private let profileId: String
    private let persist: (ModelContext) throws -> Void

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.persist = persist
    }

    func newQuote(clientId: String, now: Date) throws -> String {
        let mutationContext = isolatedContext()
        let client = try liveClient(clientId, in: mutationContext)
        let profile = try liveProfile(in: mutationContext)
        let stamp = Int((now.timeIntervalSince1970 * 1000).rounded())
        let quote = Quote(userId: userId, profileId: profileId, clientId: client.id,
                          clientName: client.name, clientEmail: client.email,
                          clientAddress: client.address, clientMobile: client.mobilePhone,
                          gstEnabled: profile.gstRegistered,
                          currency: AppSettings.businessCurrency(profileId: profileId),
                          validUntil: Self.documentDate(now: now, addingDays: 28),
                          gstRateBp: profile.gstRateBp, createdAt: stamp, updatedAt: stamp)
        mutationContext.insert(quote)
        try commit(quote, lines: [], in: mutationContext)
        return quote.id
    }

    func newInvoice(clientId: String, now: Date) throws -> String {
        let mutationContext = isolatedContext()
        let client = try liveClient(clientId, in: mutationContext)
        let profile = try liveProfile(in: mutationContext)
        let stamp = Int((now.timeIntervalSince1970 * 1000).rounded())
        let invoice = Invoice(userId: userId, profileId: profileId, clientId: client.id,
                              clientName: client.name, clientEmail: client.email,
                              gstEnabled: profile.gstRegistered,
                              currency: AppSettings.businessCurrency(profileId: profileId),
                              dueDate: Self.documentDate(now: now, addingDays: 14),
                              gstRateBp: profile.gstRateBp, createdAt: stamp, updatedAt: stamp)
        mutationContext.insert(invoice)
        try commit(invoice, lines: [], in: mutationContext)
        return invoice.id
    }

    func repeatQuote(sourceId: String, now: Date) throws -> String {
        try cloneQuote(sourceId: sourceId, now: now, allowLegacy: false)
    }

    /// Preserve v1's unlinked/empty quote duplication while using the same safe save boundary.
    func duplicateLegacyQuote(sourceId: String, now: Date) throws -> String {
        try cloneQuote(sourceId: sourceId, now: now, allowLegacy: true)
    }

    private func cloneQuote(sourceId: String, now: Date, allowLegacy: Bool) throws -> String {
        let mutationContext = isolatedContext()
        let uid = userId, pid = profileId
        let sourceDescriptor = FetchDescriptor<Quote>(predicate: #Predicate {
            $0.id == sourceId && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        guard let source = try mutationContext.fetch(sourceDescriptor).first else { throw ValidationError.sourceUnavailable }
        let client: Client?
        if let clientId = source.clientId { client = try liveClient(clientId, in: mutationContext) }
        else if allowLegacy { client = nil }
        else { throw ValidationError.clientUnavailable }
        let lines = try mutationContext.fetch(FetchDescriptor<QuoteLineItem>(predicate: #Predicate {
            $0.quoteId == sourceId && $0.userId == uid && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
        guard allowLegacy || !lines.isEmpty else { throw ValidationError.emptySource }
        let stamp = Int((now.timeIntervalSince1970 * 1000).rounded())
        let quote = Quote(userId: userId, profileId: profileId, clientId: client?.id,
                          clientName: client?.name ?? source.clientName,
                          clientEmail: client == nil ? source.clientEmail : client?.email,
                          clientAddress: client == nil ? source.clientAddress : client?.address,
                          clientMobile: client == nil ? source.clientMobile : client?.mobilePhone,
                          gstEnabled: source.gstEnabled, gstInclusive: source.gstInclusive,
                          subtotalCents: source.subtotalCents, gstCents: source.gstCents,
                          totalCents: source.totalCents, currency: source.currency,
                          validUntil: Self.documentDate(now: now, addingDays: 28),
                          gstRateBp: source.gstRateBp, createdAt: stamp, updatedAt: stamp)
        mutationContext.insert(quote)
        let copies = lines.enumerated().map { index, line in
            QuoteLineItem(userId: userId, quoteId: quote.id, itemDescription: line.itemDescription,
                          unitLabel: line.unitLabel, quantity: line.quantity,
                          unitPriceCents: line.unitPriceCents, sortOrder: index,
                          createdAt: stamp, updatedAt: stamp)
        }
        for line in copies { mutationContext.insert(line) }
        try commit(quote, lines: copies, in: mutationContext)
        return quote.id
    }

    func repeatInvoice(sourceId: String, now: Date) throws -> String {
        let mutationContext = isolatedContext()
        let uid = userId, pid = profileId
        let sourceDescriptor = FetchDescriptor<Invoice>(predicate: #Predicate {
            $0.id == sourceId && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        guard let source = try mutationContext.fetch(sourceDescriptor).first else { throw ValidationError.sourceUnavailable }
        guard let clientId = source.clientId else { throw ValidationError.clientUnavailable }
        let client = try liveClient(clientId, in: mutationContext)
        let lines = try mutationContext.fetch(FetchDescriptor<InvoiceLineItem>(predicate: #Predicate {
            $0.invoiceId == sourceId && $0.userId == uid && $0.deletedAt == nil
        }, sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt), SortDescriptor(\.id)]))
        guard !lines.isEmpty else { throw ValidationError.emptySource }
        let stamp = Int((now.timeIntervalSince1970 * 1000).rounded())
        let invoice = Invoice(userId: userId, profileId: profileId, clientId: client.id,
                              clientName: client.name, clientEmail: client.email,
                              gstEnabled: source.gstEnabled, gstInclusive: source.gstInclusive,
                              subtotalCents: source.subtotalCents, gstCents: source.gstCents,
                              totalCents: source.totalCents, currency: source.currency,
                              dueDate: Self.documentDate(now: now, addingDays: 14),
                              gstRateBp: source.gstRateBp, createdAt: stamp, updatedAt: stamp)
        mutationContext.insert(invoice)
        let copies = lines.enumerated().map { index, line in
            InvoiceLineItem(userId: userId, invoiceId: invoice.id, itemDescription: line.itemDescription,
                            unitLabel: line.unitLabel, quantity: line.quantity,
                            unitPriceCents: line.unitPriceCents, sortOrder: index,
                            createdAt: stamp, updatedAt: stamp)
        }
        for line in copies { mutationContext.insert(line) }
        try commit(invoice, lines: copies, in: mutationContext)
        return invoice.id
    }

    private func isolatedContext() -> ModelContext {
        let mutationContext = ModelContext(context.container)
        mutationContext.autosaveEnabled = false
        return mutationContext
    }

    private func liveClient(_ id: String, in mutationContext: ModelContext) throws -> Client {
        let uid = userId, pid = profileId
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        guard let client = try mutationContext.fetch(descriptor).first else { throw ValidationError.clientUnavailable }
        return client
    }

    private func liveProfile(in mutationContext: ModelContext) throws -> Profile {
        let uid = userId, pid = profileId
        let descriptor = FetchDescriptor<Profile>(predicate: #Predicate {
            $0.id == pid && $0.userId == uid && $0.deletedAt == nil
        })
        guard let profile = try mutationContext.fetch(descriptor).first else { throw ValidationError.profileUnavailable }
        return profile
    }

    private func commit(_ parent: any Syncable, lines: [any Syncable], in mutationContext: ModelContext) throws {
        let mutations = ([parent] + lines).map {
            SyncMutationDescriptor(op: "upsert", entityType: $0.entityType, entity: $0)
        }
        do { try sync.persistAndEnqueue(mutations: mutations, context: mutationContext, save: persist) }
        catch { mutationContext.rollback(); throw error }
    }

    static func documentDate(now: Date, addingDays days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let date = calendar.date(byAdding: .day, value: days, to: day)!
        return ExportDateFormatter.shared.string(from: date)
    }
}
