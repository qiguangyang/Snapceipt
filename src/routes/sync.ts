import { Hono } from "hono";
import type { AppEnv } from "../env";
import { serverStamp } from "../lib/time";
import { getProcessedMutation } from "../lib/db";
import {
  pushBodySchema,
  pullQuerySchema,
  encodeCursor,
  decodeCursor,
  type Mutation,
  type Cursor,
} from "../schemas/sync";
import {
  tableForEntityType,
  SYNCABLE_TABLES,
  PROFILE_ID_REQUIRED,
  type SyncTableMeta,
} from "../lib/syncTables";
import { validate } from "./auth";

/**
 * Sync routes mounted under `/sync`. PROTECTED — the global auth middleware has
 * already resolved c.var.userId / c.var.deviceId before these run (no per-route
 * auth import per the Canonical Contracts). GET /sync/pull is appended in the
 * next task onto this same router.
 */
export const syncRoutes = new Hono<AppEnv>();

type MutationStatus = "applied" | "conflict" | "duplicate" | "rejected";

type MutationResult = {
  mutationId: string;
  status: MutationStatus;
  reason?: string;
  entity: Record<string, unknown> | null;
};

/** Build the public (camelCase) entity envelope from a stored D1 row. */
function rowToEntity(meta: SyncTableMeta, row: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {
    id: row.id,
    userId: row.user_id,
    rev: row.rev,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    deletedAt: row.deleted_at,
    lastEditedDeviceId: row.last_edited_device_id,
  };
  if (meta.hasProfileId) out.profileId = row.profile_id;
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (col in row) out[camel] = row[col];
  }
  return out;
}

/** Coerce JS payload values to D1-storable scalars: booleans -> 0/1, undefined -> null. */
function normalize(v: unknown): string | number | null {
  if (v === undefined || v === null) return null;
  if (typeof v === "boolean") return v ? 1 : 0;
  return v as string | number;
}

syncRoutes.post("/push", validate("json", pushBodySchema), async (c) => {
  const userId = c.var.userId;
  const { deviceId, mutations } = c.req.valid("json");
  const results: MutationResult[] = [];

  for (const m of mutations) {
    results.push(await applyMutation(c.env.DB, userId, deviceId, m));
  }

  return c.json({ results, serverTime: serverStamp() });
});

/**
 * Apply one mutation in isolation. Resolution order (each step is terminal):
 *   1. idempotency replay (processed_mutations hit -> duplicate, no-op)
 *   2. unknown entity type -> rejected (VALIDATION_FAILED)
 *   3. ownership: payload.userId must equal the authed user -> else rejected FORBIDDEN
 *   4. LWW: stored.updated_at strictly newer than incoming -> conflict (echo server row)
 *   5. apply: upsert (or tombstone on delete) with server-stamped updated_at,
 *      rev = (stored.rev ?? 0) + 1, last_edited_device_id = deviceId
 * The domain write and the processed_mutations record commit together in one
 * db.batch so a replay is always idempotent. rejected/conflict outcomes are also
 * recorded so their replay returns the same prior result as a `duplicate`.
 */
async function applyMutation(
  db: D1Database,
  userId: string,
  deviceId: string,
  m: Mutation,
): Promise<MutationResult> {
  // (1) Idempotency replay — echo the stored result. Scoped to the authed user so a
  // replayed mutationId from another tenant is treated as new (no cross-tenant leak).
  const prior = await getProcessedMutation(db, m.mutationId, userId);
  if (prior) {
    const replay = JSON.parse(prior.result_json) as Omit<MutationResult, "status">;
    return { ...replay, status: "duplicate" };
  }

  const meta = tableForEntityType(m.entityType);
  if (!meta) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: "VALIDATION_FAILED",
      entity: null,
    });
  }

  // (2) Ownership: never trust a client-sent userId.
  const payload = m.payload as Record<string, unknown>;
  if (payload.userId !== userId) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: "FORBIDDEN",
      entity: null,
    });
  }

  // Load the stored row (scoped to the authed user).
  const stored = await db
    .prepare(`SELECT * FROM ${meta.table} WHERE id = ? AND user_id = ?`)
    .bind(m.entityId, userId)
    .first<Record<string, unknown>>();

  // (3) LWW: a server-stamped updated_at strictly newer than the incoming
  // client updatedAt means a later edit already won — echo the server row.
  if (stored && Number(stored.updated_at) > m.updatedAt) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "conflict",
      entity: rowToEntity(meta, stored),
    });
  }

  // (4) Apply.
  const now = serverStamp();
  const newRev = stored ? Number(stored.rev) + 1 : 1;

  if (m.op === "delete") {
    // Tombstone an existing row only (never hard-delete, never insert a shell:
    // domain columns are NOT NULL with no defaults). A delete of a row that does
    // not exist for this user is a recorded no-op (entity: null).
    if (!stored) {
      return recordAndReturn(db, userId, deviceId, m, {
        mutationId: m.mutationId,
        status: "applied",
        entity: null,
      });
    }
    const tombstoned: Record<string, unknown> = {
      ...stored,
      deleted_at: now,
      updated_at: now,
      rev: newRev,
      last_edited_device_id: deviceId,
    };
    const result: MutationResult = {
      mutationId: m.mutationId,
      status: "applied",
      entity: rowToEntity(meta, tombstoned),
    };
    const writeStmt = db
      .prepare(
        `UPDATE ${meta.table}
            SET deleted_at = ?, updated_at = ?, rev = ?, last_edited_device_id = ?
          WHERE id = ? AND user_id = ?`,
      )
      .bind(now, now, newRev, deviceId, m.entityId, userId);
    await db.batch([writeStmt, recordStmt(db, userId, deviceId, m, result)]);
    return result;
  }

  // upsert

  // (5) Guard NOT NULL profile_id: an upsert into a table whose profile_id is NOT NULL
  // (transactions, budgets, mileage_trips, wfh_logs, quotes, tax_settings) that omits
  // profileId would write NULL and throw an unhandled D1 constraint error inside the
  // batch. Reject the mutation cleanly instead. (delete never inserts profile_id, so it
  // only applies on the upsert path.)
  if (PROFILE_ID_REQUIRED.has(m.entityType) && payload.profileId == null) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: "VALIDATION_FAILED",
      entity: null,
    });
  }

  const writeStmt = buildUpsertStmt(db, meta, m, userId, now, newRev, deviceId, stored);

  // Build the canonical row we are persisting so we can echo + record it without
  // a read-back race (the upsert is deterministic from these values).
  const persisted: Record<string, unknown> = {
    id: m.entityId,
    user_id: userId,
    created_at: stored ? Number(stored.created_at) : Number(payload.createdAt ?? now),
    updated_at: now,
    deleted_at: null,
    rev: newRev,
    last_edited_device_id: deviceId,
  };
  if (meta.hasProfileId) persisted.profile_id = normalize(payload.profileId);
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (camel in payload) persisted[col] = normalize(payload[camel]);
    else if (stored && col in stored) persisted[col] = stored[col];
  }

  const result: MutationResult = {
    mutationId: m.mutationId,
    status: "applied",
    entity: rowToEntity(meta, persisted),
  };
  await db.batch([writeStmt, recordStmt(db, userId, deviceId, m, result)]);
  return result;
}

/** Record a terminal (non-applied-via-batch) result, then return it. */
async function recordAndReturn(
  db: D1Database,
  userId: string,
  deviceId: string,
  m: Mutation,
  result: MutationResult,
): Promise<MutationResult> {
  await recordStmt(db, userId, deviceId, m, result).run();
  return result;
}

/**
 * Build the processed_mutations insert statement for a mutation outcome. The
 * stored result_json carries the echoed entity (+ reason) so a later replay
 * reproduces the same result. INSERT OR IGNORE keeps it idempotent.
 */
function recordStmt(
  db: D1Database,
  userId: string,
  deviceId: string,
  m: Mutation,
  result: MutationResult,
): D1PreparedStatement {
  const resultJson = JSON.stringify({
    mutationId: result.mutationId,
    reason: result.reason,
    entity: result.entity,
  });
  return db
    .prepare(
      `INSERT OR IGNORE INTO processed_mutations
         (mutation_id, user_id, device_id, entity_type, entity_id, op, status, result_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      m.mutationId,
      // processed_mutations is server-only; store the authed user, never the payload's.
      userId,
      deviceId,
      m.entityType,
      m.entityId,
      m.op,
      result.status,
      resultJson,
      serverStamp(),
    );
}

function buildUpsertStmt(
  db: D1Database,
  meta: SyncTableMeta,
  m: Mutation,
  userId: string,
  now: number,
  newRev: number,
  deviceId: string,
  stored: Record<string, unknown> | null,
): D1PreparedStatement {
  const payload = m.payload as Record<string, unknown>;

  // Domain columns present in the payload.
  const domainCols: string[] = [];
  const domainVals: (string | number | null)[] = [];
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (camel in payload) {
      domainCols.push(col);
      domainVals.push(normalize(payload[camel]));
    }
  }

  const profileCol = meta.hasProfileId ? ["profile_id"] : [];
  const profileVal = meta.hasProfileId ? [normalize(payload.profileId)] : [];

  const createdAt = stored ? Number(stored.created_at) : Number(payload.createdAt ?? now);

  // Column order: id, user_id, [profile_id], <domain...>, created_at, updated_at, deleted_at, rev, last_edited_device_id
  const insertCols = [
    "id",
    "user_id",
    ...profileCol,
    ...domainCols,
    "created_at",
    "updated_at",
    "deleted_at",
    "rev",
    "last_edited_device_id",
  ];
  const insertVals: (string | number | null)[] = [
    m.entityId,
    userId,
    ...profileVal,
    ...domainVals,
    createdAt,
    now,
    null, // upsert clears any tombstone — a newer edit resurrects the row
    newRev,
    deviceId,
  ];

  // ON CONFLICT update list: profile + domain columns + mutable envelope fields,
  // EXCEPT id/user_id/created_at (immutable on update).
  const updateSet = [
    ...profileCol.map((col) => `${col} = excluded.${col}`),
    ...domainCols.map((col) => `${col} = excluded.${col}`),
    "updated_at = excluded.updated_at",
    "deleted_at = excluded.deleted_at",
    "rev = excluded.rev",
    "last_edited_device_id = excluded.last_edited_device_id",
  ].join(", ");

  const placeholders = insertCols.map(() => "?").join(", ");
  const sql =
    `INSERT INTO ${meta.table} (${insertCols.join(", ")}) VALUES (${placeholders}) ` +
    `ON CONFLICT(id) DO UPDATE SET ${updateSet} WHERE ${meta.table}.user_id = excluded.user_id`;

  return db.prepare(sql).bind(...insertVals);
}

// ===========================================================================
// GET /sync/pull — local-first delta pull (composite keyset + global merge)
// ===========================================================================

/** A pull change envelope: the camelCase entity plus its SPINE `type` tag. */
type PullChange = Record<string, unknown> & {
  type: string;
  id: string;
  updatedAt: number;
};

/**
 * GET /sync/pull?cursor=<opaque>&limit=<n>
 *
 * Delta pull across EVERY syncable table, merged into ONE stream globally ordered
 * by the composite keyset (updatedAt, id) and capped at `limit`. Tombstones
 * (deletedAt != null) ARE included so deletes propagate to the client. Every query
 * is scoped `WHERE user_id = c.var.userId` (tenant isolation).
 *
 * Algorithm:
 *  1. Decode the opaque cursor -> { ts, id } (null = first/full sync, no keyset filter).
 *  2. For each table, fetch up to `limit + 1` rows strictly after the cursor using
 *     the composite predicate `(updated_at > ?) OR (updated_at = ? AND id > ?)`,
 *     ordered by `(updated_at, id)`. The `+1` is the "is there a next page" probe.
 *  3. Merge all per-table results and re-sort globally by `(updatedAt, id)`.
 *  4. Slice to `limit`. `hasMore = merged.length > limit` (some table still had rows
 *     beyond the emitted window). `nextCursor` = the LAST emitted row's (updatedAt, id),
 *     so the next request resumes strictly after it — no row dropped or repeated even
 *     when many rows (across tables) share the same updatedAt.
 *
 * Table names come only from the hardcoded SYNCABLE_TABLES registry (never user
 * input), so the interpolated `${table}` is not an injection vector; user_id, the
 * cursor parts, and the fetch limit are all bound parameters.
 */
syncRoutes.get("/pull", validate("query", pullQuerySchema), async (c) => {
  const userId = c.var.userId;
  const { cursor: rawCursor, limit } = c.req.valid("query");

  // null cursor = first/full sync: start from (-1, "") so every row is "after".
  const cursor: Cursor = decodeCursor(rawCursor) ?? { ts: -1, id: "" };

  // limit + 1 per table: enough to detect hasMore after the global merge slice.
  const fetchN = limit + 1;

  const perTable = await Promise.all(
    Object.entries(SYNCABLE_TABLES).map(async ([type, meta]) => {
      const { results } = await c.env.DB.prepare(
        `SELECT * FROM ${meta.table}
          WHERE user_id = ?1
            AND ( updated_at > ?2 OR (updated_at = ?2 AND id > ?3) )
          ORDER BY updated_at ASC, id ASC
          LIMIT ?4`,
      )
        .bind(userId, cursor.ts, cursor.id, fetchN)
        .all<Record<string, unknown>>();
      return results.map((row): PullChange => ({
        type,
        ...rowToEntity(meta, row),
        id: row.id as string,
        updatedAt: Number(row.updated_at),
      }));
    }),
  );

  // Merge + global composite-keyset sort by (updatedAt, id).
  const merged = perTable.flat().sort((a, b) => {
    if (a.updatedAt !== b.updatedAt) return a.updatedAt - b.updatedAt;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  const hasMore = merged.length > limit;
  const changes = hasMore ? merged.slice(0, limit) : merged;

  const last = changes[changes.length - 1];
  // Advance the cursor to the last emitted row; with nothing emitted, echo the
  // incoming cursor (or re-encode the start sentinel) so the client can re-poll.
  const nextCursor = last
    ? encodeCursor({ ts: last.updatedAt, id: last.id })
    : (rawCursor ?? encodeCursor(cursor));

  return c.json({ changes, nextCursor, hasMore, serverTime: serverStamp() });
});
