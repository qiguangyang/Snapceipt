import { describe, it, expect } from "vitest";
import {
  baseEnvelope,
  transactionEntity,
  lineItemEntity,
  profileEntity,
  budgetEntity,
  loyaltyCardEntity,
  vehicleEntity,
  vehicleYearEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";
import {
  mutationSchema,
  pushBodySchema,
  pullQuerySchema,
  encodeCursor,
  decodeCursor,
} from "../src/schemas/sync";
import {
  appleBody,
  magicLinkRequestBody,
  magicLinkVerifyBody,
  refreshBody,
} from "../src/schemas/auth";

// ---- shared fixtures ----
const UID = "0190f8a0-1111-7000-8000-000000000001";
const PID = "0190f8a0-2222-7000-8000-000000000002";
const EID = "0190f8a0-3333-7000-8000-000000000003";
const DID = "0190f8a0-4444-7000-8000-000000000004";

function env(overrides: Record<string, unknown> = {}) {
  return {
    id: EID,
    userId: UID,
    profileId: PID,
    type: "transaction",
    createdAt: 1748563200000,
    updatedAt: 1748563200000,
    deletedAt: null,
    rev: 1,
    lastEditedDeviceId: DID,
    ...overrides,
  };
}

describe("baseEnvelope", () => {
  it("accepts a minimal valid envelope and keeps unknown fields (passthrough)", () => {
    const r = baseEnvelope.safeParse(env({ merchant: "Aldi", amountCents: -1234 }));
    expect(r.success).toBe(true);
    if (r.success) {
      expect(r.data.merchant).toBe("Aldi");
      expect(r.data.amountCents).toBe(-1234);
      expect(r.data.deletedAt).toBeNull();
    }
  });

  it("allows deletedAt as a tombstone ms timestamp", () => {
    const r = baseEnvelope.safeParse(env({ deletedAt: 1748563299999 }));
    expect(r.success).toBe(true);
  });

  it("allows profileId to be omitted (user-scoped entity)", () => {
    const e = env();
    delete (e as Record<string, unknown>).profileId;
    expect(baseEnvelope.safeParse(e).success).toBe(true);
  });

  it("rejects a non-uuid id", () => {
    expect(baseEnvelope.safeParse(env({ id: "not-a-uuid" })).success).toBe(false);
  });

  it("rejects a missing userId", () => {
    const e = env();
    delete (e as Record<string, unknown>).userId;
    expect(baseEnvelope.safeParse(e).success).toBe(false);
  });

  it("rejects a float rev", () => {
    expect(baseEnvelope.safeParse(env({ rev: 1.5 })).success).toBe(false);
  });
});

describe("transactionEntity", () => {
  it("accepts a full transaction payload with integer cents", () => {
    const r = transactionEntity.safeParse(
      env({
        type: "transaction",
        merchant: "BP Service",
        amountCents: -8800,
        currency: "AUD",
        txnDate: "2026-05-29",
        catKey: "fuel",
        mode: "business",
        deductiblePct: 100,
        gstCents: 800,
        isAi: true,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer amountCents (money must be cents)", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", amountCents: 12.5 }));
    expect(r.success).toBe(false);
  });

  it("rejects a malformed txnDate", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", txnDate: "29/05/2026" }));
    expect(r.success).toBe(false);
  });

  it("rejects an out-of-range deductiblePct", () => {
    const r = transactionEntity.safeParse(env({ type: "transaction", deductiblePct: 150 }));
    expect(r.success).toBe(false);
  });

  it("rejects the wrong type discriminator", () => {
    const r = transactionEntity.safeParse(env({ type: "profile" }));
    expect(r.success).toBe(false);
  });
});

describe("profileEntity / budgetEntity / loyaltyCardEntity / lineItemEntity", () => {
  it("accepts a profile", () => {
    const r = profileEntity.safeParse(
      env({ type: "profile", profileId: undefined, name: "Studio North", profileType: "business" }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects an invalid profile type", () => {
    const r = profileEntity.safeParse(env({ type: "profile", name: "X", profileType: "school" }));
    expect(r.success).toBe(false);
  });

  it("accepts a budget with capCents", () => {
    const r = budgetEntity.safeParse(env({ type: "budget", label: "Groceries", capCents: 60000 }));
    expect(r.success).toBe(true);
  });

  it("rejects a budget with float capCents", () => {
    const r = budgetEntity.safeParse(env({ type: "budget", label: "Groceries", capCents: 600.5 }));
    expect(r.success).toBe(false);
  });

  it("accepts a loyalty card", () => {
    const r = loyaltyCardEntity.safeParse(
      env({ type: "loyaltyCard", brand: "Everyday Rewards", number: "1234 5678" }),
    );
    expect(r.success).toBe(true);
  });

  it("accepts a line item with priceCents", () => {
    const r = lineItemEntity.safeParse(
      env({ type: "lineItem", profileId: undefined, transactionId: EID, name: "Coffee", priceCents: 550 }),
    );
    expect(r.success).toBe(true);
  });
});

describe("entitySchemaFor / SYNCABLE_TYPES", () => {
  it("exposes every syncable type", () => {
    expect(SYNCABLE_TYPES).toContain("transaction");
    expect(SYNCABLE_TYPES).toContain("taxSettings");
    expect(SYNCABLE_TYPES).toContain("quoteLineItem");
    expect(SYNCABLE_TYPES).toContain("vehicle");
    expect(SYNCABLE_TYPES).toContain("vehicleYear");
    expect(SYNCABLE_TYPES.length).toBe(14);
  });

  it("returns the specialized schema for known types", () => {
    const r = entitySchemaFor("transaction").safeParse(env({ type: "transaction", amountCents: 1 }));
    expect(r.success).toBe(true);
    expect(entitySchemaFor("transaction").safeParse(env({ type: "transaction", amountCents: 1.1 })).success).toBe(false);
  });

  it("falls back to baseEnvelope for types without a specialized schema", () => {
    const r = entitySchemaFor("category").safeParse(env({ type: "category", label: "Meals" }));
    expect(r.success).toBe(true);
  });
});

describe("mutationSchema + pushBodySchema", () => {
  const validMutation = {
    mutationId: "0190f8a0-5555-7000-8000-000000000005",
    entityType: "transaction",
    entityId: EID,
    op: "upsert" as const,
    baseRev: 0,
    updatedAt: 1748563200000,
    payload: env({ type: "transaction", amountCents: -100 }),
  };

  it("accepts a valid mutation", () => {
    expect(mutationSchema.safeParse(validMutation).success).toBe(true);
  });

  it("accepts op delete", () => {
    expect(mutationSchema.safeParse({ ...validMutation, op: "delete" }).success).toBe(true);
  });

  it("rejects an unknown op", () => {
    expect(mutationSchema.safeParse({ ...validMutation, op: "insert" }).success).toBe(false);
  });

  it("rejects a non-uuid mutationId", () => {
    expect(mutationSchema.safeParse({ ...validMutation, mutationId: "x" }).success).toBe(false);
  });

  it("accepts a push body with up to 200 mutations", () => {
    const body = { deviceId: DID, mutations: Array.from({ length: 200 }, () => validMutation) };
    expect(pushBodySchema.safeParse(body).success).toBe(true);
  });

  it("rejects a push body with 201 mutations (batch cap)", () => {
    const body = { deviceId: DID, mutations: Array.from({ length: 201 }, () => validMutation) };
    expect(pushBodySchema.safeParse(body).success).toBe(false);
  });

  it("rejects an empty push body", () => {
    expect(pushBodySchema.safeParse({ deviceId: DID, mutations: [] }).success).toBe(false);
  });
});

describe("pullQuerySchema", () => {
  it("defaults limit to 500 when omitted (first sync)", () => {
    const r = pullQuerySchema.safeParse({});
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.limit).toBe(500);
  });

  it("coerces a string limit from the query string", () => {
    const r = pullQuerySchema.safeParse({ cursor: "abc", limit: "250" });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.limit).toBe(250);
  });

  it("rejects a limit above 500", () => {
    expect(pullQuerySchema.safeParse({ limit: "5000" }).success).toBe(false);
  });
});

describe("cursor codec", () => {
  it("round-trips a cursor through base64url", () => {
    const c = { ts: 1748563200123, id: EID };
    const decoded = decodeCursor(encodeCursor(c));
    expect(decoded).toEqual(c);
  });

  it("produces a URL-safe string (no +, /, or = padding)", () => {
    const enc = encodeCursor({ ts: 1748563200123, id: EID });
    expect(enc).not.toMatch(/[+/=]/);
  });

  it("returns null for undefined (first sync = full snapshot)", () => {
    expect(decodeCursor(undefined)).toBeNull();
  });

  it("returns null for garbage input", () => {
    expect(decodeCursor("!!!not-base64!!!")).toBeNull();
  });

  it("returns null when the decoded shape is invalid", () => {
    const bad = btoa(JSON.stringify({ ts: "nope", id: 123 }))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    expect(decodeCursor(bad)).toBeNull();
  });
});

describe("auth bodies", () => {
  it("accepts a valid apple body", () => {
    const r = appleBody.safeParse({
      identityToken: "eyJ...",
      authorizationCode: "c123",
      rawNonce: "n123",
      email: "user@example.com",
    });
    expect(r.success).toBe(true);
  });

  it("rejects an apple body missing rawNonce", () => {
    expect(
      appleBody.safeParse({ identityToken: "x", authorizationCode: "y" }).success,
    ).toBe(false);
  });

  it("accepts a magic-link request with a valid email", () => {
    expect(magicLinkRequestBody.safeParse({ email: "a@b.com" }).success).toBe(true);
  });

  it("rejects a magic-link request with a bad email", () => {
    expect(magicLinkRequestBody.safeParse({ email: "not-an-email" }).success).toBe(false);
  });

  it("accepts a magic-link verify token and a refresh token", () => {
    expect(magicLinkVerifyBody.safeParse({ token: "t" }).success).toBe(true);
    expect(refreshBody.safeParse({ refreshToken: "r" }).success).toBe(true);
  });

  it("rejects an empty refresh token", () => {
    expect(refreshBody.safeParse({ refreshToken: "" }).success).toBe(false);
  });
});

describe("vehicleEntity / vehicleYearEntity", () => {
  it("accepts a full vehicle payload", () => {
    const r = vehicleEntity.safeParse(
      env({
        type: "vehicle",
        make: "Toyota",
        model: "HiLux",
        engineCc: 2800,
        registration: "ABC123",
        logbookStartDate: "2025-08-12",
        logbookEndDate: "2025-11-04",
        businessUsePct: 78,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a business_use_pct over 100", () => {
    const r = vehicleEntity.safeParse(env({ type: "vehicle", businessUsePct: 150 }));
    expect(r.success).toBe(false);
  });

  it("rejects a malformed logbookStartDate", () => {
    const r = vehicleEntity.safeParse(env({ type: "vehicle", logbookStartDate: "12/08/2025" }));
    expect(r.success).toBe(false);
  });

  it("accepts a full vehicleYear payload with integer cents", () => {
    const r = vehicleYearEntity.safeParse(
      env({
        type: "vehicleYear",
        vehicleId: "0190f8a0-5555-7000-8000-000000000005",
        fyStartYear: 2025,
        fuelCents: 220000,
        regoCents: 90000,
        insuranceCents: 60000,
        servicingCents: 30000,
        otherCents: 12000,
        depreciationCents: 100000,
        businessUsePct: 78,
        claimCents: 321360,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer cents field on vehicleYear", () => {
    const r = vehicleYearEntity.safeParse(
      env({ type: "vehicleYear", vehicleId: "0190f8a0-5555-7000-8000-000000000005", fyStartYear: 2025, fuelCents: 12.5 }),
    );
    expect(r.success).toBe(false);
  });

  it("entitySchemaFor returns the specialized vehicle schemas", () => {
    expect(entitySchemaFor("vehicle")).toBe(vehicleEntity);
    expect(entitySchemaFor("vehicleYear")).toBe(vehicleYearEntity);
  });
});
