import { z } from "zod";

/**
 * Validation for syncable entity payloads carried inside /sync/push mutations.
 *
 * Deliberately LENIENT: the envelope uses .passthrough() so new client fields
 * sync without a server deploy. The route layer (Task: sync) overwrites the
 * server-authoritative fields (updatedAt, rev, lastEditedDeviceId) regardless of
 * what the client sent, and enforces tenancy (payload.userId === c.var.userId).
 *
 * Conventions (SPINE): money = INTEGER cents, ids = UUIDv7 strings,
 * timestamps = epoch ms, dates = "YYYY-MM-DD".
 */

const uuid = z.string().uuid();
const epochMs = z.number().int().nonnegative();
const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");
const cents = z.number().int(); // signed; negative = expense
const pct = z.number().int().min(0).max(100);

/**
 * Every syncable row (D1 + push payload + pull change) carries these fields.
 *
 * `type` is OPTIONAL and `lastEditedDeviceId` is OPTIONAL + NULLABLE on purpose:
 * the push route never reads either — it derives the entity type from the
 * mutation's `entityType` and server-stamps `last_edited_device_id` from the
 * authed request's deviceId. The real iOS encoder (SyncEntityRegistry.swift
 * sharedFields()) never emits a `type` key and sends `lastEditedDeviceId: null`
 * for locally-created rows; requiring them here 400'd every real-device push
 * (production outage — see the contract regression test in sync-push.test.ts).
 */
export const baseEnvelope = z
  .object({
    id: uuid,
    userId: uuid,
    profileId: uuid.optional(),
    type: z.string().min(1).optional(),
    createdAt: epochMs,
    updatedAt: epochMs,
    deletedAt: epochMs.nullable().default(null),
    rev: z.number().int().nonnegative(),
    lastEditedDeviceId: z.string().min(1).nullable().optional(),
  })
  .passthrough();

export type BaseEnvelope = z.infer<typeof baseEnvelope>;

/** transaction — see backend.md §"transactions". Money in cents, date-only string. */
export const transactionEntity = baseEnvelope.extend({
  type: z.literal("transaction"),
  merchant: z.string().optional(),
  catKey: z
    .enum([
      "meals",
      "groceries",
      "fuel",
      "software",
      "office",
      "home",
      "health",
      "travel",
      "income",
      "custom",
    ])
    .optional(),
  categoryId: uuid.nullable().optional(),
  amountCents: cents.optional(),
  currency: z.string().length(3).optional(),
  txnDate: isoDate.optional(),
  mode: z.enum(["business", "personal"]).optional(),
  taxLabel: z.string().nullable().optional(),
  deductiblePct: pct.nullable().optional(),
  paymentMethod: z.string().nullable().optional(),
  isAi: z.boolean().optional(),
  note: z.string().nullable().optional(),
  gstCents: cents.nullable().optional(),
  logbookLink: z.enum(["vehicle", "wfh"]).nullable().optional(),
  mileageTripId: uuid.nullable().optional(),
  source: z.enum(["manual", "scan", "email_in", "import"]).optional(),
  extractionStatus: z.enum(["pending", "done", "failed"]).nullable().optional(),
});

/** lineItem — child of a transaction; replaced wholesale with its parent. */
export const lineItemEntity = baseEnvelope.extend({
  type: z.literal("lineItem"),
  transactionId: uuid,
  name: z.string().min(1),
  priceCents: cents,
  quantity: z.number().int().min(1).optional(),
  sortOrder: z.number().int().optional(),
});

/** profile — the user's switchable persona. (profileType avoids clashing with envelope.type) */
export const profileEntity = baseEnvelope.extend({
  type: z.literal("profile"),
  name: z.string().min(1),
  profileType: z.enum(["personal", "business"]),
  initials: z.string().nullable().optional(),
  accent1: z.string().optional(),
  accent2: z.string().optional(),
  accent3: z.string().optional(),
  abn: z.string().nullable().optional(),
  gstRegistered: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
  isDefault: z.boolean().optional(),
});

/** budget — per category/profile/month; cap in cents, spent is computed (never stored). */
export const budgetEntity = baseEnvelope.extend({
  type: z.literal("budget"),
  categoryId: uuid.nullable().optional(),
  catKey: z.string().nullable().optional(),
  label: z.string().min(1),
  period: z.enum(["monthly"]).optional(),
  monthKey: z.string().regex(/^\d{4}-\d{2}$/).nullable().optional(),
  capCents: cents,
  currency: z.string().length(3).optional(),
  alertThresholdPct: z.number().int().min(1).max(200).optional(),
});

/** loyaltyCard — brand + number + gradient colors + barcode metadata. */
export const loyaltyCardEntity = baseEnvelope.extend({
  type: z.literal("loyaltyCard"),
  brand: z.string().min(1),
  subBrand: z.string().nullable().optional(),
  number: z.string().min(1),
  barcodeFormat: z.enum(["code128", "ean13", "qr", "aztec", "pdf417"]).nullable().optional(),
  pointsLabel: z.string().nullable().optional(),
  color1: z.string().optional(),
  color2: z.string().optional(),
  sortOrder: z.number().int().optional(),
});

/** vehicle — the user's car for the ATO logbook method (one per profile in v1). */
export const vehicleEntity = baseEnvelope.extend({
  type: z.literal("vehicle"),
  make: z.string().nullable().optional(),
  model: z.string().nullable().optional(),
  engineCc: z.number().int().nonnegative().nullable().optional(),
  registration: z.string().nullable().optional(),
  logbookStartDate: isoDate.nullable().optional(),
  logbookEndDate: isoDate.nullable().optional(),
  businessUsePct: pct.nullable().optional(),
});

/** vehicleYear — one row per (vehicle, FY): annual running-cost totals + cached claim. */
export const vehicleYearEntity = baseEnvelope.extend({
  type: z.literal("vehicleYear"),
  vehicleId: uuid,
  fyStartYear: z.number().int(),
  odometerOpenM: z.number().int().nonnegative().nullable().optional(),
  odometerCloseM: z.number().int().nonnegative().nullable().optional(),
  fuelCents: cents.optional(),
  regoCents: cents.optional(),
  insuranceCents: cents.optional(),
  servicingCents: cents.optional(),
  otherCents: cents.optional(),
  depreciationCents: cents.optional(),
  businessUsePct: pct.nullable().optional(),
  claimCents: cents.nullable().optional(),
});

/** Every syncable type (SPINE). Types without a specialized schema validate via baseEnvelope. */
export const SYNCABLE_TYPES = [
  "transaction",
  "lineItem",
  "profile",
  "category",
  "smartRule",
  "budget",
  "loyaltyCard",
  "client",
  "quote",
  "quoteLineItem",
  "mileageTrip",
  "wfhLog",
  "taxSettings",
  "vehicle",
  "vehicleYear",
] as const;

export type SyncableType = (typeof SYNCABLE_TYPES)[number];

const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
  vehicle: vehicleEntity,
  vehicleYear: vehicleYearEntity,
};

/** Returns the strictest available schema for an entityType; baseEnvelope is the fallback. */
export function entitySchemaFor(type: string): z.ZodTypeAny {
  return SPECIALIZED[type as SyncableType] ?? baseEnvelope.passthrough();
}
