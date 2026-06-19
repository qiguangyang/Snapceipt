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
    private(set) var pdfR2Key: String?
    /// The invoice this quote was converted into (loaded from storage).
    private(set) var invoiceId: String?
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
            pdfR2Key = q.pdfR2Key
            invoiceId = q.invoiceId
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
            pdfR2Key = nil
            invoiceId = nil
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

    /// The Generate/Share PDF button is enabled whenever the quote is valid (client +
    /// ≥1 line item) — NOT gated on an existing pdfUrl (spec §3).
    var canGeneratePdf: Bool { canSend }

    /// Convert is offered on a sent/accepted quote, or whenever an invoice already
    /// exists (re-open it). (spec §4.2)
    var canConvert: Bool {
        if invoiceId != nil { return true }
        return statusValue == .sent || statusValue == .accepted
    }

    /// Build/store the quote PDF (spec §3): save + flush so the quote exists server-side,
    /// then POST /quotes/:id/pdf. Persists pdfUrl/number/pdfR2Key locally. NO status change.
    func generatePdf(api: APIClient) async -> Bool {
        guard let qid = quoteId else { return false }
        errorMessage = nil
        saveDraft()
        isSending = true
        defer { isSending = false }
        await sync.flush()
        do {
            let r = try await api.generateQuotePdf(qid)
            pdfUrl = r.pdfUrl
            if let n = r.number { number = n }
            if let quote = fetchQuote(qid) {
                if let n = r.number { quote.number = n }
                quote.updatedAt = Epoch.nowMs()
                try? context.save()
                sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
                pdfR2Key = quote.pdfR2Key   // pull will carry the persisted key
            }
            return true
        } catch let e as APIError {
            errorMessage = e.message
            return false
        } catch {
            errorMessage = "Couldn’t build the PDF. Try again."
            return false
        }
    }

    /// Client-side clone of this quote into a DRAFT invoice (spec §4.2). Idempotent:
    /// if the quote already links an invoice, returns that id (caller re-opens it).
    /// Returns nil when not eligible. Persists + enqueues the invoice and its lines,
    /// and links the quote → invoice (both ways), enqueuing the quote upsert.
    @discardableResult
    func convertToInvoice() -> String? {
        guard let qid = quoteId, let quote = fetchQuote(qid) else { return nil }
        if let existing = quote.invoiceId { invoiceId = existing; return existing }
        guard canConvert else { return nil }
        saveDraft()   // ensure the quote + lines are persisted before cloning

        let due = Self.dueDatePlus14()
        let t = totals
        let invoice = Invoice(userId: userId, profileId: profileId,
                              quoteId: qid,
                              clientName: clientName, clientEmail: clientEmail,
                              gstEnabled: gstEnabled, gstInclusive: gstInclusive,
                              subtotalCents: t.subtotal, gstCents: t.gst, totalCents: t.total,
                              currency: quote.currency,
                              status: "draft", dueDate: due)
        context.insert(invoice)

        var clonedLines: [InvoiceLineItem] = []
        for (idx, line) in lineItems.enumerated() {
            let cloned = InvoiceLineItem(userId: userId, invoiceId: invoice.id,
                                         itemDescription: line.itemDescription,
                                         quantity: line.quantity, unitPriceCents: line.unitPriceCents,
                                         sortOrder: idx)
            context.insert(cloned)
            clonedLines.append(cloned)
        }

        quote.invoiceId = invoice.id
        quote.status = QuoteStatus.invoiced.rawValue
        quote.updatedAt = Epoch.nowMs()
        try? context.save()

        sync.enqueue(op: "upsert", entityType: .invoice, entity: invoice)
        for line in clonedLines { sync.enqueue(op: "upsert", entityType: .invoiceLineItem, entity: line) }
        sync.enqueue(op: "upsert", entityType: .quote, entity: quote)

        status = quote.status
        invoiceId = invoice.id
        return invoice.id
    }

    /// "YYYY-MM-DD" 14 days from today (UTC), matching the convert default (spec §4.2).
    static func dueDatePlus14() -> String {
        let today = ExportDateFormatter.shared.string(from: Date())
        guard let d = ExportDateFormatter.shared.date(from: today),
              let plus = Calendar(identifier: .gregorian).date(byAdding: .day, value: 14, to: d) else {
            return today
        }
        return ExportDateFormatter.shared.string(from: plus)
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
