import { describe, it, expect } from "vitest";
import {
  invoiceEntity,
  invoiceLineItemEntity,
  paymentEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";
import { SYNCABLE_TABLES } from "../src/lib/syncTables";

const UID = "0190f8a0-1111-7000-8000-000000000001";
const PID = "0190f8a0-2222-7000-8000-000000000002";
const EID = "0190f8a0-3333-7000-8000-000000000003";
const DID = "0190f8a0-4444-7000-8000-000000000004";
const INV = "0190f8a0-5555-7000-8000-000000000005";

function env(overrides: Record<string, unknown> = {}) {
  return {
    id: EID,
    userId: UID,
    profileId: PID,
    createdAt: 1748563200000,
    updatedAt: 1748563200000,
    deletedAt: null,
    rev: 1,
    lastEditedDeviceId: DID,
    ...overrides,
  };
}

describe("invoiceEntity", () => {
  it("accepts a full invoice payload with integer cents + dates", () => {
    const r = invoiceEntity.safeParse(
      env({
        type: "invoice",
        number: "INV-0001",
        quoteId: INV,
        clientName: "Jane Roe",
        clientEmail: "jane@example.com",
        gstEnabled: true,
        gstInclusive: false,
        subtotalCents: 105000,
        gstCents: 10500,
        totalCents: 115500,
        currency: "AUD",
        status: "issued",
        issueDate: "2026-06-19",
        dueDate: "2026-07-03",
        issuedAt: 1748563200000,
        pdfR2Key: "u/invoices/x.pdf",
      }),
    );
    expect(r.success).toBe(true);
  });

  it("accepts a draft invoice with the optional fields omitted", () => {
    const r = invoiceEntity.safeParse(env({ type: "invoice", status: "draft" }));
    expect(r.success).toBe(true);
  });

  it("rejects a bad status", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", status: "paid" })).success).toBe(false);
  });

  it("rejects a non-integer totalCents (money must be cents)", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", totalCents: 12.5 })).success).toBe(false);
  });

  it("rejects a malformed dueDate", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", dueDate: "03/07/2026" })).success).toBe(false);
  });

  it("rejects the wrong type discriminator", () => {
    expect(invoiceEntity.safeParse(env({ type: "payment" })).success).toBe(false);
  });
});

describe("invoiceLineItemEntity", () => {
  it("accepts a line item (itemDescription + unitPriceCents)", () => {
    const r = invoiceLineItemEntity.safeParse(
      env({
        type: "invoiceLineItem",
        profileId: undefined,
        invoiceId: INV,
        itemDescription: "Site inspection",
        quantity: 1,
        unitPriceCents: 25000,
        sortOrder: 0,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a missing invoiceId", () => {
    expect(
      invoiceLineItemEntity.safeParse(
        env({ type: "invoiceLineItem", itemDescription: "x", unitPriceCents: 1 }),
      ).success,
    ).toBe(false);
  });

  it("rejects an empty itemDescription", () => {
    expect(
      invoiceLineItemEntity.safeParse(
        env({ type: "invoiceLineItem", invoiceId: INV, itemDescription: "", unitPriceCents: 1 }),
      ).success,
    ).toBe(false);
  });
});

describe("paymentEntity", () => {
  it("accepts a payment (amountCents + paidOn + optional method/note)", () => {
    const r = paymentEntity.safeParse(
      env({
        type: "payment",
        profileId: undefined,
        invoiceId: INV,
        amountCents: 50000,
        paidOn: "2026-06-20",
        method: "bank transfer",
        note: "deposit",
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer amountCents", () => {
    expect(
      paymentEntity.safeParse(env({ type: "payment", invoiceId: INV, amountCents: 1.5, paidOn: "2026-06-20" }))
        .success,
    ).toBe(false);
  });

  it("rejects a malformed paidOn", () => {
    expect(
      paymentEntity.safeParse(env({ type: "payment", invoiceId: INV, amountCents: 1, paidOn: "20-06-2026" }))
        .success,
    ).toBe(false);
  });
});

describe("entitySchemaFor / SYNCABLE_TYPES (invoices)", () => {
  it("exposes the three new syncable types", () => {
    expect(SYNCABLE_TYPES).toContain("invoice");
    expect(SYNCABLE_TYPES).toContain("invoiceLineItem");
    expect(SYNCABLE_TYPES).toContain("payment");
    expect(Object.keys(SYNCABLE_TABLES)).toHaveLength(20);
    expect([...SYNCABLE_TYPES].sort()).toEqual(Object.keys(SYNCABLE_TABLES).sort());
  });

  it("returns the specialized invoice schemas", () => {
    expect(entitySchemaFor("invoice")).toBe(invoiceEntity);
    expect(entitySchemaFor("invoiceLineItem")).toBe(invoiceLineItemEntity);
    expect(entitySchemaFor("payment")).toBe(paymentEntity);
  });
});
