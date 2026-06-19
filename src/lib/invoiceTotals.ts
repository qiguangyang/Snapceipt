/**
 * Derived accounts-receivable helpers (spec §4.1). PURE — no DB, no I/O. The iOS
 * app computes the IDENTICAL formula on-device for badges; the issue/send routes
 * and the PDF builder reuse these on the server. Keep the two in lock-step.
 *
 * Money in cents; dates are "YYYY-MM-DD" (lexicographic compare == chronological).
 *   amountPaidCents = Σ non-deleted Payment.amountCents.
 *   paymentState    = paid (amountPaid >= total) | partial (amountPaid > 0) | unpaid.
 *   isOverdue       = status==issued && paymentState!=paid && today > dueDate.
 */

/** The single amount needed per payment to derive A/R state. */
export interface PaymentAmount {
  amountCents: number;
}

export type PaymentState = "unpaid" | "partial" | "paid";

/** Σ of the (already non-deleted) payment amounts. */
export function amountPaidCents(payments: PaymentAmount[]): number {
  let sum = 0;
  for (const p of payments) sum += p.amountCents;
  return sum;
}

/** Derive the payment state from the invoice total and the amount paid. */
export function paymentState(totalCents: number, paidCents: number): PaymentState {
  if (paidCents >= totalCents) return "paid";
  if (paidCents > 0) return "partial";
  return "unpaid";
}

/**
 * An invoice is overdue when it is issued, not fully paid, has a due date, and
 * today is strictly past that due date. `today` and `dueDate` are "YYYY-MM-DD"
 * strings, which compare correctly with `>`.
 */
export function isOverdue(args: {
  status: string;
  paymentState: PaymentState;
  dueDate: string | null;
  today: string;
}): boolean {
  return (
    args.status === "issued" &&
    args.paymentState !== "paid" &&
    args.dueDate != null &&
    args.today > args.dueDate
  );
}
