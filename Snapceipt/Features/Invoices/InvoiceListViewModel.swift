import Foundation
import SwiftData
import Observation

/// Drives the invoices list (mirror of `QuoteListViewModel`, with the A/R derivation
/// layered on). Partitions the active profile's live invoices into a "Needs attention"
/// group (overdue first, then due within 7 days) and the rest, each newest-first;
/// derives the A/R payment-state badge per row; soft-deletes through the sync seam.
/// Also exposes a static `overdueCount` for the Home bell (spec §4.4).
///
/// Soft framing (spec): overdue is a CLASSIFICATION the VM produces; the VIEW renders
/// it in amber, not red. `@MainActor`; deps injected for deterministic tests (`today`).
@Observable
@MainActor
final class InvoiceListViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored let profileId: String
    @ObservationIgnored private let today: String

    /// Why a row landed in the "Needs attention" group (drives the row's amber accent).
    /// Distinct from `InvoiceBadge` (the payment-state badge), which has no overdue case.
    enum Attention { case overdue, dueSoon }

    struct Row: Identifiable {
        let invoice: Invoice
        let badge: InvoiceBadge
        /// Non-nil only for rows in `needsAttention`.
        let attention: Attention?
        var id: String { invoice.id }
    }

    private(set) var needsAttention: [Row] = []
    private(set) var others: [Row] = []
    /// Date filter: "" = All time (default — a bare VM shows everything), else "YYYY-MM" — matched
    /// against each invoice's issue date (falling back to its created date for drafts). The VIEW owns
    /// the default month selection (current / newest); it sets this and calls reload().
    var monthKey: String = MonthKey.allTime
    /// Months present in the profile's invoices (+ the current month), newest first — the menu
    /// options. Computed over the FULL set in reload() so it stays populated under any filter.
    private(set) var availableMonthKeys: [String] = []
    /// Newest month that has an invoice — for landing the list on recent data on open; nil if none.
    private(set) var newestMonthWithData: String?
    /// True when the profile has ANY invoice (pre-filter) — distinguishes "no invoices yet" from
    /// "none in the selected month" for the empty state.
    private(set) var hasAny: Bool = false

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String,
         today: String = ExportDateFormatter.shared.string(from: Date())) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.profileId = profileId
        self.today = today
        reload()
    }

    func reload() {
        let pid = profileId
        let d = FetchDescriptor<Invoice>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let invoices = (try? context.fetch(d)) ?? []
        // Full-set facts for the month filter, computed BEFORE filtering so the menu options and the
        // snap-to-newest target stay stable regardless of the current selection.
        hasAny = !invoices.isEmpty
        let dayKeys = invoices.map { Self.effectiveDay($0) }
        availableMonthKeys = MonthKey.available(dayKeys)
        newestMonthWithData = MonthKey.newest(dayKeys)
        let soonCutoff = Self.dayOffset(today, days: 7)   // hoisted: due on/before this is "due soon"

        var attnOverdue: [Row] = []
        var attnDueSoon: [Row] = []
        var rest: [Row] = []
        for inv in invoices {
            guard MonthKey.matches(Self.effectiveDay(inv), monthKey) else { continue }   // month filter
            let paid = Self.amountPaidCents(context, invoiceId: inv.id)
            let state = AccountsReceivable.paymentState(totalCents: inv.totalCents, paidCents: paid)
            let overdue = AccountsReceivable.isOverdue(status: inv.status, paymentState: state,
                                                       dueDate: inv.dueDate, today: today)
            if overdue {
                attnOverdue.append(Row(invoice: inv, badge: state, attention: .overdue))
            } else if Self.isDueSoon(status: inv.status, paymentState: state,
                                     dueDate: inv.dueDate, today: today, soonCutoff: soonCutoff) {
                attnDueSoon.append(Row(invoice: inv, badge: state, attention: .dueSoon))
            } else {
                rest.append(Row(invoice: inv, badge: state, attention: nil))
            }
        }
        needsAttention = attnOverdue + attnDueSoon   // each already newest-first (source order)
        others = rest
    }

    /// The day-string the date filter keys off: the issue date (the tax-invoice date), falling back
    /// to the created date for drafts (issueDate == nil) so a draft isn't hidden by the filter.
    static func effectiveDay(_ inv: Invoice) -> String {
        inv.issueDate ?? MonthKey.localDay(inv.createdAt)
    }

    func badge(for invoice: Invoice) -> InvoiceBadge {
        let paid = Self.amountPaidCents(context, invoiceId: invoice.id)
        return AccountsReceivable.paymentState(totalCents: invoice.totalCents, paidCents: paid)
    }

    /// Soft-delete (set deletedAt) + enqueue a delete. (Line items / payments tombstone
    /// with the invoice server-side; local child rows are orphaned harmlessly.)
    func delete(_ invoice: Invoice) {
        invoice.deletedAt = Epoch.nowMs()
        invoice.updatedAt = Epoch.nowMs()
        try? context.save()
        reload()
        sync.enqueue(op: "delete", entityType: .invoice, entity: invoice)
    }

    /// Σ of the invoice's non-deleted payment amounts.
    static func amountPaidCents(_ context: ModelContext, invoiceId: String) -> Int {
        let iid = invoiceId
        let d = FetchDescriptor<Payment>(
            predicate: #Predicate { $0.invoiceId == iid && $0.deletedAt == nil })
        let amounts = ((try? context.fetch(d)) ?? []).map { AccountsReceivable.PaymentAmount(amountCents: $0.amountCents) }
        return AccountsReceivable.amountPaidCents(amounts)
    }

    /// Count of overdue invoices for the profile (drives the Home bell, spec §4.4).
    static func overdueCount(context: ModelContext, profileId: String, today: String) -> Int {
        let pid = profileId
        let d = FetchDescriptor<Invoice>(
            predicate: #Predicate { $0.profileId == pid && $0.deletedAt == nil })
        let invoices = (try? context.fetch(d)) ?? []
        return invoices.reduce(0) { acc, inv in
            let paid = amountPaidCents(context, invoiceId: inv.id)
            let state = AccountsReceivable.paymentState(totalCents: inv.totalCents, paidCents: paid)
            return acc + (AccountsReceivable.isOverdue(status: inv.status, paymentState: state,
                                                       dueDate: inv.dueDate, today: today) ? 1 : 0)
        }
    }

    /// Due-soon: an issued, not-fully-paid invoice with a due date that is NOT yet overdue
    /// (i.e. today <= dueDate) but falls on/before `today + 7 days`. Mirrors `isOverdue`'s
    /// guards; the caller has already excluded overdue rows.
    private static func isDueSoon(status: String, paymentState: AccountsReceivable.PaymentState,
                                  dueDate: String?, today: String, soonCutoff: String) -> Bool {
        guard let dueDate else { return false }
        guard status == "issued", paymentState != .paid else { return false }
        // Strings are "YYYY-MM-DD" → lexicographic compare == chronological.
        return today <= dueDate && dueDate <= soonCutoff
    }

    /// `iso` ("YYYY-MM-DD") shifted by `days` whole days, in UTC. Mirrors
    /// `QuoteEditorViewModel.dueDatePlus14`. Falls back to the input on parse failure.
    private static func dayOffset(_ iso: String, days: Int) -> String {
        guard let d = ExportDateFormatter.shared.date(from: iso) else { return iso }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let shifted = cal.date(byAdding: .day, value: days, to: d) else { return iso }
        return ExportDateFormatter.shared.string(from: shifted)
    }
}
