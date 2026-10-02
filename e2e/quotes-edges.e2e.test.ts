import { grantLocalPro } from "./helpers/entitlement";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * QUOTE SEND EDGES HTTP END-TO-END TEST (J47).
 *
 * Boots the REAL Worker over a real HTTP socket via wrangler's `unstable_dev`
 * (same harness as quotes.e2e.test.ts) and exercises the invalid-send edges
 * black-box over the wire:
 *   J47a — sending a quote with NO line items is rejected (400) and consumes no
 *          number (the row stays a draft with a null number).
 *   J47b — sending a quote with NO client email is rejected (400).
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-quotes-edges-"));
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
  grantLocalPro(repoRoot, persistDir, ver.json.user.id);
  return { userId: ver.json.user.id as string, auth: { authorization: `Bearer ${ver.json.accessToken}` } };
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

describe("e2e (real HTTP): POST /quotes/:id/send — invalid-send edges (J47)", () => {
  it("J47a: sending a quote with no line items is rejected and consumes no number", async () => {
    const ip = "203.0.113.80", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j47a@example.com`, ip, dev);
    const profileId = await seedProfile(userId, auth, dev);
    const quoteId = crypto.randomUUID();
    // Push a quote with NO line items.
    await api("/sync/push", { method: "POST", headers: auth, body: { deviceId: dev, mutations: [{
      mutationId: crypto.randomUUID(), entityType: "quote", entityId: quoteId, op: "upsert", updatedAt: Date.now(),
      payload: { id: quoteId, userId, profileId, type: "quote", clientName: "C", clientEmail: "c@example.com",
        gstEnabled: false, subtotalCents: 0, gstCents: 0, totalCents: 0, status: "draft",
        createdAt: Date.now(), updatedAt: Date.now(), deletedAt: null, rev: 0, lastEditedDeviceId: dev } }] } });
    const send = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: auth, body: {} });
    expect(send.status).toBe(400);
    // It stays a draft with no minted number.
    const pull = await api("/sync/pull?limit=500", { headers: auth });
    const row = pull.json.changes.find((c: any) => c.id === quoteId);
    expect(row.status).toBe("draft");
    expect(row.number ?? null).toBeNull();
  });

  it("J47b: sending a quote with no client email is rejected", async () => {
    const ip = "203.0.113.81", dev = crypto.randomUUID();
    const { userId, auth } = await signIn(`e2e+${Date.now()}-j47b@example.com`, ip, dev);
    const profileId = await seedProfile(userId, auth, dev);
    const quoteId = crypto.randomUUID(); const lineId = crypto.randomUUID();
    // The line-item wire field is `description` (src/lib/syncTables.ts:156; quote_line_items.description
    // is NOT NULL). `itemDescription` is the Swift-side model name only — using it would leave
    // description empty, the line-item mutation would be REJECTED, and /send would 400 for "no line
    // items" (the WRONG reason) instead of exercising the no-client-email edge.
    const push = await api("/sync/push", { method: "POST", headers: auth, body: { deviceId: dev, mutations: [
      { mutationId: crypto.randomUUID(), entityType: "quote", entityId: quoteId, op: "upsert", updatedAt: Date.now(),
        payload: { id: quoteId, userId, profileId, type: "quote", clientName: "C", clientEmail: "",
          gstEnabled: false, subtotalCents: 1000, gstCents: 0, totalCents: 1000, status: "draft",
          createdAt: Date.now(), updatedAt: Date.now(), deletedAt: null, rev: 0, lastEditedDeviceId: dev } },
      { mutationId: crypto.randomUUID(), entityType: "quoteLineItem", entityId: lineId, op: "upsert", updatedAt: Date.now(),
        payload: { id: lineId, userId, quoteId, type: "quoteLineItem", description: "X", quantity: 1,
          unitPriceCents: 1000, sortOrder: 0, createdAt: Date.now(), updatedAt: Date.now(),
          deletedAt: null, rev: 0, lastEditedDeviceId: dev } } ] } });
    // Assert BOTH mutations applied so /send 400s for the no-client-email reason, not a missing line item.
    expect(push.json.results.every((r: any) => r.status === "applied")).toBe(true);
    const send = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: auth, body: {} });
    expect(send.status).toBe(400);
  });
});
