import Testing
import Foundation
@testable import Snapceipt

/// Parity tests for the on-device A/R derivation helper. Mirrors the backend
/// `src/lib/invoiceTotals.ts` boundary set (spec §4.1) — the two MUST stay lock-step.
@Suite("AccountsReceivable")
struct AccountsReceivableTests {

    // MARK: amountPaidCents — Σ of (already non-deleted) payment amounts

    @Test("amountPaid: empty payment set sums to zero")
    func amountPaidEmpty() {
        #expect(AccountsReceivable.amountPaidCents([]) == 0)
    }

    @Test("amountPaid: sums every payment amount")
    func amountPaidSum() {
        let pays = [
            AccountsReceivable.PaymentAmount(amountCents: 3000),
            AccountsReceivable.PaymentAmount(amountCents: 1500),
            AccountsReceivable.PaymentAmount(amountCents: 500),
        ]
        #expect(AccountsReceivable.amountPaidCents(pays) == 5000)
    }

    // MARK: paymentState — paid >= total ; partial > 0 ; else unpaid

    @Test("paymentState: nothing paid is unpaid")
    func unpaid() {
        #expect(AccountsReceivable.paymentState(totalCents: 10_000, paidCents: 0) == .unpaid)
    }

    @Test("paymentState: some-but-not-all paid is partial")
    func partial() {
        #expect(AccountsReceivable.paymentState(totalCents: 10_000, paidCents: 4_000) == .partial)
    }

    @Test("paymentState: exactly the total is paid")
    func paidExact() {
        #expect(AccountsReceivable.paymentState(totalCents: 10_000, paidCents: 10_000) == .paid)
    }

    @Test("paymentState: overpayment is still paid")
    func paidOver() {
        #expect(AccountsReceivable.paymentState(totalCents: 10_000, paidCents: 12_000) == .paid)
    }

    @Test("paymentState: a zero-total invoice is paid even with nothing paid")
    func paidZeroTotal() {
        // paid >= total → 0 >= 0 → paid (matches backend ordering).
        #expect(AccountsReceivable.paymentState(totalCents: 0, paidCents: 0) == .paid)
    }

    // MARK: isOverdue — issued && !paid && dueDate != nil && today > dueDate

    @Test("overdue: issued, unpaid, today strictly after dueDate")
    func overdueAfter() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .unpaid,
                                             dueDate: "2026-07-03", today: "2026-07-04") == true)
    }

    @Test("overdue: on the due date is NOT overdue (strictly after only)")
    func notOverdueOnDueDate() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .unpaid,
                                             dueDate: "2026-07-03", today: "2026-07-03") == false)
    }

    @Test("overdue: before the due date is NOT overdue")
    func notOverdueBefore() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .partial,
                                             dueDate: "2026-07-03", today: "2026-07-02") == false)
    }

    @Test("overdue: partial payment past due IS overdue")
    func overduePartial() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .partial,
                                             dueDate: "2026-07-03", today: "2026-08-01") == true)
    }

    @Test("overdue: a paid invoice past its due date is NOT overdue")
    func notOverduePaidPastDue() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .paid,
                                             dueDate: "2026-07-03", today: "2026-08-01") == false)
    }

    @Test("overdue: draft is never overdue even when past due + unpaid")
    func notOverdueDraft() {
        #expect(AccountsReceivable.isOverdue(status: "draft", paymentState: .unpaid,
                                             dueDate: "2026-07-03", today: "2026-08-01") == false)
    }

    @Test("overdue: void is never overdue")
    func notOverdueVoid() {
        #expect(AccountsReceivable.isOverdue(status: "void", paymentState: .unpaid,
                                             dueDate: "2026-07-03", today: "2026-08-01") == false)
    }

    @Test("overdue: nil dueDate is never overdue")
    func notOverdueNilDueDate() {
        #expect(AccountsReceivable.isOverdue(status: "issued", paymentState: .unpaid,
                                             dueDate: nil, today: "2099-01-01") == false)
    }

    // MARK: end-to-end derive over an Invoice + its Payment rows

    @Test("derive: end-to-end unpaid issued past-due invoice")
    func deriveOverdue() {
        let inv = Invoice(userId: "u1", profileId: "p1", totalCents: 55_000,
                          status: "issued", dueDate: "2026-07-03")
        let r = AccountsReceivable.derive(invoice: inv, payments: [], today: "2026-07-10")
        #expect(r.amountPaidCents == 0)
        #expect(r.paymentState == .unpaid)
        #expect(r.isOverdue == true)
    }

    @Test("derive: partial payments, on due date, not yet overdue")
    func derivePartialOnDue() {
        let inv = Invoice(userId: "u1", profileId: "p1", totalCents: 55_000,
                          status: "issued", dueDate: "2026-07-03")
        let pays = [Payment(userId: "u1", invoiceId: inv.id, amountCents: 20_000, paidOn: "2026-06-30")]
        let r = AccountsReceivable.derive(invoice: inv, payments: pays, today: "2026-07-03")
        #expect(r.amountPaidCents == 20_000)
        #expect(r.paymentState == .partial)
        #expect(r.isOverdue == false)
    }

    @Test("derive: fully paid past due is paid and not overdue")
    func derivePaid() {
        let inv = Invoice(userId: "u1", profileId: "p1", totalCents: 55_000,
                          status: "issued", dueDate: "2026-07-03")
        let pays = [
            Payment(userId: "u1", invoiceId: inv.id, amountCents: 30_000, paidOn: "2026-07-01"),
            Payment(userId: "u1", invoiceId: inv.id, amountCents: 25_000, paidOn: "2026-07-02"),
        ]
        let r = AccountsReceivable.derive(invoice: inv, payments: pays, today: "2026-08-01")
        #expect(r.amountPaidCents == 55_000)
        #expect(r.paymentState == .paid)
        #expect(r.isOverdue == false)
    }

    @Test("derive: soft-deleted payments are excluded from the paid total")
    func deriveExcludesDeleted() {
        let inv = Invoice(userId: "u1", profileId: "p1", totalCents: 55_000,
                          status: "issued", dueDate: "2026-07-03")
        let live = Payment(userId: "u1", invoiceId: inv.id, amountCents: 20_000, paidOn: "2026-07-01")
        let gone = Payment(userId: "u1", invoiceId: inv.id, amountCents: 35_000, paidOn: "2026-07-02")
        gone.deletedAt = Epoch.nowMs()   // soft-deleted → must not count
        let r = AccountsReceivable.derive(invoice: inv, payments: [live, gone], today: "2026-07-10")
        #expect(r.amountPaidCents == 20_000)
        #expect(r.paymentState == .partial)
        #expect(r.isOverdue == true)
    }
}
