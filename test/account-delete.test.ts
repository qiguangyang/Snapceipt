import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

// Every user-scoped table the DELETE /account purge must clear, child→parent.
// Mirrors PURGE_ORDER in src/routes/account.ts (kept here as the contract under
// test). The strengthened seed below populates a representative parent/child
// graph so the FK-safe cascade is actually exercised, not just the empty path.
const PURGE_ORDER = [
  "line_items", "quote_line_items", "receipt_images",
  "transactions",
  "smart_rules", "budgets",
  "mileage_trips", "vehicle_years",
  "vehicles",
  "categories",
  "quotes",
  "clients", "tax_settings", "loyalty_cards", "wfh_logs",
  "inbound_email_log", "profile_inbox_tokens", "quote_counters",
  "email_outbox", "processed_mutations", "sessions", "devices", "auth_identities",
  "profiles",
  "smart_scan_usage",
  "crash_reports",
  "users",
] as const;

// Seed a user with populated rows across many user-scoped tables, wired with
// real parent/child FKs (profile→txn→line_item, profile→txn→receipt_image,
// quote→quote_line_item, vehicle→vehicle_year, etc.) so the purge has to honor
// the FK-safe delete order to succeed.
async function seedRichUser(): Promise<{ userId: string; bearer: string; r2Key: string; exportKey: string; quoteR2Key: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const categoryId = uuidv7();
  const txnId = uuidv7();
  const lineItemId = uuidv7();
  const imageId = uuidv7();
  const quoteId = uuidv7();
  const exportId = uuidv7(); // R2 export key only — no D1 exports table backs this
  const qliId = uuidv7();
  const vehicleId = uuidv7();
  const vehicleYearId = uuidv7();
  const ruleId = uuidv7();
  const budgetId = uuidv7();
  const loyaltyId = uuidv7();
  const taxId = uuidv7();
  const clientId = uuidv7();
  const tripId = uuidv7();
  const wfhId = uuidv7();
  const authIdentityId = uuidv7();
  const outboxId = uuidv7();
  const inboxToken = uuidv7();
  const messageId = uuidv7();
  const mutationId = uuidv7();
  const t = nowMs();

  await env.DB.prepare(`INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(`INSERT INTO auth_identities (id, user_id, provider, subject, created_at) VALUES (?, ?, 'apple', ?, ?)`).bind(authIdentityId, userId, `sub-${userId}`, t).run();
  await env.DB.prepare(`INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`).bind(deviceId, userId, t, t).run();
  await env.DB.prepare(`INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at) VALUES (?, ?, 'Biz', 'business', '#0','#1','#2', ?, ?)`).bind(profileId, userId, t, t).run();

  await env.DB.prepare(`INSERT INTO categories (id, user_id, profile_id, key, label, icon, tint, soft, created_at, updated_at) VALUES (?, ?, ?, 'office', 'Office', 'tray', '#a', '#b', ?, ?)`).bind(categoryId, userId, profileId, t, t).run();

  await env.DB.prepare(`INSERT INTO transactions (id, user_id, profile_id, merchant, category_id, cat_key, amount_cents, currency, txn_date, mode, is_ai, source, created_at, updated_at, rev) VALUES (?, ?, ?, 'X', ?, 'office', -100, 'AUD', '2026-06-01', 'business', 0, 'manual', ?, ?, 0)`).bind(txnId, userId, profileId, categoryId, t, t).run();
  await env.DB.prepare(`INSERT INTO line_items (id, user_id, transaction_id, name, price_cents, quantity, created_at, updated_at) VALUES (?, ?, ?, 'Pens', 100, 1, ?, ?)`).bind(lineItemId, userId, txnId, t, t).run();
  await env.DB.prepare(`INSERT INTO receipt_images (id, user_id, profile_id, transaction_id, r2_key, content_type, source, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'image/jpeg', 'scan', ?, ?)`).bind(imageId, userId, profileId, txnId, `u/${userId}/x.jpg`, t, t).run();

  await env.DB.prepare(`INSERT INTO smart_rules (id, user_id, profile_id, match_type, matcher, category_id, priority, enabled, created_at, updated_at) VALUES (?, ?, ?, 'merchant_contains', 'X', ?, 0, 1, ?, ?)`).bind(ruleId, userId, profileId, categoryId, t, t).run();
  await env.DB.prepare(`INSERT INTO budgets (id, user_id, profile_id, category_id, label, period, cap_cents, currency, alert_threshold_pct, created_at, updated_at) VALUES (?, ?, ?, ?, 'Office cap', 'monthly', 5000, 'AUD', 90, ?, ?)`).bind(budgetId, userId, profileId, categoryId, t, t).run();

  await env.DB.prepare(`INSERT INTO vehicles (id, user_id, profile_id, make, model, created_at, updated_at) VALUES (?, ?, ?, 'Toyota', 'Hilux', ?, ?)`).bind(vehicleId, userId, profileId, t, t).run();
  await env.DB.prepare(`INSERT INTO vehicle_years (id, user_id, profile_id, vehicle_id, fy_start_year, created_at, updated_at) VALUES (?, ?, ?, ?, 2025, ?, ?)`).bind(vehicleYearId, userId, profileId, vehicleId, t, t).run();
  await env.DB.prepare(`INSERT INTO mileage_trips (id, user_id, profile_id, trip_date, distance_m, is_business, vehicle_id, created_at, updated_at) VALUES (?, ?, ?, '2026-06-01', 12000, 1, ?, ?, ?)`).bind(tripId, userId, profileId, vehicleId, t, t).run();
  await env.DB.prepare(`INSERT INTO wfh_logs (id, user_id, profile_id, log_date, minutes, created_at, updated_at) VALUES (?, ?, ?, '2026-06-01', 480, ?, ?)`).bind(wfhId, userId, profileId, t, t).run();

  await env.DB.prepare(`INSERT INTO quotes (id, user_id, profile_id, number, subtotal_cents, gst_cents, total_cents, currency, status, created_at, updated_at) VALUES (?, ?, ?, 'SN-0001', 1000, 100, 1100, 'AUD', 'draft', ?, ?)`).bind(quoteId, userId, profileId, t, t).run();
  await env.DB.prepare(`INSERT INTO quote_line_items (id, user_id, quote_id, description, quantity, unit_price_cents, created_at, updated_at) VALUES (?, ?, ?, 'Consulting', 1, 1000, ?, ?)`).bind(qliId, userId, quoteId, t, t).run();
  await env.DB.prepare(`INSERT INTO clients (id, user_id, profile_id, name, email, created_at, updated_at) VALUES (?, ?, ?, 'Acme', 'acme@e.com', ?, ?)`).bind(clientId, userId, profileId, t, t).run();
  await env.DB.prepare(`INSERT INTO quote_counters (user_id, next_seq) VALUES (?, 2)`).bind(userId).run();

  await env.DB.prepare(`INSERT INTO tax_settings (id, user_id, profile_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`).bind(taxId, userId, profileId, t, t).run();
  await env.DB.prepare(`INSERT INTO loyalty_cards (id, user_id, profile_id, brand, number, color_1, color_2, created_at, updated_at) VALUES (?, ?, ?, 'Coles', '123', '#1', '#2', ?, ?)`).bind(loyaltyId, userId, profileId, t, t).run();

  await env.DB.prepare(`INSERT INTO profile_inbox_tokens (token, user_id, profile_id, created_at) VALUES (?, ?, ?, ?)`).bind(inboxToken, userId, profileId, t).run();
  await env.DB.prepare(`INSERT INTO inbound_email_log (message_id, user_id, profile_id, transaction_id, status, received_at) VALUES (?, ?, ?, ?, 'created', ?)`).bind(messageId, userId, profileId, txnId, t).run();
  await env.DB.prepare(`INSERT INTO email_outbox (id, user_id, to_email, kind, status, attempts, created_at) VALUES (?, ?, 'x@e.com', 'magic_link', 'queued', 0, ?)`).bind(outboxId, userId, t).run();
  await env.DB.prepare(`INSERT INTO processed_mutations (mutation_id, user_id, device_id, entity_type, entity_id, op, status, result_json, created_at) VALUES (?, ?, ?, 'transaction', ?, 'upsert', 'applied', '{}', ?)`).bind(mutationId, userId, deviceId, txnId, t).run();

  // smart_scan_usage: server-only cap table — must be purged on account delete.
  await env.DB.prepare(`INSERT INTO smart_scan_usage (user_id, period, count, updated_at) VALUES (?, '2026-06', 5, ?)`).bind(userId, t).run();

  // crash_reports: iOS MetricKit diagnostics (migration 0007) — right-to-erasure gap if missed.
  const crashId = uuidv7();
  await env.DB.prepare(
    `INSERT INTO crash_reports (id, user_id, device_id, kind, app_version, os_version, device_model, occurred_at, payload, created_at)
     VALUES (?, ?, ?, 'crash', '1.0.0', '18.0', 'iPhone16,2', ?, '{}', ?)`
  ).bind(crashId, userId, deviceId, t, t).run();

  const r2Key = `u/${userId}/x.jpg`;
  const exportKey = `${userId}/exports/${exportId}.pdf`;
  const quoteR2Key = `${userId}/quotes/${quoteId}.pdf`;
  await env.RECEIPTS.put(r2Key, new TextEncoder().encode("img"));
  await env.RECEIPTS.put(exportKey, new TextEncoder().encode("export-pdf"));
  await env.RECEIPTS.put(quoteR2Key, new TextEncoder().encode("quote-pdf"));
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, bearer: `Bearer ${accessToken}`, r2Key, exportKey, quoteR2Key };
}

beforeEach(async () => {
  // Clear in FK-safe (child→parent) order so a populated graph from a prior run
  // never blocks the next run.
  for (const table of PURGE_ORDER) {
    await env.DB.exec(`DELETE FROM ${table}`);
  }
});

// Resolve the per-table tenant column: every PURGE_ORDER table is scoped by
// user_id except quote_counters (PK is user_id, no separate column distinction)
// and the two server-only logs keyed by their own PK. They all carry user_id,
// so a uniform WHERE user_id = ? COUNT works for all of them.
async function countForUser(table: string, userId: string): Promise<number> {
  const row = await env.DB.prepare(`SELECT COUNT(*) c FROM ${table} WHERE user_id = ?`).bind(userId).first<{ c: number }>();
  return row!.c;
}

describe("DELETE /account", () => {
  it("purges all D1 rows across every user-scoped table + R2 objects", async () => {
    const { userId, bearer, r2Key, exportKey, quoteR2Key } = await seedRichUser();

    // Sanity: the seed actually populated the graph (a few representative tables).
    for (const table of ["transactions", "line_items", "receipt_images", "quotes", "quote_line_items", "vehicle_years", "profiles", "users"]) {
      expect(await countForUser(table, userId)).toBeGreaterThan(0);
    }

    const res = await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: bearer } });
    expect(res.status).toBe(200);

    // The FK-safe cascade must leave nothing behind in ANY user-scoped table.
    for (const table of PURGE_ORDER) {
      expect(await countForUser(table, userId)).toBe(0);
    }

    expect(await env.RECEIPTS.get(r2Key)).toBeNull();       // u/${userId}/x.jpg
    expect(await env.RECEIPTS.get(exportKey)).toBeNull();    // ${userId}/exports/<id>.pdf
    expect(await env.RECEIPTS.get(quoteR2Key)).toBeNull();   // ${userId}/quotes/<id>.pdf
  });

  it("does not touch another user's data", async () => {
    const a = await seedRichUser();
    const b = await seedRichUser();
    await SELF.fetch("https://x/account", { method: "DELETE", headers: { authorization: a.bearer } });
    const bRows = await env.DB.prepare("SELECT COUNT(*) c FROM transactions WHERE user_id = ?").bind(b.userId).first<{ c: number }>();
    expect(bRows!.c).toBe(1);
  });
});
