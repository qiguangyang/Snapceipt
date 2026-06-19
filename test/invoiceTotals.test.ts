import { describe, expect, it } from "vitest";
import {
  amountPaidCents,
  paymentState,
  isOverdue,
  type PaymentAmount,
} from "../src/lib/invoiceTotals";

describe("amountPaidCents", () => {
  it("sums payment amounts", () => {
    const ps: PaymentAmount[] = [{ amountCents: 5000 }, { amountCents: 2500 }, { amountCents: 100 }];
    expect(amountPaidCents(ps)).toBe(7600);
  });

  it("returns 0 for no payments", () => {
    expect(amountPaidCents([])).toBe(0);
  });
});

describe("paymentState", () => {
  it("is unpaid when nothing is paid", () => {
    expect(paymentState(115500, 0)).toBe("unpaid");
  });

  it("is partial when some (but not all) is paid", () => {
    expect(paymentState(115500, 50000)).toBe("partial");
  });

  it("is paid when the full total is paid", () => {
    expect(paymentState(115500, 115500)).toBe("paid");
  });

  it("is paid when overpaid (amountPaid > total)", () => {
    expect(paymentState(115500, 120000)).toBe("paid");
  });

  it("treats a zero-total invoice as paid (degenerate but consistent)", () => {
    expect(paymentState(0, 0)).toBe("paid");
  });
});

describe("isOverdue", () => {
  const base = { status: "issued", paymentState: "unpaid" as const, dueDate: "2026-06-15" };

  it("is overdue when issued, unpaid, and today is past the due date", () => {
    expect(isOverdue({ ...base, today: "2026-06-16" })).toBe(true);
  });

  it("is NOT overdue on the due date itself (boundary)", () => {
    expect(isOverdue({ ...base, today: "2026-06-15" })).toBe(false);
  });

  it("is NOT overdue before the due date", () => {
    expect(isOverdue({ ...base, today: "2026-06-14" })).toBe(false);
  });

  it("is NOT overdue when fully paid even if past due", () => {
    expect(isOverdue({ ...base, paymentState: "paid", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue for a draft invoice", () => {
    expect(isOverdue({ ...base, status: "draft", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue for a void invoice", () => {
    expect(isOverdue({ ...base, status: "void", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue when there is no due date", () => {
    expect(isOverdue({ ...base, dueDate: null, today: "2026-07-01" })).toBe(false);
  });

  it("a partially-paid past-due invoice is overdue", () => {
    expect(isOverdue({ ...base, paymentState: "partial", today: "2026-06-16" })).toBe(true);
  });
});
