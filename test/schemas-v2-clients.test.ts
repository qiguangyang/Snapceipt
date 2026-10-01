import { describe, expect, it } from "vitest";
import * as entities from "../src/schemas/entities";
import { PROFILE_ID_REQUIRED, tableForEntityType } from "../src/lib/syncTables";
import { mutationSchema } from "../src/schemas/sync";

const ID = "0190f8a0-1111-7000-8000-000000000001";
const base = { id: ID, userId: ID, profileId: ID, createdAt: 0, updatedAt: 0, deletedAt: null, rev: 0, lastEditedDeviceId: null };
const catalog = { ...base, itemDescription: "Consulting", unitPriceCents: 1000, currency: "AUD" };
const followUp = { ...base, clientId: ID, title: "Call", dueAt: 0, timezone: "Australia/Sydney", completedAt: null };

describe("newEntitySchemaValidation", () => {
  it("exports specialized schemas and accepts real iOS payloads without type", () => {
    expect(entities).toHaveProperty("catalogItemEntity");
    expect(entities).toHaveProperty("clientFollowUpEntity");
    for (const [type, payload] of [["catalogItem", catalog], ["clientFollowUp", followUp]] as const) {
      expect(entities.entitySchemaFor(type).safeParse(payload).success).toBe(true);
      expect(mutationSchema.safeParse({ mutationId: ID, entityId: ID, entityType: type, op: "upsert", updatedAt: 0, payload }).success).toBe(true);
    }
  });

  it("registers profile-scoped wire mappings for both new entities", () => {
    expect(tableForEntityType("catalogItem")).toEqual({ table: "catalog_items", hasProfileId: true, columns: { itemDescription: "description", unitLabel: "unit_label", unitPriceCents: "unit_price_cents", currency: "currency" } });
    expect(tableForEntityType("clientFollowUp")).toEqual({ table: "client_follow_ups", hasProfileId: true, columns: { clientId: "client_id", title: "title", dueAt: "due_at", timezone: "timezone", completedAt: "completed_at" } });
    for (const type of ["catalogItem", "clientFollowUp"]) {
      expect(PROFILE_ID_REQUIRED.has(type)).toBe(true);
      expect(entities.entitySchemaFor(type).safeParse({ ...(type === "catalogItem" ? catalog : followUp), profileId: undefined }).success).toBe(false);
    }
    expect(tableForEntityType("client")?.columns.notes).toBe("notes");
    for (const type of ["quote", "invoice"]) expect(tableForEntityType(type)?.columns.clientId).toBe("client_id");
    for (const type of ["quoteLineItem", "invoiceLineItem"]) expect(tableForEntityType(type)?.columns.unitLabel).toBe("unit_label");
  });

  it.each([0, 1_000_000_000])("accepts a saved-item price of %i cents", unitPriceCents => {
    expect(entities.entitySchemaFor("catalogItem").safeParse({ ...catalog, unitPriceCents }).success).toBe(true);
  });
  it.each([-1, 0.5, 1_000_000_001])("rejects a saved-item price of %s cents", unitPriceCents => {
    expect(entities.entitySchemaFor("catalogItem").safeParse({ ...catalog, unitPriceCents }).success).toBe(false);
  });

  it("trims required text and rejects blank or over-limit names, descriptions, and titles", () => {
    for (const [type, fixture, field, limit] of [["client", { ...base, name: "Acme" }, "name", 200], ["catalogItem", catalog, "itemDescription", 500], ["clientFollowUp", followUp, "title", 200]] as const) {
      const schema = entities.entitySchemaFor(type);
      expect(schema.parse({ ...fixture, [field]: "  Work  " })[field]).toBe("Work");
      expect(schema.safeParse({ ...fixture, [field]: "x".repeat(limit) }).success).toBe(true);
      expect(schema.safeParse({ ...fixture, [field]: "x".repeat(limit + 1) }).success).toBe(false);
      expect(schema.safeParse({ ...fixture, [field]: " \n " }).success).toBe(false);
    }
  });

  it("normalizes blank optional notes and units, accepting null, omission, and exact limits", () => {
    for (const [type, fixture, field, limit] of [["client", { ...base, name: "Acme" }, "notes", 10_000], ["catalogItem", catalog, "unitLabel", 40], ["quoteLineItem", { ...base, quoteId: ID, description: "Work", unitPriceCents: 1 }, "unitLabel", 40], ["invoiceLineItem", { ...base, type: "invoiceLineItem", invoiceId: ID, itemDescription: "Work", unitPriceCents: 1 }, "unitLabel", 40]] as const) {
      const schema = entities.entitySchemaFor(type);
      expect(schema.parse({ ...fixture, [field]: "  " })[field]).toBeNull();
      expect(schema.parse({ ...fixture, [field]: null })[field]).toBeNull();
      expect(schema.parse(fixture)[field]).toBeUndefined();
      expect(schema.safeParse({ ...fixture, [field]: "x".repeat(limit) }).success).toBe(true);
      expect(schema.safeParse({ ...fixture, [field]: "x".repeat(limit + 1) }).success).toBe(false);
    }
  });

  it("validates safe nonnegative integer follow-up timestamps and IANA timezones", () => {
    const schema = entities.entitySchemaFor("clientFollowUp");
    for (const field of ["dueAt", "completedAt", "createdAt", "updatedAt", "deletedAt"]) {
      for (const value of [-1, 1.5, Number.MAX_SAFE_INTEGER + 1]) expect(schema.safeParse({ ...followUp, [field]: value }).success).toBe(false);
      expect(schema.safeParse({ ...followUp, [field]: Number.MAX_SAFE_INTEGER }).success).toBe(true);
    }
    for (const timezone of ["UTC", "Australia/Sydney", "America/New_York"]) expect(schema.safeParse({ ...followUp, timezone }).success).toBe(true);
    for (const timezone of ["", "Mars/Olympus", "+10:00"]) expect(schema.safeParse({ ...followUp, timezone }).success).toBe(false);
    expect(schema.parse(followUp).completedAt).toBeNull();
    expect(schema.safeParse({ ...followUp, clientId: "bad-id" }).success).toBe(false);
    for (const field of ["clientId", "title", "dueAt", "timezone"]) expect(schema.safeParse({ ...followUp, [field]: undefined }).success).toBe(false);
  });

  it("validates nullable document client IDs while preserving v1 omissions", () => {
    for (const type of ["quote", "invoice"]) {
      const schema = entities.entitySchemaFor(type);
      expect(schema.safeParse({ ...base, type }).success).toBe(true);
      for (const clientId of [ID, null]) expect(schema.safeParse({ ...base, type, clientId }).success).toBe(true);
      expect(schema.safeParse({ ...base, type, clientId: "bad-id" }).success).toBe(false);
    }
    // Existing free-form contact values stay accepted.
    expect(entities.entitySchemaFor("client").safeParse({ ...base, name: "Acme", email: "legacy", mobilePhone: "any", address: "Somewhere" }).success).toBe(true);
  });
});
