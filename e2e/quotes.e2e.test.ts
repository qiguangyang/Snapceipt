import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const JWT_SIGNING_KEY = "e2e-signing-key-0123456789-abcdefghijklmnop";
const APPLE_BUNDLE_ID = "com.snapceipt.app";

let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;

function applyMigrations(dir: string): void {
  execFileSync(
    "node",
    [
      path.join(repoRoot, "node_modules", "wrangler", "bin", "wrangler.js"),
      "d1", "migrations", "apply", "snapceipt", "--local", "--persist-to", dir,
    ],
    { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-quotes-"));
  applyMigrations(persistDir);
  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    vars: { E2E_TEST_MODE: "1", JWT_SIGNING_KEY, APPLE_BUNDLE_ID },
    logLevel: "warn",
  });
  const host = worker.address === "::" || worker.address === "0.0.0.0" ? "127.0.0.1" : worker.address;
  baseUrl = `http://${host}:${worker.port}`;
}, 120_000);

afterAll(async () => {
  if (worker) await worker.stop();
  if (persistDir) {
    try { rmSync(persistDir, { recursive: true, force: true }); } catch { /* best-effort */ }
  }
});

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
  try { json = text.length ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

describe("e2e (real HTTP): POST /quotes/:id/send -> /quotes/dl round-trip", () => {
  it("seeds a quote via /sync, sends it, mints SN-0001, downloads the PDF back", async () => {
    const email = `e2e-quote+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.91";

    const reqRes = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    expect(reqRes.status).toBe(202);
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    expect(verifyRes.status).toBe(200);
    const userId: string = verifyRes.json.user.id;
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };

    const profileId = crypto.randomUUID();
    const quoteId = crypto.randomUUID();
    const li1 = crypto.randomUUID();
    const li2 = crypto.randomUUID();
    const t = Date.now();

    const pushRes = await api("/sync/push", {
      method: "POST", headers: authHeaders,
      body: {
        deviceId,
        mutations: [
          {
            mutationId: crypto.randomUUID(), entityType: "profile", entityId: profileId,
            op: "upsert", updatedAt: t,
            payload: {
              id: profileId, userId, type: "profile", name: "Acme Pty Ltd",
              profileType: "business", abn: "12 345 678 901", gstRegistered: true,
              accent1: "#000", accent2: "#111", accent3: "#222",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quote", entityId: quoteId,
            op: "upsert", updatedAt: t,
            payload: {
              id: quoteId, userId, profileId, type: "quote",
              clientName: "Jane Roe", clientEmail: "jane@example.com",
              gstEnabled: true, currency: "AUD", status: "draft", validUntil: "2026-06-15",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quoteLineItem", entityId: li1,
            op: "upsert", updatedAt: t,
            payload: {
              id: li1, userId, type: "quoteLineItem", quoteId,
              description: "Site inspection", quantity: 1, unitPriceCents: 25000, sortOrder: 0,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quoteLineItem", entityId: li2,
            op: "upsert", updatedAt: t,
            payload: {
              id: li2, userId, type: "quoteLineItem", quoteId,
              description: "Report", quantity: 2, unitPriceCents: 40000, sortOrder: 1,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushRes.status).toBe(200);

    const sendRes = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: authHeaders, body: {} });
    expect(sendRes.status).toBe(200);
    expect(sendRes.json.number).toBe("SN-0001");
    expect(sendRes.json.status).toBe("sent");
    expect(sendRes.json.subtotalCents).toBe(105000);
    expect(sendRes.json.gstCents).toBe(10500);
    expect(sendRes.json.totalCents).toBe(115500);
    expect(typeof sendRes.json.sentAt).toBe("number");
    expect(typeof sendRes.json.pdfUrl).toBe("string");
    expect(sendRes.json.pdfUrl).toContain("/quotes/dl/");

    const dlPath = new URL(sendRes.json.pdfUrl).pathname; // origin-agnostic: wrangler dev rewrites the worker-visible origin when custom-domain routes exist
    const dl = await api(dlPath);
    expect(dl.status).toBe(200);
    expect(dl.text.startsWith("%PDF")).toBe(true);

    const resend = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: authHeaders, body: {} });
    expect(resend.status).toBe(200);
    expect(resend.json.number).toBe("SN-0001");
  });

  it("returns 403 for a forged quote download token", async () => {
    const res = await api("/quotes/dl/not.a.real.token");
    expect(res.status).toBe(403);
  });
});
