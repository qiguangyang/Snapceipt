/**
 * Hourly D1 -> R2 backup (ops). Pure-ish: db + bucket + nowMs are injected so it is
 * unit-testable without the scheduled() runtime. Reads the full schema + data via a
 * single dump query and stores it as a .sql object partitioned by UTC date. The
 * dump uses sqlite_master for DDL and per-table SELECTs for data so it round-trips
 * via `wrangler d1 execute --file`.
 */

/** R2 object key: d1/snapceipt/<YYYY-MM-DD>/<epoch-ms>.sql (UTC date partition). */
export function backupKey(nowMs: number): string {
  const d = new Date(nowMs);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `d1/snapceipt/${y}-${m}-${day}/${nowMs}.sql`;
}

/** SQL-escape a value as a literal for the dump (strings single-quoted + doubled). */
function lit(v: unknown): string {
  if (v === null || v === undefined) return "NULL";
  if (typeof v === "number") return String(v);
  if (v instanceof ArrayBuffer) {
    const hex = [...new Uint8Array(v)].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `X'${hex}'`;
  }
  return `'${String(v).replace(/'/g, "''")}'`;
}

export async function d1BackupLogic(db: D1Database, bucket: R2Bucket, nowMs: number): Promise<void> {
  // 1. DDL for every user table (skip sqlite_* + D1 internal + the migrations bookkeeping table).
  const { results: schema } = await db
    .prepare(
      `SELECT name, sql FROM sqlite_master
        WHERE type = 'table'
          AND name NOT LIKE 'sqlite_%'
          AND name NOT LIKE '_cf_%'
          AND name <> 'd1_migrations'
        ORDER BY name`,
    )
    .all<{ name: string; sql: string }>();

  const parts: string[] = [
    `-- Snapceipt D1 dump ${new Date(nowMs).toISOString()}`,
    "PRAGMA foreign_keys=OFF;",
    "BEGIN TRANSACTION;",
  ];

  for (const t of schema) {
    parts.push(`${t.sql};`);
    const { results: rows } = await db.prepare(`SELECT * FROM "${t.name}"`).all<Record<string, unknown>>();
    for (const row of rows) {
      const cols = Object.keys(row);
      const vals = cols.map((c) => lit(row[c])).join(", ");
      parts.push(`INSERT INTO "${t.name}" (${cols.map((c) => `"${c}"`).join(", ")}) VALUES (${vals});`);
    }
  }

  parts.push("COMMIT;", "PRAGMA foreign_keys=ON;", "");
  await bucket.put(backupKey(nowMs), parts.join("\n"));
}
