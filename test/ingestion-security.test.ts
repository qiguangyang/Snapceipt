import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { pruneCrashReports } from "../src/routes/crashReports";
import { d1BackupLogic, decryptBackup, backupKey } from "../src/cron/d1Backup";
import { inboundEmailLogic } from "../src/email/inbound";
import { mintInboxToken, addressForToken } from "../src/lib/inboxToken";

const HOUR_MS = 60 * 60 * 1000;

// ---- shared seeds -----------------------------------------------------------

async function seedAuthed(): Promise<{ bearer: string; userId: string }> {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at) VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at) VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, t, t).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { bearer: `Bearer ${accessToken}`, userId };
}

const baseCrash = {
  kind: "crash" as const,
  appVersion: "0.1.0",
  osVersion: "iOS 18.5",
  deviceModel: "iPhone16,2",
  occurredAt: 1_718_400_000_000,
};

function postCrash(bearer: string, payload: unknown): Promise<Response> {
  return SELF.fetch("https://x/crash-reports", {
    method: "POST",
    headers: { authorization: bearer, "content-type": "application/json" },
    body: JSON.stringify({ ...baseCrash, payload }),
  });
}

// Hermetic email env: stub OCR + stub extraction.
function emailEnv(over: Record<string, unknown> = {}) {
  return { ...env, E2E_EMAIL_MODE: "1", E2E_EXTRACT_MODE: "1", ...over } as typeof env;
}

// multipart/mixed MIME with one base64 image/jpeg attachment.
function mimeWithImage(messageId: string): ArrayBuffer {
  const raw = [
    "From: supplier@example.com",
    "To: receipts@example.com",
    `Message-ID: <${messageId}>`,
    "Subject: invoice",
    "MIME-Version: 1.0",
    'Content-Type: multipart/mixed; boundary="BOUND"',
    "",
    "--BOUND",
    'Content-Type: image/jpeg; name="receipt.jpg"',
    "Content-Transfer-Encoding: base64",
    'Content-Disposition: attachment; filename="receipt.jpg"',
    "",
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBD",
    "--BOUND--",
    "",
  ].join("\r\n");
  return new TextEncoder().encode(raw).buffer as ArrayBuffer;
}

async function seedProInbox(): Promise<{ userId: string; address: string; token: string }> {
  const userId = uuidv7();
  const profileId = uuidv7();
  const t = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, subscription_status, subscription_expires_at, created_at, updated_at)
     VALUES (?, ?, 1, 'pro', 'active', NULL, ?, ?)`,
  ).bind(userId, `${userId}@e.com`, t, t).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at)
     VALUES (?, ?, 'Biz', 'business', '#0', '#1', '#2', ?, ?)`,
  ).bind(profileId, userId, t, t).run();
  const token = await mintInboxToken(env.DB, userId, profileId, t);
  return { userId, address: addressForToken(token), token };
}

beforeEach(async () => {
  // isolatedStorage already gives each test a fresh D1/KV/R2, but clear explicitly for clarity.
  await env.DB.exec("DELETE FROM crash_reports");
  await env.DB.exec("DELETE FROM inbound_email_log");
  await env.DB.exec("DELETE FROM profile_inbox_tokens");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
});

// ---- M3: crash-report ingestion --------------------------------------------

describe("M3 crash-report ingestion hardening", () => {
  it("truncates an oversized payload instead of storing the full row", async () => {
    const { bearer } = await seedAuthed();
    // ~100 KB serialized: under the schema's 256 KB pre-cap (so it passes validation) but well
    // over the 16 KB store cap, so the handler must truncate it.
    const res = await postCrash(bearer, { blob: "a".repeat(100_000) });
    expect(res.status).toBe(201);
    const { id } = (await res.json()) as { id: string };

    const row = await env.DB.prepare("SELECT payload FROM crash_reports WHERE id = ?")
      .bind(id).first<{ payload: string }>();
    expect(row).not.toBeNull();
    // Stored row is bounded (truncated marker + 16 KB preview), not the full ~100 KB blob.
    expect(row!.payload.length).toBeLessThan(20_000);
    const parsed = JSON.parse(row!.payload) as { _truncated?: boolean; _originalBytes?: number };
    expect(parsed._truncated).toBe(true);
    expect(parsed._originalBytes).toBeGreaterThan(100_000);
  });

  it("stores a small payload verbatim (no truncation)", async () => {
    const { bearer } = await seedAuthed();
    const res = await postCrash(bearer, { signal: 11, terminationReason: "SIGSEGV" });
    expect(res.status).toBe(201);
    const { id } = (await res.json()) as { id: string };
    const row = await env.DB.prepare("SELECT payload FROM crash_reports WHERE id = ?")
      .bind(id).first<{ payload: string }>();
    expect(JSON.parse(row!.payload)).toEqual({ signal: 11, terminationReason: "SIGSEGV" });
  });

  it("enforces a tight per-IP rate tier (10/min) on /crash-reports", async () => {
    const { bearer } = await seedAuthed();
    // The crash tier is per-IP (shared "unknown" IP in tests). First 10 succeed; the 11th is 429.
    for (let i = 0; i < 10; i++) {
      const ok = await postCrash(bearer, { signal: 11 });
      expect(ok.status).toBe(201);
    }
    const limited = await postCrash(bearer, { signal: 11 });
    expect(limited.status).toBe(429);
    const body = (await limited.json()) as { error: { code: string } };
    expect(body.error.code).toBe("RATE_LIMITED");
  });

  it("pruneCrashReports deletes rows older than 30 days and keeps recent ones", async () => {
    const { userId } = await seedAuthed();
    const now = nowMs();
    const oldId = uuidv7();
    const freshId = uuidv7();
    const insert = (id: string, createdAt: number) =>
      env.DB.prepare(
        `INSERT INTO crash_reports (id, user_id, device_id, kind, app_version, os_version, device_model, occurred_at, payload, created_at)
         VALUES (?, ?, ?, 'crash', '0.1.0', 'iOS 18.5', 'iPhone16,2', ?, '{}', ?)`,
      ).bind(id, userId, uuidv7(), createdAt, createdAt).run();
    await insert(oldId, now - 40 * 24 * HOUR_MS); // 40 days old -> pruned
    await insert(freshId, now - 24 * HOUR_MS); //     1 day old -> kept

    await pruneCrashReports(env.DB, now);

    const old = await env.DB.prepare("SELECT 1 FROM crash_reports WHERE id = ?").bind(oldId).first();
    const fresh = await env.DB.prepare("SELECT 1 FROM crash_reports WHERE id = ?").bind(freshId).first();
    expect(old).toBeNull();
    expect(fresh).not.toBeNull();
  });
});

// ---- I2: inbound alias-discovery throttle ----------------------------------

describe("I2 inbound alias-discovery throttle", () => {
  it("throttles repeated invalid alias lookups (rate_limited) once the miss budget is spent", async () => {
    const now = nowMs();
    // Pre-seed the global failed-lookup counter at the limit (30) for this window.
    const bucket = Math.floor(now / HOUR_MS);
    await env.KV.put(`rl:inbound-miss:${bucket}`, "30");

    const res = await inboundEmailLogic(emailEnv(), {
      to: "r.deadbeefdeadbeefdeadbeefdeadbeef@in.snapceipt.cc",
      from: "attacker@e.com", messageId: "<probe>", raw: mimeWithImage("probe"),
    }, now);
    expect(res).toEqual({ status: "rejected", reason: "rate_limited" });
    const c = await env.DB.prepare("SELECT COUNT(*) c FROM transactions").first<{ c: number }>();
    expect(c!.c).toBe(0);
  });

  it("does NOT throttle a legitimate forward to a VALID alias even when the miss budget is spent", async () => {
    const now = nowMs();
    const { token } = await seedProInbox();
    // Miss budget fully spent — must not affect a valid alias (it never hits the miss limiter).
    const bucket = Math.floor(now / HOUR_MS);
    await env.KV.put(`rl:inbound-miss:${bucket}`, "999");

    const res = await inboundEmailLogic(emailEnv(), {
      to: addressForToken(token), from: "supplier@e.com", messageId: "<valid>", raw: mimeWithImage("valid"),
    }, now);
    expect(res.status).toBe("created");
  });

  it("does not throttle the first invalid lookups (under budget -> unknown_inbox)", async () => {
    const res = await inboundEmailLogic(emailEnv(), {
      to: "r.nope@in.snapceipt.cc", from: "x@e.com", messageId: "<m>", raw: mimeWithImage("m"),
    }, nowMs());
    expect(res).toEqual({ status: "rejected", reason: "unknown_inbox" });
  });
});

// ---- L9: D1 backup encryption ----------------------------------------------

describe("L9 D1 backup encryption", () => {
  it("encrypts the dump (no plaintext SQL) and round-trips when a key is set", async () => {
    const ms = Date.UTC(2026, 5, 16, 1, 0, 0);
    const secret = "ops-backup-secret-key";
    await d1BackupLogic(env.DB, env.BACKUPS, ms, secret);

    // The plaintext `.sql` key is NOT written; the encrypted `.sql.enc` key is.
    const plain = await env.BACKUPS.get(backupKey(ms));
    expect(plain).toBeNull();
    const enc = await env.BACKUPS.get(`${backupKey(ms)}.enc`);
    expect(enc).not.toBeNull();

    const bytes = await enc!.arrayBuffer();
    // Ciphertext must not contain readable SQL.
    const asText = new TextDecoder().decode(bytes);
    expect(asText).not.toContain("CREATE TABLE");

    // Round-trips: decrypt recovers the real dump.
    const dump = await decryptBackup(secret, bytes);
    expect(dump).toContain("CREATE TABLE");
    expect(dump).toContain("users");
  });

  it("writes an UNENCRYPTED .sql dump (and does not throw) when no key is configured", async () => {
    const ms = Date.UTC(2026, 5, 16, 2, 0, 0);
    await expect(d1BackupLogic(env.DB, env.BACKUPS, ms)).resolves.toBeUndefined();
    const obj = await env.BACKUPS.get(backupKey(ms));
    expect(obj).not.toBeNull();
    const text = await obj!.text();
    expect(text).toContain("CREATE TABLE");
  });
});
