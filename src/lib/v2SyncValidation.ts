import { z } from "zod";
import type { Mutation } from "../schemas/sync";
import { catalogItemEntity, clientEntity, clientFollowUpEntity, quoteLineItemEntity } from "../schemas/entities";
import { tableForEntityType } from "./syncTables";

const uuidv7 = z.string().uuid().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
const timestamp = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const newEnvelope = {
  id: uuidv7, profileId: uuidv7, createdAt: timestamp, updatedAt: timestamp,
  deletedAt: timestamp.nullable(),
};

// Validate only this feature's fields. Old entities have deliberately lenient
// payloads (including no type tag), so their complete strict schemas do not apply.
const schemas: Record<string, z.ZodTypeAny> = {
  client: clientEntity.pick({ name: true, notes: true }),
  quote: z.object({ clientId: uuidv7.nullable().optional() }),
  invoice: z.object({ clientId: uuidv7.nullable().optional() }),
  quoteLineItem: quoteLineItemEntity.pick({ unitLabel: true }),
  invoiceLineItem: quoteLineItemEntity.pick({ unitLabel: true }),
  catalogItem: catalogItemEntity.pick({ itemDescription: true, unitLabel: true, unitPriceCents: true, currency: true })
    .extend({ ...newEnvelope, currency: z.string().length(3).default("AUD") }),
  clientFollowUp: clientFollowUpEntity.pick({ clientId: true, title: true, dueAt: true, timezone: true, completedAt: true })
    .extend({ ...newEnvelope, clientId: uuidv7 }),
};

/** Types whose apply-time validation and insert fallbacks use a merged row. */
export const V2_SYNC_TYPES: ReadonlySet<string> = new Set(Object.keys(schemas));

/** Validate the row that will actually be saved, normalizing supplied v2 text. */
export async function validateV2Mutation(
  db: D1Database,
  userId: string,
  mutation: Mutation,
  stored: Record<string, unknown> | null,
): Promise<"FORBIDDEN" | "VALIDATION_FAILED" | null> {
  const schema = schemas[mutation.entityType];
  if (mutation.op === "delete" || !schema) return null;
  const payload = mutation.payload as Record<string, unknown>;
  const meta = tableForEntityType(mutation.entityType)!;
  const effective: Record<string, unknown> = {};
  if (stored) {
    effective.profileId = stored.profile_id;
    effective.createdAt = stored.created_at;
    for (const [field, column] of Object.entries(meta.columns)) effective[field] = stored[column];
  }
  Object.assign(effective, payload);
  // createdAt is immutable in the upsert; check its actual retained value.
  if (stored) effective.createdAt = stored.created_at;
  const parsed = schema.safeParse(effective);
  if (!parsed.success) return "VALIDATION_FAILED";

  const isNewType = mutation.entityType === "catalogItem" || mutation.entityType === "clientFollowUp";
  if (isNewType) {
    if (!timestamp.safeParse(mutation.updatedAt).success || payload.id !== mutation.entityId) return "VALIDATION_FAILED";
    const profile = await db.prepare(
      "SELECT type FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
    ).bind(effective.profileId, userId).first<{ type: string }>();
    if (!profile || profile.type !== "business") return "FORBIDDEN";
  }

  if (mutation.entityType === "client" && stored && effective.profileId !== stored.profile_id) {
    // Only live links in the client's current scope constrain a move. Tombstoned
    // document/reminder history survives and never has its snapshots rewritten.
    for (const table of ["quotes", "invoices", "client_follow_ups"]) {
      const linked = await db.prepare(
        `SELECT 1 FROM ${table} WHERE user_id = ? AND profile_id IS ? AND client_id = ? AND deleted_at IS NULL LIMIT 1`,
      ).bind(userId, stored.profile_id, mutation.entityId).first();
      if (linked) return "FORBIDDEN";
    }
  }

  if (["quote", "invoice", "clientFollowUp"].includes(mutation.entityType) && effective.clientId != null) {
    const client = await db.prepare(
      "SELECT deleted_at FROM clients WHERE id = ? AND user_id = ? AND profile_id IS ?",
    ).bind(effective.clientId, userId, effective.profileId ?? null).first<{ deleted_at: number | null }>();
    if (!client) {
      // Existence-only probe distinguishes a scope violation from an unknown ID;
      // it never returns another tenant's contact data.
      const exists = await db.prepare("SELECT 1 FROM clients WHERE id = ?").bind(effective.clientId).first();
      return exists ? "FORBIDDEN" : "VALIDATION_FAILED";
    }
    if (client.deleted_at != null) {
      const unchangedDocumentLink = (mutation.entityType === "quote" || mutation.entityType === "invoice")
        && stored && stored.client_id === effective.clientId && stored.profile_id === effective.profileId;
      if (!unchangedDocumentLink) return "VALIDATION_FAILED";
    }
  }

  // Normalize only supplied fields: an old client's omissions must not clear or
  // rewrite existing values. The route separately retains INSERT fallbacks and
  // limits ON CONFLICT UPDATE to supplied columns.
  for (const [field, value] of Object.entries(parsed.data as Record<string, unknown>)) {
    if (field in payload) payload[field] = value;
  }
  if (mutation.entityType === "catalogItem" && !stored && !("currency" in payload)) payload.currency = "AUD";
  return null;
}
