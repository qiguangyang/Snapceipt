import Foundation
import SwiftData
import Observation

/// Drives the quote editor. Owns a draft quote id, a working line-item set, the GST
/// toggle, and the client snapshot; computes live totals via `QuoteTotals`; persists
/// via `saveDraft()` (quote upsert + per-line diff/enqueue) and sends via the injected
/// `APIClient`. `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class QuoteEditorViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var quoteId: String?
    var lineItems: [QuoteLineItem] = []
    var gstEnabled = true
    /// When true (and `gstEnabled`), entered prices already include GST — see
    /// `QuoteTotals.compute`. Only meaningful while `gstEnabled`.
    var gstInclusive = false
    private(set) var clientName: String?
    private(set) var clientEmail: String?

    private(set) var number: String?
    private(set) var status: String = QuoteStatus.draft.rawValue
    private(set) var sentAt: Int?
    private(set) var validUntil: String?
    private(set) var pdfUrl: String?
    private(set) var emailed = false

    private(set) var isSending = false
    var errorMessage: String?

    @ObservationIgnored private var originalLineIds: Set<String> = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
    }

    var statusValue: QuoteStatus? { QuoteStatus(rawValue: status) }

    var totals: (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled, gstInclusive: gstInclusive)
    }

    var canSend: Bool {
        !(clientName ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !lineItems.isEmpty
    }

    var displayNumber: String { number ?? "Draft" }

    func load(id: String?) {
        if let id, let q = fetchQuote(id) {
            quoteId = q.id
            gstEnabled = q.gstEnabled
            gstInclusive = q.gstInclusive
            clientName = q.clientName
            clientEmail = q.clientEmail
            number = q.number
            status = q.status
            sentAt = q.sentAt
            validUntil = q.validUntil
            let qid = q.id
            let d = FetchDescriptor<QuoteLineItem>(
                predicate: #Predicate { $0.quoteId == qid && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
            lineItems = (try? context.fetch(d)) ?? []
            originalLineIds = Set(lineItems.map(\.id))
        } else {
            quoteId = ID.uuidv7()
            gstEnabled = true
            gstInclusive = false
            clientName = nil
            clientEmail = nil
            number = nil
            status = QuoteStatus.draft.rawValue
            sentAt = nil
            validUntil = nil
            lineItems = []
            originalLineIds = []
        }
    }

    func setClient(name: String, email: String?) {
        clientName = name
        clientEmail = email
    }

    func addLine() {
        guard let qid = quoteId else { return }
        lineItems.append(QuoteLineItem(userId: userId, quoteId: qid,
                                       itemDescription: "", quantity: 1, unitPriceCents: 0,
                                       sortOrder: lineItems.count))
    }

    func removeLine(_ line: QuoteLineItem) {
        lineItems.removeAll { $0.id == line.id }
    }

    func saveDraft() {
        guard let qid = quoteId else { return }
        let t = totals
        let quote = fetchQuote(qid) ?? {
            let q = Quote(userId: userId, profileId: profileId)
            q.id = qid
            context.insert(q)
            return q
        }()
        quote.profileId = profileId
        quote.clientName = clientName
        quote.clientEmail = clientEmail
        quote.gstEnabled = gstEnabled
        quote.gstInclusive = gstInclusive
        quote.subtotalCents = t.subtotal
        quote.gstCents = t.gst
        quote.totalCents = t.total
        quote.validUntil = validUntil
        quote.updatedAt = Epoch.nowMs()

        let keptIds = Set(lineItems.map(\.id))
        for (idx, line) in lineItems.enumerated() {
            line.sortOrder = idx
            line.updatedAt = Epoch.nowMs()
            if fetchLine(line.id) == nil { context.insert(line) }
        }
        let removed = originalLineIds.subtracting(keptIds)
        var deletedRows: [QuoteLineItem] = []
        for rid in removed {
            if let row = fetchLine(rid) {
                row.deletedAt = Epoch.nowMs()
                row.updatedAt = Epoch.nowMs()
                deletedRows.append(row)
            }
        }
        try? context.save()

        sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
        for line in lineItems { sync.enqueue(op: "upsert", entityType: .quoteLineItem, entity: line) }
        for row in deletedRows { sync.enqueue(op: "delete", entityType: .quoteLineItem, entity: row) }
        originalLineIds = keptIds
    }

    func send(api: APIClient) async -> Bool {
        guard let qid = quoteId else { return false }
        errorMessage = nil
        saveDraft()
        isSending = true
        defer { isSending = false }
        // The send route loads the quote from D1 (it was only just enqueued locally
        // by saveDraft). Push the outbox first so the quote + its line items exist
        // server-side before we ask the backend to mint/number/PDF/email it — without
        // this, a never-synced draft 404s as "Quote not found for this user".
        await sync.flush()
        do {
            let r = try await api.sendQuote(qid)
            number = r.number
            status = r.status
            sentAt = r.sentAt
            pdfUrl = r.pdfUrl
            emailed = r.emailed
            if let quote = fetchQuote(qid) {
                quote.number = r.number
                quote.status = r.status
                quote.sentAt = r.sentAt
                quote.subtotalCents = r.subtotalCents
                quote.gstCents = r.gstCents
                quote.totalCents = r.totalCents
                quote.updatedAt = Epoch.nowMs()
                try? context.save()
                sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
            }
            return true
        } catch let e as APIError {
            errorMessage = e.message
            return false
        } catch {
            errorMessage = "Couldn’t send the quote. Try again."
            return false
        }
    }

    private func fetchQuote(_ id: String) -> Quote? {
        var d = FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func fetchLine(_ id: String) -> QuoteLineItem? {
        var d = FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
