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

    /// Localized tax label (GST / Sales tax / GST/HST) for the profile's business currency.
    var taxLabel: String { receiptTaxLabel(for: AppSettings.businessCurrency(profileId: profileId)) }

    /// The active profile's GST rate (basis points), resolved lazily from storage; used
    /// for live totals + snapshotted onto a fresh invoice at save. (spec §3)
    @ObservationIgnored private lazy var profileGstRateBp: Int = {
        fetchProfile(profileId)?.gstRateBp ?? QuoteTotals.defaultRateBp
    }()

    private func fetchProfile(_ id: String) -> Profile? {
        var d = FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first
    }

    private(set) var invoiceId: String?
    /// The invoice's snapshotted GST rate (basis points), loaded from storage. nil until
    /// the first save snapshots `profileGstRateBp` (or convert sets it). (spec §3)
    private(set) var gstRateBp: Int?
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
        InvoiceTotals.compute(lineItems: lineItems, gstEnabled: gstEnabled, gstInclusive: gstInclusive,
                              gstRateBp: gstRateBp ?? profileGstRateBp)
    }

    /// The GST rate (bp) this invoice actually uses: its snapshot, else the profile default.
    var effectiveGstRateBp: Int { gstRateBp ?? profileGstRateBp }
    /// Percent text for the GST line label, e.g. "10", "15", "12.5".
    var gstRatePercentText: String {
        let pct = Double(effectiveGstRateBp) / 100.0
        return pct == pct.rounded() ? String(Int(pct)) : String(pct)
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
            gstRateBp = inv.gstRateBp
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
            gstRateBp = nil
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
        let invoice = fetchInvoice(iid) ?? {
            let x = Invoice(userId: userId, profileId: profileId,
                            currency: AppSettings.businessCurrency(profileId: profileId))
            x.id = iid
            context.insert(x)
            return x
        }()
        // Snapshot the GST rate from the active profile on first save (mirrors the quote
        // editor); keep an existing snapshot (e.g. set by convert) so a re-save never
        // re-rates the invoice. (spec §3)
        if invoice.gstRateBp == nil { invoice.gstRateBp = profileGstRateBp }
        gstRateBp = invoice.gstRateBp
        let t = totals
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
                recordIncome(for: inv)
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

    /// Record an issued invoice as income (user choice: recognize on issue). Creates one
    /// positive (income) Transaction tagged to the invoice. Dedup-guarded by a per-invoice
    /// note marker so a re-issue can't double-count.
    private func recordIncome(for invoice: Invoice) {
        let label = "Invoice \(invoice.number ?? invoice.id)"
        let existing = try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.note == label && $0.source == "invoice" && $0.deletedAt == nil }))
        if let existing, !existing.isEmpty { return }

        let name = (clientName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let txn = Transaction(
            userId: userId, profileId: profileId,
            merchant: name.isEmpty ? label : name,
            catKey: CategoryKey.income.rawValue,
            amountCents: invoice.totalCents,        // positive ⇒ income
            currency: invoice.currency,
            txnDate: invoice.issueDate ?? ExportDateFormatter.shared.string(from: Date()),
            mode: "business",
            note: label,
            gstCents: invoice.gstCents,
            source: "invoice"
        )
        context.insert(txn)

        // Carry the invoice's line items onto the income transaction so it shows the same
        // breakdown (priceCents is the line total, matching how receipt line items read).
        var items: [LineItem] = []
        for (idx, li) in lineItems.enumerated() {
            let item = LineItem(userId: userId, transactionId: txn.id,
                                name: li.itemDescription,
                                priceCents: li.unitPriceCents * li.quantity,
                                quantity: li.quantity, sortOrder: idx)
            context.insert(item)
            items.append(item)
        }
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        for item in items { sync.enqueue(op: "upsert", entityType: .lineItem, entity: item) }
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
