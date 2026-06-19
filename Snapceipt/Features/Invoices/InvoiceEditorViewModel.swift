import Foundation
import SwiftData
import Observation

/// The A/R badge surfaced by the invoice editor. Reuses the pure on-device payment
/// state from `AccountsReceivable` so the VM and the helper stay in lock-step (spec §4.4).
typealias InvoiceBadge = AccountsReceivable.PaymentState

/// Drives the invoice editor (near-mirror of `QuoteEditorViewModel`). Owns a draft
/// invoice id, a working line-item set, GST toggles, the client snapshot, and an
/// editable due date; computes live totals via `InvoiceTotals`; persists via
/// `saveDraft()` (invoice upsert + per-line diff/enqueue) and finalizes via
/// `issue(api:)` (POST /invoices/:id/issue). `@MainActor`; deps injected for tests.
@Observable
@MainActor
final class InvoiceEditorViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String

    private(set) var invoiceId: String?
    var lineItems: [InvoiceLineItem] = []
    var gstEnabled = true
    var gstInclusive = false
    var dueDate: String = QuoteEditorViewModel.dueDatePlus14()
    private(set) var clientName: String?
    private(set) var clientEmail: String?

    private(set) var number: String?
    private(set) var status: String = "draft"
    private(set) var quoteId: String?
    private(set) var pdfUrl: String?
    private(set) var issuedAt: Int?
    private(set) var emailed = false

    private(set) var isIssuing = false
    var errorMessage: String?

    @ObservationIgnored private var originalLineIds: Set<String> = []

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
    }

    var totals: (subtotal: Int, gst: Int, total: Int) {
        InvoiceTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled, gstInclusive: gstInclusive)
    }

    var canIssue: Bool {
        status == "draft"
            && !(clientName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && !lineItems.isEmpty
    }

    var statusValue: String { status }
    var displayNumber: String { number ?? "Draft" }

    /// Derived A/R badge over the invoice's non-deleted payments (spec §4.1/§4.4).
    var badge: InvoiceBadge {
        let paid = AccountsReceivable.amountPaidCents(loadedPaymentAmounts())
        return AccountsReceivable.paymentState(totalCents: totals.total, paidCents: paid)
    }

    func load(id: String?) {
        if let id, let inv = fetchInvoice(id) {
            invoiceId = inv.id
            gstEnabled = inv.gstEnabled
            gstInclusive = inv.gstInclusive
            clientName = inv.clientName
            clientEmail = inv.clientEmail
            number = inv.number
            status = inv.status
            quoteId = inv.quoteId
            issuedAt = inv.issuedAt
            pdfUrl = nil
            dueDate = inv.dueDate ?? QuoteEditorViewModel.dueDatePlus14()
            let iid = inv.id
            let d = FetchDescriptor<InvoiceLineItem>(
                predicate: #Predicate { $0.invoiceId == iid && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
            lineItems = (try? context.fetch(d)) ?? []
            originalLineIds = Set(lineItems.map(\.id))
        } else {
            invoiceId = ID.uuidv7()
            gstEnabled = true
            gstInclusive = false
            clientName = nil
            clientEmail = nil
            number = nil
            status = "draft"
            quoteId = nil
            issuedAt = nil
            pdfUrl = nil
            dueDate = QuoteEditorViewModel.dueDatePlus14()
            lineItems = []
            originalLineIds = []
        }
    }

    func setClient(name: String, email: String?) {
        clientName = name
        clientEmail = email
    }

    func setDueDate(_ iso: String) { dueDate = iso }

    func addLine() {
        guard let iid = invoiceId else { return }
        lineItems.append(InvoiceLineItem(userId: userId, invoiceId: iid,
                                         itemDescription: "", quantity: 1, unitPriceCents: 0,
                                         sortOrder: lineItems.count))
    }

    func removeLine(_ line: InvoiceLineItem) {
        lineItems.removeAll { $0.id == line.id }
    }

    func saveDraft() {
        guard let iid = invoiceId else { return }
        let t = totals
        let invoice = fetchInvoice(iid) ?? {
            let x = Invoice(userId: userId, profileId: profileId)
            x.id = iid
            context.insert(x)
            return x
        }()
        invoice.profileId = profileId
        invoice.quoteId = quoteId
        invoice.clientName = clientName
        invoice.clientEmail = clientEmail
        invoice.gstEnabled = gstEnabled
        invoice.gstInclusive = gstInclusive
        invoice.subtotalCents = t.subtotal
        invoice.gstCents = t.gst
        invoice.totalCents = t.total
        invoice.dueDate = dueDate
        invoice.updatedAt = Epoch.nowMs()

        let keptIds = Set(lineItems.map(\.id))
        for (idx, line) in lineItems.enumerated() {
            line.sortOrder = idx
            line.updatedAt = Epoch.nowMs()
            if fetchLine(line.id) == nil { context.insert(line) }
        }
        let removed = originalLineIds.subtracting(keptIds)
        var deletedRows: [InvoiceLineItem] = []
        for rid in removed {
            if let row = fetchLine(rid) {
                row.deletedAt = Epoch.nowMs()
                row.updatedAt = Epoch.nowMs()
                deletedRows.append(row)
            }
        }
        try? context.save()

        sync.enqueue(op: "upsert", entityType: .invoice, entity: invoice)
        for line in lineItems { sync.enqueue(op: "upsert", entityType: .invoiceLineItem, entity: line) }
        for row in deletedRows { sync.enqueue(op: "delete", entityType: .invoiceLineItem, entity: row) }
        originalLineIds = keptIds
    }

    /// Finalize: save + flush so the draft exists server-side, then POST
    /// /invoices/:id/issue. Applies number/status/dates/totals + pdf url.
    func issue(api: APIClient) async -> Bool {
        guard let iid = invoiceId else { return false }
        errorMessage = nil
        saveDraft()
        isIssuing = true
        defer { isIssuing = false }
        // The issue route loads the invoice from D1 (it was only just enqueued locally
        // by saveDraft). Push the outbox first so the invoice + its line items exist
        // server-side before we ask the backend to mint/number/PDF it.
        await sync.flush()
        do {
            let r = try await api.issueInvoice(iid)
            number = r.number
            status = r.status
            pdfUrl = r.pdfUrl
            issuedAt = r.issuedAt
            dueDate = r.dueDate ?? dueDate
            if let inv = fetchInvoice(iid) {
                inv.number = r.number
                inv.status = r.status
                inv.issueDate = r.issueDate
                inv.dueDate = r.dueDate ?? inv.dueDate
                inv.issuedAt = r.issuedAt
                inv.subtotalCents = r.subtotalCents
                inv.gstCents = r.gstCents
                inv.totalCents = r.totalCents
                inv.updatedAt = Epoch.nowMs()
                try? context.save()
                sync.enqueue(op: "upsert", entityType: .invoice, entity: inv)
            }
            return true
        } catch let e as APIError {
            errorMessage = e.message
            return false
        } catch {
            errorMessage = "Couldn’t issue the invoice. Try again."
            return false
        }
    }

    /// Email the issued invoice's tax-invoice PDF to the client (POST /invoices/:id/send).
    /// Mirrors `issue(api:)`'s error handling so a backend failure (e.g. 400 "no client
    /// email") surfaces via `errorMessage` instead of silently no-oping.
    func send(api: APIClient) async -> Bool {
        guard let iid = invoiceId else { return false }
        errorMessage = nil
        do {
            let r = try await api.sendInvoice(iid)
            if let url = r.pdfUrl { pdfUrl = url }
            emailed = r.emailed
            return true
        } catch let e as APIError {
            errorMessage = e.message
            return false
        } catch {
            errorMessage = "Couldn’t send the invoice. Try again."
            return false
        }
    }

    private func loadedPaymentAmounts() -> [AccountsReceivable.PaymentAmount] {
        guard let iid = invoiceId else { return [] }
        let d = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.invoiceId == iid && $0.deletedAt == nil })
        return ((try? context.fetch(d)) ?? []).map { AccountsReceivable.PaymentAmount(amountCents: $0.amountCents) }
    }

    private func fetchInvoice(_ id: String) -> Invoice? {
        var d = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private func fetchLine(_ id: String) -> InvoiceLineItem? {
        var d = FetchDescriptor<InvoiceLineItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }
}
