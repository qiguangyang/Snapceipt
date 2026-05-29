import type { Env } from "../env";

/** A processed-mutation idempotency-log row (sync push). Mirrors the processed_mutations table. */
export interface ProcessedMutation {
  mutation_id: string;
  user_id: string;
  device_id: string;
  entity_type: string;
  entity_id: string;
  op: "upsert" | "delete";
  status: "applied" | "conflict" | "duplicate" | "rejected";
  result_json: string | null;
  created_at: number;
}

/** Allow-list of table names that may be passed to the scoped helpers (table names cannot be bound params). */
const SCOPED_TABLES = new Set([
  "users", "devices", "profiles", "categories", "smart_rules",
  "transactions", "line_items", "receipt_images", "budgets", "loyalty_cards",
  "mileage_trips", "wfh_logs", "quotes", "quote_line_items", "tax_settings",
  "auth_identities", "email_tokens", "sessions", "email_outbox",
]);

function assertTable(table: string): string {
  if (!SCOPED_TABLES.has(table)) throw new Error(`db: unknown/unsafe table '${table}'`);
  return table;
}

/** All rows for a tenant, oldest-first by the delta-sync key (updated_at, id). Tombstones included. */
export async function scopedAll<T = Record<string, unknown>>(
  db: D1Database,
  table: string,
  userId: string,
): Promise<T[]> {
  const t = assertTable(table);
  const { results } = await db
    .prepare(`SELECT * FROM ${t} WHERE user_id = ? ORDER BY updated_at, id`)
    .bind(userId)
    .all<T>();
  return results;
}

/** A single row by id, scoped to the tenant. Returns null if it does not exist for this user. */
export async function scopedGet<T = Record<string, unknown>>(
  db: D1Database,
  table: string,
  userId: string,
  id: string,
): Promise<T | null> {
  const t = assertTable(table);
  return db
    .prepare(`SELECT * FROM ${t} WHERE user_id = ? AND id = ?`)
    .bind(userId, id)
    .first<T>();
}

/** Record the outcome of a processed sync mutation. Idempotent: re-recording the same id is a no-op. */
export async function recordProcessedMutation(
  db: D1Database,
  m: {
    mutationId: string;
    userId: string;
    deviceId: string;
    entityType: string;
    entityId: string;
    op: "upsert" | "delete";
    status: "applied" | "conflict" | "duplicate" | "rejected";
    resultJson: string | null;
    createdAt: number;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT OR IGNORE INTO processed_mutations
         (mutation_id, user_id, device_id, entity_type, entity_id, op, status, result_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      m.mutationId, m.userId, m.deviceId, m.entityType, m.entityId,
      m.op, m.status, m.resultJson, m.createdAt,
    )
    .run();
}

/** Look up a prior mutation result for idempotent replay. Returns null if not yet processed. */
export async function getProcessedMutation(
  db: D1Database,
  mutationId: string,
): Promise<ProcessedMutation | null> {
  return db
    .prepare(`SELECT * FROM processed_mutations WHERE mutation_id = ?`)
    .bind(mutationId)
    .first<ProcessedMutation>();
}

// The shared bindings type; the scoped helpers only need the DB binding.
export type DbEnv = Pick<Env, "DB">;
