import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * HTTP e2e for J10 — device revoke. Signs in TWO devices for one user, revokes
 * device B, and proves B's SESSION FAMILY is dead on the REFRESH path (a refresh
 * with B's refresh token now 401s). Access-token auth is STATELESS
 * (src/middleware/auth.ts verifyBearer only checks the JWT), so B's short-lived
 * access token would still pass — revocation is provable only via refresh.
 * Mirrors e2e/devices.e2e.test.ts boot scaffolding.
 */
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
      "d1",
      "migrations",
      "apply",
      "snapceipt",
      "--local",
      "--persist-to",
      dir,
    ],
    { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-devices-revoke-e2e-"));
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
    try {
      rmSync(persistDir, { recursive: true, force: true });
    } catch {
      /* best-effort cleanup */
    }
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
  try {
    json = text.length ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, json, text };
}

describe("e2e (real HTTP): J10 device revoke kills the revoked session family", () => {
  it("J10: revoking a device kills that device's session family (refresh rejected)", async () => {
    const email = `e2e+${Date.now()}-j10@example.com`;
    const ip = "203.0.113.50";
    // Device A signs in.
    const reqA = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const devA = crypto.randomUUID();
    const verA = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": devA },
      body: { token: reqA.json.devToken },
    });
    const accessA = `Bearer ${verA.json.accessToken}`;
    // Device B signs in (same email; 2nd of the 3/email/hr budget).
    const reqB = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const devB = crypto.randomUUID();
    const verB = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": devB },
      body: { token: reqB.json.devToken },
    });
    const refreshB: string = verB.json.refreshToken;
    // A sees BOTH devices via /auth/me.
    const me = await api("/auth/me", { headers: { authorization: accessA } });
    expect(me.status).toBe(200);
    expect(me.json.devices.some((d: any) => d.id === devB || d.deviceId === devB)).toBe(true);
    // A revokes B (route is DELETE /devices/:id — devB's id is already known).
    const rev = await api(`/devices/${devB}`, { method: "DELETE", headers: { authorization: accessA } });
    expect(rev.status).toBe(200);
    // B's SESSION FAMILY is dead → refreshing with B's refresh token now 401s.
    const refresh = await api("/auth/refresh", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": devB },
      body: { refreshToken: refreshB },
    });
    expect(refresh.status).toBe(401);
    // And B has dropped out of A's device list.
    const me2 = await api("/auth/me", { headers: { authorization: accessA } });
    expect(me2.json.devices.some((d: any) => d.id === devB || d.deviceId === devB)).toBe(false);
  });
});
