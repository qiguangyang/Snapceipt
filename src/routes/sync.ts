import { Hono } from "hono";
import type { AppEnv } from "../env";
import { serverStamp, nowMs } from "../lib/time";
import { getProcessedMutation } from "../lib/db";
import { isSessionLive } from "../lib/sessions";
import { ApiError } from "../lib/errors";
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
import { validateV2Mutation, V2_SYNC_TYPES } from "../lib/v2SyncValidation";

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

/**
 * M2 (security): domain columns that MUST hold a safe integer when present. The
 * push route persists payload values verbatim (normalize() only maps bool->0/1),
 * so without this a client could store arbitrary markup in a numeric column —
 * e.g. a line item's `quantity` / `unit_price_cents` — which later renders into
 * invoice/quote PDFs + CSV exports (stored XSS). A column is guarded if it is a
 * line-item count (`quantity` / `sort_order`) or a money column (`*_cents`). A
 * present, non-null value that is not a safe integer rejects the mutation;
 * absent / null values are left untouched (those are valid optional fields).
 *
 * NB: this is a targeted guard rather than wiring entitySchemaFor() at apply
 * time — the strict per-entity schemas each require `type: z.literal(...)`, but
 * the real iOS encoder omits the `type` key (see the contract regression test in
 * sync-push.test.ts), so validating payloads against them would 400 every real
 * device push. `quoteLineItem` also has no specialized schema at all.
 */
function isGuardedIntegerColumn(col: string): boolean {
  return col === "quantity" || col === "sort_order" || col.endsWith("_cents");
}

/**
 * L4 (security): child entityType -> { payload field carrying its parent id, the
 * parent's table }. Before upserting a child we look the parent up by id ALONE
 * (not user-scoped) and reject ONLY if it EXISTS under a different user_id
 * (cross-tenant attach — the child's NOT NULL FK references the parent id, so a
 * known/guessed foreign parent id would otherwise insert cleanly). An ABSENT
 * parent is allowed: legitimate out-of-order sync (the FK or a later parent sync
 * reconciles it). Table names are hardcoded here (never user input → safe to
 * interpolate, same as the SYNCABLE_TABLES registry).
 */
const CHILD_PARENT_REF: Record<string, { field: string; table: string }> = {
  lineItem: { field: "transactionId", table: "transactions" },
  quoteLineItem: { field: "quoteId", table: "quotes" },
  invoiceLineItem: { field: "invoiceId", table: "invoices" },
  payment: { field: "invoiceId", table: "invoices" },
};

syncRoutes.post("/push", validate("json", pushBodySchema), async (c) => {
  // S4: writes are gated on a still-live session so a signed-out / revoked device can't
  // keep mutating data during the <=15-min access-token window. (Reads /pull are left
  // ungated — the lag there is the accepted GA risk.)
  if (!(await isSessionLive(c.env.DB, c.var.sessionId, nowMs()))) {
    throw new ApiError("AUTH_INVALID_TOKEN", "Session is no longer valid");
  }
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
  const retainOmittedV2Fields = V2_SYNC_TYPES.has(m.entityType);
  const profileId = "profileId" in payload ? payload.profileId
    : retainOmittedV2Fields ? stored?.profile_id : undefined;

  // Validate the merged v2 row after stale-write/delete resolution. Fail only
  // this mutation and record its outcome through the usual idempotency path.
  const v2Error = await validateV2Mutation(db, userId, m, stored);
  if (v2Error) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: v2Error,
      entity: null,
    });
  }

  // (5) Guard NOT NULL profile_id: an upsert into a table whose profile_id is NOT NULL
  // (transactions, budgets, mileage_trips, wfh_logs, quotes, tax_settings) that omits
  // profileId would write NULL and throw an unhandled D1 constraint error inside the
  // batch. Reject the mutation cleanly instead. (delete never inserts profile_id, so it
  // only applies on the upsert path.)
  if (PROFILE_ID_REQUIRED.has(m.entityType) && profileId == null) {
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: "VALIDATION_FAILED",
      entity: null,
    });
  }

  // (5b) Ownership of the referenced profile (CORE DATA RULE): profileId is taken
  // verbatim from the client, so verify it belongs to the caller before persisting a
  // row tagged with it. Without this, a known/guessed foreign profile UUID would create
  // a dangling cross-tenant reference (no data leak — every read re-scopes by user_id —
  // but it violates per-profile ownership).
  if (meta.hasProfileId && profileId != null) {
    const ownProfile = await db
      .prepare("SELECT 1 FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
      .bind(profileId, userId)
      .first();
    if (!ownProfile) {
      return recordAndReturn(db, userId, deviceId, m, {
        mutationId: m.mutationId,
        status: "rejected",
        reason: "FORBIDDEN",
        entity: null,
      });
    }
  }

  // (5c) L4 — child-entity parent ownership: an upsert of a lineItem / quoteLineItem /
  // invoiceLineItem / payment must not attach to ANOTHER user's parent row. Look the
  // parent up by id alone; reject (FORBIDDEN) only if it exists under a different
  // user_id. An absent parent is allowed (out-of-order sync — FK / later sync handles it).
  const parentRef = CHILD_PARENT_REF[m.entityType];
  if (parentRef) {
    const parentId = payload[parentRef.field];
    if (parentId != null) {
      const parent = await db
        .prepare(`SELECT user_id FROM ${parentRef.table} WHERE id = ?`)
        .bind(parentId)
        .first<{ user_id: string }>();
      if (parent && parent.user_id !== userId) {
        return recordAndReturn(db, userId, deviceId, m, {
          mutationId: m.mutationId,
          status: "rejected",
          reason: "FORBIDDEN",
          entity: null,
        });
      }
    }
  }

  // (5d) M2 — reject non-integer values for guarded numeric columns (quantity,
  // sort_order, *_cents). normalize() would otherwise persist arbitrary markup
  // verbatim in a numeric column → stored XSS when it later renders into invoice/
  // quote PDFs + CSV exports. Present-but-null / absent values are left untouched.
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (!(camel in payload)) continue;
    const v = payload[camel];
    if (v == null) continue;
    if (isGuardedIntegerColumn(col) && !Number.isSafeInteger(v)) {
      return recordAndReturn(db, userId, deviceId, m, {
        mutationId: m.mutationId,
        status: "rejected",
        reason: "VALIDATION_FAILED",
        entity: null,
      });
    }
  }

  const writeStmt = buildUpsertStmt(db, meta, m, userId, now, newRev, deviceId, stored, retainOmittedV2Fields);

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
  if (meta.hasProfileId) persisted.profile_id = normalize(profileId);
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (camel in payload) persisted[col] = normalize(payload[camel]);
    else if (stored && col in stored) persisted[col] = stored[col];
  }

  const result: MutationResult = {
    mutationId: m.mutationId,
    status: "applied",
    entity: rowToEntity(meta, persisted),
  };
  try {
    await db.batch([writeStmt, recordStmt(db, userId, deviceId, m, result)]);
  } catch {
    // A DB constraint violation here (e.g. a budget whose category_id references a
    // category that has not synced yet → FOREIGN KEY, or a duplicate-scope budget →
    // UNIQUE) must reject ONLY this mutation — never throw out of /sync/push and 500
    // the whole batch, which makes the client treat the push as transient and silently
    // go offline. The batch rolled back, so nothing was written; record + return a
    // clean rejection (mirrors the PROFILE_ID_REQUIRED pre-check above).
    return recordAndReturn(db, userId, deviceId, m, {
      mutationId: m.mutationId,
      status: "rejected",
      reason: "VALIDATION_FAILED",
      entity: null,
    });
  }
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
  retainOmittedV2Fields: boolean,
): D1PreparedStatement {
  const payload = m.payload as Record<string, unknown>;

  // INSERT columns may include retained v2 values; UPDATE columns are supplied.
  const domainCols: string[] = [];
  const suppliedDomainCols: string[] = [];
  const domainVals: (string | number | null)[] = [];
  for (const [camel, col] of Object.entries(meta.columns)) {
    if (camel in payload) {
      domainCols.push(col);
      suppliedDomainCols.push(col);
      domainVals.push(normalize(payload[camel]));
    } else if (retainOmittedV2Fields && stored && col in stored) {
      // SQLite checks required INSERT values before ON CONFLICT. Supply retained
      // values for insertion, but never add omitted columns to the update set:
      // reference validation may yield to a concurrent server PDF/status write.
      domainCols.push(col);
      domainVals.push(normalize(stored[col]));
    }
  }

  const profileCol = meta.hasProfileId ? ["profile_id"] : [];
  const profileId = "profileId" in payload ? payload.profileId
    : retainOmittedV2Fields ? stored?.profile_id : undefined;
  const profileVal = meta.hasProfileId ? [normalize(profileId)] : [];
  const updateProfileCols = retainOmittedV2Fields && !("profileId" in payload) ? [] : profileCol;

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
    ...updateProfileCols.map((col) => `${col} = excluded.${col}`),
    ...suppliedDomainCols.map((col) => `${col} = excluded.${col}`),
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
