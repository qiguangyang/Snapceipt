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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-export-"));
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

describe("e2e (real HTTP): /export csv -> /export/dl round-trip", () => {
  it("authenticates, pushes a txn, exports csv, and downloads it back", async () => {
    const email = `e2e-export+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.77";

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
    const txnId = crypto.randomUUID();
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
              profileType: "business", accent1: "#000", accent2: "#111", accent3: "#222",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "transaction", entityId: txnId,
            op: "upsert", updatedAt: t,
            payload: {
              id: txnId, userId, profileId, type: "transaction", merchant: "The Grounds",
              catKey: "meals", amountCents: -3300, gstCents: 300, deductiblePct: 50,
              currency: "AUD", txnDate: "2026-05-30", mode: "business",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushRes.status).toBe(200);

    // Export CSV.
    const exportRes = await api("/export", {
      method: "POST", headers: authHeaders,
      body: { profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" },
    });
    expect(exportRes.status).toBe(200);
    expect(typeof exportRes.json.url).toBe("string");
    expect(typeof exportRes.json.expiresAt).toBe("number");

    // Download it back (public, no auth). Parse the pathname instead of slicing
    // the origin: with custom-domain routes in wrangler.jsonc, wrangler dev
    // rewrites the worker-visible origin, so baseUrl-length slicing breaks.
    const dlPath = new URL(exportRes.json.url).pathname;
    const dl = await api(dlPath);
    expect(dl.status).toBe(200);
    expect(dl.text).toContain("date,merchant,category,amount_incl_gst");
    expect(dl.text).toContain("The Grounds");
    expect(dl.text).toContain("-33.00");
  });

  it("rejects accountant format without toEmail (validation reachable over HTTP)", async () => {
    const email = `e2e-export-acct+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.78";
    const reqRes = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };
    const res = await api("/export", {
      method: "POST", headers: authHeaders,
      body: { profileId: crypto.randomUUID(), format: "accountant", from: "2026-05-01", to: "2026-05-31" },
    });
    expect(res.status).toBe(400);
    expect(res.json.error.code).toBe("VALIDATION_FAILED");
  });

  it("returns 403 for a forged download token", async () => {
    const res = await api("/export/dl/not.a.real.token");
    expect(res.status).toBe(403);
  });
});
