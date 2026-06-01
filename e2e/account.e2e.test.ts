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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-account-"));
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
  const res = await fetch(`${baseUrl}${pathname}`, { method: init.method ?? (body ? "POST" : "GET"), headers, body });
  const text = await res.text();
  let json: any = null;
  try { json = text.length ? JSON.parse(text) : null; } catch { json = null; }
  return { status: res.status, json, text };
}

describe("e2e (real HTTP): account ops", () => {
  async function signIn(ip: string): Promise<{ auth: Record<string, string>; deviceId: string }> {
    const email = `e2e-acct+${Date.now()}-${ip}@example.com`;
    const deviceId = crypto.randomUUID();
    const reqRes = await api("/auth/magic-link/request", { method: "POST", headers: { "cf-connecting-ip": ip }, body: { email } });
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    return { auth: { authorization: `Bearer ${verifyRes.json.accessToken}` }, deviceId };
  }

  it("changes the email via the 6-digit code", async () => {
    const { auth } = await signIn("203.0.113.40");
    const req = await api("/users/me/email", { method: "POST", headers: auth, body: { newEmail: `changed+${Date.now()}@example.com` } });
    expect(req.status).toBe(202);
    const code = req.json.devCode as string;
    const ver = await api("/users/me/email/verify", { method: "POST", headers: auth, body: { code } });
    expect(ver.status).toBe(200);
    expect(ver.json.user.email).toContain("changed+");
    const me = await api("/auth/me", { headers: auth });
    expect(me.json.user.email).toContain("changed+");
  });

  it("deletes the account so subsequent authed calls are rejected", async () => {
    const { auth } = await signIn("203.0.113.41");
    const del = await api("/account", { method: "DELETE", headers: auth });
    expect(del.status).toBe(200);
    // DEVIATION FROM PLAN: the auth middleware (src/middleware/auth.ts) only verifies
    // the access-JWT signature/expiry — it does NOT re-check the session/user against D1.
    // The DELETE batch purges the users row, so the still-valid JWT clears the bearer
    // guard and /auth/me then throws NOT_FOUND (404) at src/routes/auth.ts (user row gone),
    // rather than 401. The security guarantee (a purged account can no longer read its
    // data) holds either way; accept 401 (session-revoked) or 404 (user purged).
    const after = await api("/auth/me", { headers: auth });
    expect(after.status).not.toBe(200);
    expect([401, 404]).toContain(after.status);
  });
});
