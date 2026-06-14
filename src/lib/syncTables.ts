// Maps each syncable entity type (camelCase, as sent by the client) to its D1
// table and the set of writable domain columns. Sync-envelope columns
// (id, user_id, profile_id, created_at, updated_at, deleted_at, rev,
// last_edited_device_id) are handled generically by the push route and are NOT
// listed here. Server-generated columns (e.g. transactions.month_key,
// quote_line_items.line_total_cents) are deliberately omitted — they are never
// written from a client payload.

export type SyncTableMeta = {
  table: string;
  hasProfileId: boolean;
  // camelCase field name -> snake_case column name for domain fields
  columns: Record<string, string>;
};

export const SYNCABLE_TABLES: Record<string, SyncTableMeta> = {
  transaction: {
    table: "transactions",
    hasProfileId: true,
    columns: {
      merchant: "merchant",
      categoryId: "category_id",
      catKey: "cat_key",
      amountCents: "amount_cents",
      currency: "currency",
      txnDate: "txn_date",
      mode: "mode",
      taxLabel: "tax_label",
      deductiblePct: "deductible_pct",
      paymentMethod: "payment_method",
      isAi: "is_ai",
      note: "note",
      gstCents: "gst_cents",
      gstFree: "gst_free",
      capital: "capital",
      gstSource: "gst_source",
      logbookLink: "logbook_link",
      mileageTripId: "mileage_trip_id",
      source: "source",
      extractionStatus: "extraction_status",
    },
  },
  lineItem: {
    table: "line_items",
    hasProfileId: false,
    columns: {
      transactionId: "transaction_id",
      name: "name",
      priceCents: "price_cents",
      quantity: "quantity",
      sortOrder: "sort_order",
    },
  },
  profile: {
    table: "profiles",
    hasProfileId: false,
    columns: {
      name: "name",
      // Client sends the persona as `profileType` (envelope `type` is the "profile"
      // discriminant). Map profileType -> profiles.type so we persist the persona,
      // not the envelope discriminant.
      profileType: "type",
      initials: "initials",
      accent1: "accent_1",
      accent2: "accent_2",
      accent3: "accent_3",
      abn: "abn",
      gstRegistered: "gst_registered",
      sortOrder: "sort_order",
      isDefault: "is_default",
    },
  },
  category: {
    table: "categories",
    hasProfileId: true,
    columns: {
      key: "key",
      label: "label",
      icon: "icon",
      tint: "tint",
      soft: "soft",
      defaultDeductiblePct: "default_deductible_pct",
      isIncome: "is_income",
      sortOrder: "sort_order",
      gstFreeDefault: "gst_free_default",
    },
  },
  smartRule: {
    table: "smart_rules",
    hasProfileId: true,
    columns: {
      matchType: "match_type",
      matcher: "matcher",
      categoryId: "category_id",
      setDeductiblePct: "set_deductible_pct",
      setMode: "set_mode",
      priority: "priority",
      enabled: "enabled",
    },
  },
  budget: {
    table: "budgets",
    hasProfileId: true,
    columns: {
      categoryId: "category_id",
      catKey: "cat_key",
      label: "label",
      period: "period",
      monthKey: "month_key",
      capCents: "cap_cents",
      currency: "currency",
      alertThresholdPct: "alert_threshold_pct",
      alertSentAt: "alert_sent_at",
    },
  },
  loyaltyCard: {
    table: "loyalty_cards",
    hasProfileId: true,
    columns: {
      brand: "brand",
      subBrand: "sub_brand",
      number: "number",
      barcodeFormat: "barcode_format",
      pointsLabel: "points_label",
      color1: "color_1",
      color2: "color_2",
      sortOrder: "sort_order",
    },
  },
  client: {
    table: "clients",
    hasProfileId: true,
    columns: {
      name: "name",
      email: "email",
    },
  },
  quote: {
    table: "quotes",
    hasProfileId: true,
    columns: {
      number: "number",
      clientName: "client_name",
      clientEmail: "client_email",
      gstEnabled: "gst_enabled",
      subtotalCents: "subtotal_cents",
      gstCents: "gst_cents",
      totalCents: "total_cents",
      currency: "currency",
      status: "status",
      validUntil: "valid_until",
      sentAt: "sent_at",
    },
  },
  quoteLineItem: {
    table: "quote_line_items",
    hasProfileId: false,
    columns: {
      quoteId: "quote_id",
      description: "description",
      quantity: "quantity",
      unitPriceCents: "unit_price_cents",
      sortOrder: "sort_order",
    },
  },
  mileageTrip: {
    table: "mileage_trips",
    hasProfileId: true,
    columns: {
      tripDate: "trip_date",
      fromLabel: "from_label",
      toLabel: "to_label",
      purpose: "purpose",
      distanceM: "distance_m",
      isBusiness: "is_business",
      rateCentsPerKm: "rate_cents_per_km",
      claimCents: "claim_cents",
      autoTracked: "auto_tracked",
      vehicleId: "vehicle_id",
      odometerStartM: "odometer_start_m",
      odometerEndM: "odometer_end_m",
    },
  },
  wfhLog: {
    table: "wfh_logs",
    hasProfileId: true,
    columns: {
      logDate: "log_date",
      minutes: "minutes",
      note: "note",
      rateCentsPerHour: "rate_cents_per_hour",
      claimCents: "claim_cents",
    },
  },
  vehicle: {
    table: "vehicles",
    hasProfileId: true,
    columns: {
      make: "make",
      model: "model",
      engineCc: "engine_cc",
      registration: "registration",
      logbookStartDate: "logbook_start_date",
      logbookEndDate: "logbook_end_date",
      businessUsePct: "business_use_pct",
    },
  },
  vehicleYear: {
    table: "vehicle_years",
    hasProfileId: true,
    columns: {
      vehicleId: "vehicle_id",
      fyStartYear: "fy_start_year",
      odometerOpenM: "odometer_open_m",
      odometerCloseM: "odometer_close_m",
      fuelCents: "fuel_cents",
      regoCents: "rego_cents",
      insuranceCents: "insurance_cents",
      servicingCents: "servicing_cents",
      otherCents: "other_cents",
      depreciationCents: "depreciation_cents",
      businessUsePct: "business_use_pct",
      claimCents: "claim_cents",
    },
  },
  taxSettings: {
    table: "tax_settings",
    hasProfileId: true,
    columns: {
      gstRateBps: "gst_rate_bps",
      financialYearStartMonth: "financial_year_start_month",
      mealsDeductiblePct: "meals_deductible_pct",
      wfhRateCentsPerHour: "wfh_rate_cents_per_hour",
      mileageRateCentsPerKm: "mileage_rate_cents_per_km",
      accountantEmail: "accountant_email",
    },
  },
};

/**
 * EntityTypes whose D1 `profile_id` column is NOT NULL (see migrations/0001_init.sql).
 * An upsert for one of these that omits profileId would write NULL and trip a NOT NULL
 * constraint inside the batch — the push route guards these and rejects the mutation
 * cleanly (VALIDATION_FAILED) instead. categories/smartRule/loyaltyCard have a nullable
 * profile_id; profile/lineItem have none — they are intentionally absent here.
 */
export const PROFILE_ID_REQUIRED: ReadonlySet<string> = new Set([
  "transaction",
  "budget",
  "mileageTrip",
  "wfhLog",
  "vehicle",
  "vehicleYear",
  "quote",
  "taxSettings",
]);

/** Resolve a client entityType to its table metadata, or null if unknown. */
export function tableForEntityType(entityType: string): SyncTableMeta | null {
  return SYNCABLE_TABLES[entityType] ?? null;
}
