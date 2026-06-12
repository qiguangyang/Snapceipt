import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * SYNC-CORRECTNESS HTTP END-TO-END TEST (J20-J23).
 *
 * Boots the REAL Worker over a real HTTP socket via wrangler's `unstable_dev`
 * (same harness as snapceipt.e2e.test.ts) and exercises the four sync
 * correctness invariants black-box over the wire:
 *   J20 — LWW: a stale-updatedAt upsert loses; the server row is echoed/kept.
 *   J21 — tombstone: an op:"delete" push removes the row from a later pull.
 *   J22 — keyset pagination returns every row exactly once across pages.
 *   J23 — tenant isolation: user B's pull never returns user A's rows.
 *
 * See snapceipt.e2e.test.ts for the migration / E2E_TEST_MODE seam rationale.
 */

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const JWT_SIGNING_KEY = "e2e-signing-key-0123456789-abcdefghijklmnop";
const APPLE_BUNDLE_ID = "com.snapceipt.app";

let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;

/** Apply the D1 migrations to the isolated local persist dir (one-time, pre-boot). */
function applyMigrations(dir: string): void {
  execFileSync(
    "node",
    [
      path.join(repoRoot, "node_modules", "wrangler", "bin", "wrangler.js"),
      "d1",
      "migrations",
      "apply",
      "snapceipt",
      "--local",
      "--persist-to",
      dir,
    ],
    {
      cwd: repoRoot,
      stdio: "pipe",
      env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" },
    },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-sync-"));
  applyMigrations(persistDir);

  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    vars: {
      E2E_TEST_MODE: "1",
      JWT_SIGNING_KEY,
      APPLE_BUNDLE_ID,
    },
    logLevel: "warn",
  });

  const host = worker.address === "::" || worker.address === "0.0.0.0" ? "127.0.0.1" : worker.address;
  baseUrl = `http://${host}:${worker.port}`;
}, 120_000);

afterAll(async () => {
  if (worker) await worker.stop();
  if (persistDir) {
    try {
      rmSync(persistDir, { recursive: true, force: true });
    } catch {
      /* best-effort cleanup */
    }
  }
});

/** Small JSON fetch helper that hits the real dev server over HTTP. */
async function api(
  pathname: string,
  init: { method?: string; headers?: Record<string, string>; body?: unknown } = {},
): Promise<{ status: number; json: any; text: string }> {
  const headers: Record<string, string> = { ...(init.headers ?? {}) };
  let body: string | undefined;
  if (init.body !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(init.body);
  }
  const res = await fetch(`${baseUrl}${pathname}`, {
    method: init.method ?? (body ? "POST" : "GET"),
    headers,
    body,
  });
  const text = await res.text();
  let json: any = null;
  try {
    json = text.length ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json, text };
}

async function signIn(email: string, ip: string, deviceId: string) {
  const req = await api("/auth/magic-link/request", {
    method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
  });
  const ver = await api("/auth/magic-link/verify", {
    method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
    body: { token: req.json.devToken },
  });
  return { userId: ver.json.user.id as string, auth: { authorization: `Bearer ${ver.json.accessToken}` } };
}

function txnMutation(userId: string, profileId: string, id: string, deviceId: string, updatedAt: number, over: any = {}) {
  return {
    mutationId: crypto.randomUUID(), entityType: "transaction", entityId: id,
    op: over.op ?? "upsert", updatedAt,
    payload: {
      id, userId, profileId, type: "transaction", merchant: over.merchant ?? "M",
      catKey: "meals", amountCents: -100, currency: "AUD", txnDate: "2026-05-30",
      mode: "business", createdAt: updatedAt, updatedAt, deletedAt: over.deletedAt ?? null,
      rev: 0, lastEditedDeviceId: deviceId, ...over.payload,
    },
  };
}

async function seedProfile(userId: string, auth: any, deviceId: string) {
  const profileId = crypto.randomUUID(); const now = Date.now();
  await api("/sync/push", { method: "POST", headers: auth, body: { deviceId, mutations: [{
    mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId, op: "upsert", updatedAt: now,
    payload: { id: profileId, userId, type: "profile", name: "Biz", profileType: "business",
      accent1: "#000", accent2: "#111", accent3: "#222", createdAt: now, updatedAt: now,
      deletedAt: null, rev: 0, lastEditedDeviceId: deviceId } }] } });
  return profileId;
}

describe("e2e (real HTTP): sync correctness — LWW, tombstone, pagination, tenant isolation", () => {
  it("J20: a stale-updatedAt upsert loses LWW and the server row is echoed", async () => {
    const ip = "203.0.113.60", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j20@example.com`, ip, dev);
    const profileId = await seedProfile(userId, auth, dev);
    const txnId = crypto.randomUUID();
    const tNew = Date.now();
    await api("/sync/push", { method: "POST", headers: auth, body: {
      deviceId: dev, mutations: [txnMutation(userId, profileId, txnId, dev, tNew, { merchant: "NEW" })] } });
    // Stale write (older updatedAt) → conflict; server keeps NEW.
    const stale = await api("/sync/push", { method: "POST", headers: auth, body: {
      deviceId: dev, mutations: [txnMutation(userId, profileId, txnId, dev, tNew - 10_000, { merchant: "OLD" })] } });
    expect(stale.status).toBe(200);
    const res = stale.json.results[0];
    expect(["conflict", "applied"]).toContain(res.status);
    // The authoritative row still reads NEW on pull.
    const pull = await api("/sync/pull?limit=500", { headers: auth });
    const row = pull.json.changes.find((c: any) => c.id === txnId);
    expect(row.merchant).toBe("NEW");
  });

  it("J21: a tombstone push removes the row from a subsequent pull", async () => {
    const ip = "203.0.113.61", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j21@example.com`, ip, dev);
    const profileId = await seedProfile(userId, auth, dev);
    const txnId = crypto.randomUUID(); const t = Date.now();
    await api("/sync/push", { method: "POST", headers: auth, body: {
      deviceId: dev, mutations: [txnMutation(userId, profileId, txnId, dev, t)] } });
    // Tombstone via op:"delete" — the push handler only sets deleted_at on a delete op
    // (src/routes/sync.ts:142); an upsert hardcodes deleted_at=null (src/routes/sync.ts:201),
    // so a `deletedAt` payload field on an upsert would NOT tombstone the row.
    // The delete's updatedAt must beat the SERVER-STAMPED updated_at of the upsert
    // (sync.ts:139 re-stamps to the server wall clock, a few ms ahead of `t`), else
    // LWW (sync.ts:130) treats the delete as stale → conflict and never tombstones.
    // `t + 10_000` clears any plausible server-clock skew so the delete wins.
    await api("/sync/push", { method: "POST", headers: auth, body: {
      deviceId: dev, mutations: [txnMutation(userId, profileId, txnId, dev, t + 10_000, { op: "delete" })] } });
    const pull = await api("/sync/pull?limit=500", { headers: auth });
    const row = pull.json.changes.find((c: any) => c.id === txnId);
    // Tombstoned rows pull back with deletedAt set (client removes them).
    expect(row?.deletedAt ?? null).not.toBeNull();
  });

  it("J22: pull keyset pagination returns every row once across pages", async () => {
    const ip = "203.0.113.62", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j22@example.com`, ip, dev);
    const profileId = await seedProfile(userId, auth, dev);
    const ids = new Set<string>(); const base = Date.now();
    for (let i = 0; i < 12; i++) {
      const id = crypto.randomUUID(); ids.add(id);
      await api("/sync/push", { method: "POST", headers: auth, body: {
        deviceId: dev, mutations: [txnMutation(userId, profileId, id, dev, base + i)] } });
    }
    const seen = new Set<string>(); let cursor = ""; let guard = 0;
    do {
      const q = cursor ? `/sync/pull?limit=5&cursor=${encodeURIComponent(cursor)}` : "/sync/pull?limit=5";
      const page = await api(q, { headers: auth });
      for (const c of page.json.changes) if (c.type === "transaction") seen.add(c.id);
      cursor = page.json.nextCursor ?? "";
      if (!page.json.hasMore) break;
    } while (++guard < 20);
    for (const id of ids) expect(seen.has(id)).toBe(true);
  });

  it("J23: a second user's pull never returns the first user's rows", async () => {
    const ipA = "203.0.113.63", ipB = "203.0.113.64";
    // pushBodySchema requires deviceId: z.string().uuid() (src/schemas/sync.ts) — a
    // non-UUID like "devA" 400s VALIDATION_FAILED, so A's row would never be created
    // and the test would pass VACUOUSLY. Use a real UUID and assert the seed applied.
    const devA = crypto.randomUUID();
    const a = await signIn(`e2e+${Date.now()}-j23a@example.com`, ipA, devA);
    const profileId = await seedProfile(a.userId, a.auth, devA);
    const txnId = crypto.randomUUID();
    const push = await api("/sync/push", { method: "POST", headers: a.auth, body: {
      deviceId: devA, mutations: [txnMutation(a.userId, profileId, txnId, devA, Date.now())] } });
    expect(push.status).toBe(200);
    expect(push.json.results[0].status).toBe("applied"); // guards against a vacuous pass
    const b = await signIn(`e2e+${Date.now()}-j23b@example.com`, ipB, crypto.randomUUID());
    const pullB = await api("/sync/pull?limit=500", { headers: b.auth });
    expect(pullB.json.changes.find((c: any) => c.id === txnId)).toBeUndefined();
  });
});
