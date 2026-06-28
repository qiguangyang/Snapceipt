/**
 * Hourly D1 -> R2 backup (ops). Pure-ish: db + bucket + nowMs are injected so it is
 * unit-testable without the scheduled() runtime. Reads the full schema + data via a
 * single dump query and stores it as a .sql object partitioned by UTC date. The
 * dump uses sqlite_master for DDL and per-table SELECTs for data so it round-trips
 * via `wrangler d1 execute --file`.
 *
 * SCALE NOTE: the whole dump is accumulated in memory (`parts`) before a single
 * bucket.put. Fine at GA scale; if the DB grows large, switch to a streamed/chunked
 * export (paginate per-table SELECTs + multipart R2 upload) to avoid Worker OOM.
 */

/** R2 object key: d1/snapceipt/<YYYY-MM-DD>/<epoch-ms>.sql (UTC date partition). */
export function backupKey(nowMs: number): string {
  const d = new Date(nowMs);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `d1/snapceipt/${y}-${m}-${day}/${nowMs}.sql`;
}

/** Derive a 256-bit AES-GCM key from an arbitrary secret string (SHA-256 of its UTF-8 bytes).
 *  Lets an operator set any passphrase via `wrangler secret put BACKUP_ENCRYPTION_KEY`. */
async function aesKeyFromSecret(secret: string, usages: ("encrypt" | "decrypt")[]): Promise<CryptoKey> {
  const material = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", material, { name: "AES-GCM" }, false, usages);
}

/** Encrypt the dump as [12-byte IV][AES-256-GCM ciphertext+tag]. The IV is stored inline with the
 *  ciphertext so the object is self-describing for restore. */
export async function encryptBackup(secret: string, plaintext: string): Promise<Uint8Array> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await aesKeyFromSecret(secret, ["encrypt"]);
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plaintext),
  );
  const out = new Uint8Array(iv.length + ciphertext.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(ciphertext), iv.length);
  return out;
}

/** Inverse of encryptBackup — used by ops/tests to verify a backup round-trips. */
export async function decryptBackup(secret: string, data: ArrayBuffer | Uint8Array): Promise<string> {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  const iv = bytes.slice(0, 12);
  const ciphertext = bytes.slice(12);
  const key = await aesKeyFromSecret(secret, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ciphertext);
  return new TextDecoder().decode(plaintext);
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

export async function d1BackupLogic(
  db: D1Database,
  bucket: R2Bucket,
  nowMs: number,
  encryptionKey?: string,
): Promise<void> {
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
  const sql = parts.join("\n");

  // L9: the dump carries password hashes + tokens, so encrypt it at rest with AES-256-GCM when a
  // key is configured. SAFE / no-crash: if the secret isn't set yet, warn and write plaintext (the
  // operator provisions BACKUP_ENCRYPTION_KEY at deploy) — losing a backup window is worse than
  // a temporarily-unencrypted dump in a private ops bucket.
  if (!encryptionKey) {
    console.warn(
      "[d1Backup] BACKUP_ENCRYPTION_KEY is not set — writing the D1 dump UNENCRYPTED. " +
        "Set the secret (`wrangler secret put BACKUP_ENCRYPTION_KEY`) to encrypt backups at rest.",
    );
    await bucket.put(backupKey(nowMs), sql);
    return;
  }
  // Encrypted backups get a distinct `.sql.enc` key so restore tooling never feeds ciphertext to
  // `wrangler d1 execute` by mistake.
  const ciphertext = await encryptBackup(encryptionKey, sql);
  await bucket.put(`${backupKey(nowMs)}.enc`, ciphertext, {
    httpMetadata: { contentType: "application/octet-stream" },
    customMetadata: { enc: "aes-256-gcm" },
  });
}
