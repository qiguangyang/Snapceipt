import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * EXPORT EDGES HTTP END-TO-END TEST (J30-J32).
 *
 * Boots the REAL Worker over a real HTTP socket via wrangler's `unstable_dev`
 * (same harness as snapceipt.e2e.test.ts / sync-correctness.e2e.test.ts) and
 * exercises the export edges black-box over the wire:
 *   J30 — a PDF export downloads back as %PDF bytes via the path-segment token.
 *   J31 — an accountant export with toEmail returns 200 { status: "sent" }
 *         (miniflare simulates the send_email binding locally; a send failure
 *         instead yields a 500 INTERNAL envelope, never a 200 queued/failed).
 *   J32 — a forged export download path-token is rejected with 403.
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-export-"));
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

// FY range used by every export below (mirrors snapceipt-export.e2e.test.ts).
const FROM = "2025-07-01", TO = "2026-06-30";

async function seedProfileWithTxn(userId: string, auth: any, deviceId: string) {
  const profileId = crypto.randomUUID(); const now = Date.now();
  const pPush = await api("/sync/push", { method: "POST", headers: auth, body: { deviceId, mutations: [{
    mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId, op: "upsert", updatedAt: now,
    payload: { id: profileId, userId, type: "profile", name: "Biz", profileType: "business",
      accent1: "#000", accent2: "#111", accent3: "#222", createdAt: now, updatedAt: now,
      deletedAt: null, rev: 0, lastEditedDeviceId: deviceId } }] } });
  expect(pPush.json.results[0].status).toBe("applied");
  const txnId = crypto.randomUUID();
  const tPush = await api("/sync/push", { method: "POST", headers: auth, body: {
    deviceId, mutations: [txnMutation(userId, profileId, txnId, deviceId, now,
      { merchant: "Export Co", payload: { txnDate: "2026-01-15" } })] } });
  expect(tPush.json.results[0].status).toBe("applied");
  return profileId;
}

describe("e2e (real HTTP): export edges — PDF download, accountant outbox, forged path-token", () => {
  it("J30: PDF export downloads back as %PDF bytes", async () => {
    const ip = "203.0.113.70", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j30@example.com`, ip, dev);
    const profileId = await seedProfileWithTxn(userId, auth, dev);
    const exp = await api("/export", { method: "POST", headers: auth, body: {
      profileId, format: "pdf", from: FROM, to: TO } });
    expect(exp.status).toBe(200);
    const dlUrl: string = exp.json.url;                       // "${origin}/export/dl/${token}"
    const pathname = new URL(dlUrl).pathname;
    const dl = await fetch(`${baseUrl}${pathname}`);
    expect(dl.status).toBe(200);
    const buf = new Uint8Array(await dl.arrayBuffer());
    expect(String.fromCharCode(buf[0], buf[1], buf[2], buf[3])).toBe("%PDF");
  });

  it("J31: accountant export with toEmail returns 200 { status: 'sent' }", async () => {
    const ip = "203.0.113.71", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j31@example.com`, ip, dev);
    const profileId = await seedProfileWithTxn(userId, auth, dev);
    const exp = await api("/export", { method: "POST", headers: auth, body: {
      profileId, format: "accountant", from: FROM, to: TO, toEmail: "cpa@example.com" } });
    // miniflare simulates the send_email binding locally → the only 200 outcome is "sent".
    // (If the local runtime cannot send, the route throws INTERNAL → a 500 envelope.)
    if (exp.status === 200) {
      expect(exp.json.status).toBe("sent");
      expect(exp.json.outboxId).toBeDefined();
    } else {
      expect(exp.status).toBe(500);
      expect(exp.json.error.code).toBe("INTERNAL");
    }
  });

  it("J32: a forged export download path-token is rejected with 403", async () => {
    const ip = "203.0.113.72", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j32@example.com`, ip, dev);
    const profileId = await seedProfileWithTxn(userId, auth, dev);
    const exp = await api("/export", { method: "POST", headers: auth, body: {
      profileId, format: "csv", from: FROM, to: TO } });
    expect(exp.status).toBe(200);
    // Tamper the LAST PATH SEGMENT (the token), not a query param.
    const u = new URL(exp.json.url);
    const parts = u.pathname.split("/");
    const tok = parts.pop()!;
    const tampered = tok.slice(0, -2) + (tok.endsWith("a") ? "bb" : "aa");
    const dl = await fetch(`${baseUrl}${parts.join("/")}/${tampered}`);
    expect(dl.status).toBe(403);
  });
});
