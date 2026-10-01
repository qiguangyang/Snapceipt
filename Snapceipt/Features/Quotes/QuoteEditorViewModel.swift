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
    @ObservationIgnored private let persist: (ModelContext) throws -> Void
    @ObservationIgnored let profileId: String

    /// Localized tax label (GST / Sales tax / GST/HST) for the profile's business currency.
    var taxLabel: String { receiptTaxLabel(for: AppSettings.businessCurrency(profileId: profileId)) }

    /// The active profile's GST rate (basis points), resolved lazily from storage; used
    /// for live totals + snapshotted onto the quote at save. (spec §3)
    @ObservationIgnored private lazy var profileGstRateBp: Int = {
        fetchProfile(profileId)?.gstRateBp ?? QuoteTotals.defaultRateBp
    }()

    private func fetchProfile(_ id: String) -> Profile? {
        let uid = userId
        var d = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id && $0.userId == uid })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    /// Active profile, fetched once — backs the read-only business/bank preview shown on
    /// the quote (the same details the client sees on the hosted quote). Edited in Tax & GST.
    @ObservationIgnored private lazy var activeProfile: Profile? = fetchProfile(profileId)
    private func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    var businessName: String? { clean(activeProfile?.name) }
    var businessAbn: String? { clean(activeProfile?.abn) }
    var businessEmail: String? { clean(activeProfile?.businessEmail) }
    var businessPhone: String? { clean(activeProfile?.phone) }
    var businessWebsite: String? { clean(activeProfile?.website) }
    var businessAddress: String? { clean(activeProfile?.addressText) }
    var bankDetails: String? { clean(activeProfile?.bankDetails) }
    /// Any business-contact field set (name alone doesn't count — it always exists).
    var hasBusinessContact: Bool {
        [businessAbn, businessEmail, businessPhone, businessWebsite, businessAddress].contains { $0 != nil }
    }

    private(set) var quoteId: String?
    /// The quote's snapshotted GST rate (basis points), loaded from storage. nil until
    /// the first save snapshots `profileGstRateBp` onto the quote. (spec §3)
    private(set) var gstRateBp: Int?
    var lineItems: [QuoteLineItem] = []
    var gstEnabled = true
    /// When true (and `gstEnabled`), entered prices already include GST — see
    /// `QuoteTotals.compute`. Only meaningful while `gstEnabled`.
    var gstInclusive = false
    private(set) var clientId: String?
    private(set) var clientName: String?
    private(set) var clientEmail: String?
    /// Snapshot of the picked client's freeform address (mirrors clientName/clientEmail);
    /// rendered in the bill-to preview and on the hosted quote when non-empty.
    private(set) var clientAddress: String?
    /// Snapshot of the picked client's mobile phone (mirrors clientAddress); rendered on the
    /// hosted quote when non-empty.
    private(set) var clientMobile: String?

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

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         persist: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.persist = persist
        self.profileId = profileId
    }

    var statusValue: QuoteStatus? { QuoteStatus(rawValue: status) }

    var totals: (subtotal: Int, gst: Int, total: Int) {
        QuoteTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled,
                            gstInclusive: gstInclusive, gstRateBp: gstRateBp ?? profileGstRateBp)
    }

    /// The GST rate (bp) this quote actually uses: its snapshot, else the profile default.
    var effectiveGstRateBp: Int { gstRateBp ?? profileGstRateBp }
    /// Percent text for the GST line label, e.g. "10", "15", "12.5".
    var gstRatePercentText: String {
        let pct = Double(effectiveGstRateBp) / 100.0
        return pct == pct.rounded() ? String(Int(pct)) : String(pct)
    }

    var canSend: Bool {
        !(clientName ?? "").trimmingCharacters(in: .whitespaces).isEmpty && !lineItems.isEmpty
    }

    /// "Save Draft" is worth enabling once the quote has a client OR at least one line item —
    /// keeps a completely empty shell quote from being persisted and cluttering the Quotes list.
    var canSaveDraft: Bool {
        !(clientName ?? "").trimmingCharacters(in: .whitespaces).isEmpty || !lineItems.isEmpty
    }

    var displayNumber: String { number ?? "Draft" }

    func load(id: String?) {
        if let id, let q = fetchQuote(id) {
            quoteId = q.id
            gstEnabled = q.gstEnabled
            gstInclusive = q.gstInclusive
            clientId = q.clientId
            clientName = q.clientName
            clientEmail = q.clientEmail
            clientAddress = q.clientAddress
            clientMobile = q.clientMobile
            number = q.number
            status = q.status
            sentAt = q.sentAt
            validUntil = q.validUntil
            pdfR2Key = q.pdfR2Key
            invoiceId = q.invoiceId
            gstRateBp = q.gstRateBp
            let qid = q.id
            let uid = userId
            let d = FetchDescriptor<QuoteLineItem>(
                predicate: #Predicate { $0.quoteId == qid && $0.userId == uid && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
            lineItems = (try? context.fetch(d)) ?? []
            originalLineIds = Set(lineItems.map(\.id))
        } else {
            quoteId = ID.uuidv7()
            gstEnabled = true
            gstInclusive = false
            clientId = nil
            clientName = nil
            clientEmail = nil
            clientAddress = nil
            clientMobile = nil
            number = nil
            status = QuoteStatus.draft.rawValue
            sentAt = nil
            validUntil = Self.validUntilPlus28()   // new quotes are valid for 28 days
            pdfR2Key = nil
            invoiceId = nil
            gstRateBp = nil
            lineItems = []
            originalLineIds = []
        }
    }

    func setClient(name: String, email: String?, mobile: String? = nil, address: String? = nil) {
        clientId = nil
        clientName = name
        clientEmail = email
        clientMobile = mobile
        clientAddress = address
    }

    func setClient(_ selection: ClientSelection) {
        clientId = selection.id
        clientName = selection.name
        clientEmail = selection.email
        clientMobile = selection.mobilePhone
        clientAddress = selection.address
    }

    /// Append a blank line item. Returns the new line's id so the editor can move keyboard
    /// focus to its Description field (nil only if there's no draft quote to attach it to).
    @discardableResult
    func addLine() -> String? {
        guard let qid = quoteId else { return nil }
        let line = QuoteLineItem(userId: userId, quoteId: qid,
                                 itemDescription: "", quantity: 1, unitPriceCents: 0,
                                 sortOrder: lineItems.count)
        lineItems.append(line)
        return line.id
    }

    func removeLine(_ line: QuoteLineItem) {
        lineItems.removeAll { $0.id == line.id }
    }

    @discardableResult
    func saveDraft() -> Bool {
        errorMessage = nil
        guard let qid = quoteId else { return false }
        let existing = fetchQuote(qid)
        guard validClientLink(clientId, previousId: existing?.clientId) else {
            errorMessage = "Select a live client in this business."
            return false
        }
        let quote = existing ?? {
            let q = Quote(userId: userId, profileId: profileId,
                          currency: AppSettings.businessCurrency(profileId: profileId))
            q.id = qid
            context.insert(q)
            return q
        }()
        quote.profileId = profileId
        // Snapshot the GST rate from the active profile on first save; keep an existing
        // snapshot so a re-save never re-rates an already-sent quote. (spec §2.2/§3)
        if quote.gstRateBp == nil { quote.gstRateBp = profileGstRateBp }
        gstRateBp = quote.gstRateBp
        let t = totals
        quote.clientId = clientId
        quote.clientName = clientName
        quote.clientEmail = clientEmail
        quote.clientAddress = clientAddress
        quote.clientMobile = clientMobile
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
        do { try persist(context) }
        catch {
            context.rollback()
            errorMessage = "Couldn’t save the draft. Try again."
            return false
        }

        sync.enqueue(op: "upsert", entityType: .quote, entity: quote)
        for line in lineItems { sync.enqueue(op: "upsert", entityType: .quoteLineItem, entity: line) }
        for row in deletedRows { sync.enqueue(op: "delete", entityType: .quoteLineItem, entity: row) }
        originalLineIds = keptIds
        return true
    }

    func send(api: APIClient) async -> Bool {
        guard let qid = quoteId else { return false }
        errorMessage = nil
        guard saveDraft() else { return false }
        isSending = true
        defer { isSending = false }
        // The send route loads the quote from D1 (it was only just enqueued locally
        // by saveDraft). Push the outbox first so the quote + its line items exist
        // server-side before we ask the backend to mint/number/PDF/email it — without
        // this, a never-synced draft 404s as "Quote not found for this user".
        await sync.flush()
        do {
            let r = try await api.sendQuote(qid)
            // The send response now carries only {url, emailed, number}; status/totals are
            // persisted server-side and synced via /sync (NOT returned here). Apply the
            // link + email status + minted number, and set status locally. (spec §4)
            pdfUrl = r.url
            emailed = r.emailed
            if let n = r.number { number = n }
            status = QuoteStatus.sent.rawValue
            let sentNow = Epoch.nowMs()
            sentAt = sentNow
            if let quote = fetchQuote(qid) {
                if let n = r.number { quote.number = n }
                quote.status = QuoteStatus.sent.rawValue
                quote.sentAt = sentNow
                quote.updatedAt = sentNow
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

    /// Convert is offered once a quote is sent/accepted (hidden while it's still a Draft),
    /// or whenever an invoice already exists (re-open it). (spec §4.2)
    var canConvert: Bool {
        if invoiceId != nil { return true }
        return statusValue == .sent || statusValue == .accepted
    }

    /// Mint (or re-mint) the hosted HTML quote link for the Share action (spec §4).
    /// Saves + flushes so the quote exists server-side, then POST /quotes/:id/link.
    /// Applies the minted number to the local quote so "Quote #N" displays immediately.
    func shareLink(api: APIClient) async -> String? {
        guard let qid = quoteId else { return nil }
        errorMessage = nil
        guard saveDraft() else { return nil }
        isSending = true
        defer { isSending = false }
        await sync.flush()
        do {
            let r = try await api.quoteShareLink(qid)
            pdfUrl = r.url
            // Sharing the link issues the quote (spec §4): apply the server-minted number
            // AND move it out of Draft → Sent so it becomes eligible to convert to an invoice.
            let now = Epoch.nowMs()
            if let n = r.number, number == nil { number = n }
            if statusValue == .draft {
                status = QuoteStatus.sent.rawValue
                if sentAt == nil { sentAt = now }
            }
            if let q = fetchQuote(qid) {
                if let n = r.number, q.number == nil { q.number = n }
                if QuoteStatus(rawValue: q.status) == .draft {
                    q.status = QuoteStatus.sent.rawValue
                    if q.sentAt == nil { q.sentAt = now }
                }
                q.updatedAt = now
                try? context.save()
                sync.enqueue(op: "upsert", entityType: .quote, entity: q)
            }
            return r.url
        } catch let e as APIError {
            errorMessage = e.message
            return nil
        } catch {
            errorMessage = "Couldn’t create the link. Try again."
            return nil
        }
    }

    /// Generate the on-device PDF (spec §4): mint the link, then render it in a hidden
    /// WKWebView and return the temp PDF file URL for sharing.
    func generatePdf(api: APIClient, renderer: QuotePdfRenderer) async -> URL? {
        guard let urlString = await shareLink(api: api), let url = URL(string: urlString) else { return nil }
        isSending = true
        defer { isSending = false }
        do {
            let name = "Quote-\(number ?? "draft")"
            return try await renderer.renderPDF(from: url, fileName: name)
        } catch {
            errorMessage = "Couldn’t build the PDF. Try again."
            return nil
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
        guard quote.status == QuoteStatus.sent.rawValue || quote.status == QuoteStatus.accepted.rawValue else { return nil }
        guard validClientLink(quote.clientId, previousId: nil) else {
            errorMessage = "Select a live client in this business before creating an invoice."
            return nil
        }
        let uid = userId
        let descriptor = FetchDescriptor<QuoteLineItem>(
            predicate: #Predicate { $0.quoteId == qid && $0.userId == uid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        guard let sourceLines = try? context.fetch(descriptor) else {
            errorMessage = "Couldn’t load the quote items. Try again."
            return nil
        }

        let due = Self.dueDatePlus14()
        let invoice = Invoice(userId: userId, profileId: profileId,
                              quoteId: qid,
                              clientId: quote.clientId,
                              clientName: quote.clientName, clientEmail: quote.clientEmail,
                              gstEnabled: quote.gstEnabled, gstInclusive: quote.gstInclusive,
                              subtotalCents: quote.subtotalCents, gstCents: quote.gstCents, totalCents: quote.totalCents,
                              currency: quote.currency,
                              status: "draft", dueDate: due,
                              // Snapshot the quote's GST rate onto the invoice so it stays
                              // consistent with the quote it came from (spec §3).
                              gstRateBp: quote.gstRateBp)
        context.insert(invoice)

        var clonedLines: [InvoiceLineItem] = []
        for (idx, line) in sourceLines.enumerated() {
            let cloned = InvoiceLineItem(userId: userId, invoiceId: invoice.id,
                                         itemDescription: line.itemDescription,
                                         unitLabel: line.unitLabel,
                                         quantity: line.quantity, unitPriceCents: line.unitPriceCents,
                                         sortOrder: idx)
            context.insert(cloned)
            clonedLines.append(cloned)
        }

        quote.invoiceId = invoice.id
        quote.status = QuoteStatus.invoiced.rawValue
        quote.updatedAt = Epoch.nowMs()
        do { try persist(context) }
        catch {
            context.rollback()
            errorMessage = "Couldn’t create the invoice. Try again."
            return nil
        }

        sync.enqueue(op: "upsert", entityType: .invoice, entity: invoice)
        for line in clonedLines { sync.enqueue(op: "upsert", entityType: .invoiceLineItem, entity: line) }
        sync.enqueue(op: "upsert", entityType: .quote, entity: quote)

        status = quote.status
        invoiceId = invoice.id
        return invoice.id
    }

    /// "YYYY-MM-DD" `days` from today (UTC). Falls back to today on a parse failure.
    static func dateString(daysFromNow days: Int) -> String {
        let today = ExportDateFormatter.shared.string(from: Date())
        guard let d = ExportDateFormatter.shared.date(from: today),
              let plus = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: d) else {
            return today
        }
        return ExportDateFormatter.shared.string(from: plus)
    }

    /// "YYYY-MM-DD" 14 days from today (UTC) — the invoice convert/due default (spec §4.2).
    static func dueDatePlus14() -> String { dateString(daysFromNow: 14) }

    /// "YYYY-MM-DD" 28 days from today (UTC) — the default quote validity.
    static func validUntilPlus28() -> String { dateString(daysFromNow: 28) }

    private func validClientLink(_ candidate: String?, previousId: String?) -> Bool {
        guard let clientId = candidate else { return true }
        // Historical documents may keep their unchanged link after deletion.
        if clientId == previousId { return true }
        let uid = userId, pid = profileId
        let descriptor = FetchDescriptor<Client>(predicate: #Predicate {
            $0.id == clientId && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil
        })
        return (try? context.fetch(descriptor).isEmpty) == false
    }

    private func fetchQuote(_ id: String) -> Quote? {
        let uid = userId, pid = profileId
        var d = FetchDescriptor<Quote>(predicate: #Predicate { $0.id == id && $0.userId == uid && $0.profileId == pid && $0.deletedAt == nil })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func fetchLine(_ id: String) -> QuoteLineItem? {
        guard let parentId = quoteId, fetchQuote(parentId) != nil else { return nil }
        let uid = userId
        var d = FetchDescriptor<QuoteLineItem>(predicate: #Predicate { $0.id == id && $0.userId == uid && $0.quoteId == parentId })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
