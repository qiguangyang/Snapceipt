import Foundation

/// Pure on-device accounts-receivable derivation (spec §4.1). Identical formula to
/// the backend `src/lib/invoiceTotals.ts`, golden-locked — keep the two in lock-step.
/// No SwiftData fetch, no hidden `Date()`; every input is passed in so the helper is
/// deterministic + trivially unit-testable (mirrors `BasEngine`/`QuoteTotals`).
///
/// Money in cents; dates are "YYYY-MM-DD" (lexicographic compare == chronological).
///   amountPaidCents = Σ non-deleted Payment.amountCents.
///   paymentState    = paid (amountPaid >= total) | partial (amountPaid > 0) | unpaid.
///   isOverdue       = status == issued && paymentState != paid && today > dueDate.
enum AccountsReceivable {

    /// The single amount needed per payment to derive A/R state (decoupled from the
    /// `Payment` @Model so the math stays pure). Mirrors the backend `PaymentAmount`.
    struct PaymentAmount: Equatable {
        let amountCents: Int
    }

    enum PaymentState: String, Equatable {
        case unpaid, partial, paid
    }

    /// The full derived A/R snapshot for one invoice.
    struct Derived: Equatable {
        let amountPaidCents: Int
        let paymentState: PaymentState
        let isOverdue: Bool
    }

    /// Σ of the (already non-deleted) payment amounts.
    static func amountPaidCents(_ payments: [PaymentAmount]) -> Int {
        payments.reduce(0) { $0 + $1.amountCents }
    }

    /// Derive the payment state from the invoice total and the amount paid. Order
    /// matters: a fully-paid (incl. zero-total) invoice resolves to `paid` first.
    static func paymentState(totalCents: Int, paidCents: Int) -> PaymentState {
        if paidCents >= totalCents { return .paid }
        if paidCents > 0 { return .partial }
        return .unpaid
    }

    /// An invoice is overdue when it is issued, not fully paid, has a due date, and
    /// today is STRICTLY past that due date (on-due-date is not overdue). `today` and
    /// `dueDate` are "YYYY-MM-DD" strings, which compare correctly with `>`.
    static func isOverdue(status: String, paymentState: PaymentState,
                          dueDate: String?, today: String) -> Bool {
        guard let dueDate else { return false }
        return status == "issued" && paymentState != .paid && today > dueDate
    }

    /// End-to-end derivation over an `Invoice` and its `Payment` rows. Filters out
    /// soft-deleted payments here so callers can pass the raw relationship set.
    static func derive(invoice: Invoice, payments: [Payment], today: String) -> Derived {
        let live = payments
            .filter { $0.deletedAt == nil }
            .map { PaymentAmount(amountCents: $0.amountCents) }
        let paid = amountPaidCents(live)
        let state = paymentState(totalCents: invoice.totalCents, paidCents: paid)
        let overdue = isOverdue(status: invoice.status, paymentState: state,
                                dueDate: invoice.dueDate, today: today)
        return Derived(amountPaidCents: paid, paymentState: state, isOverdue: overdue)
    }
}
