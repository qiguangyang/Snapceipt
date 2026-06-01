import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * HTTP e2e for PUT /devices/me — proves the quiet-hours + timezone round-trip
 * over a real socket. Mirrors e2e/snapceipt.e2e.test.ts boot scaffolding.
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-devices-e2e-"));
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

describe("e2e (real HTTP): PUT /devices/me quiet-hours + timezone round-trip", () => {
  it("stores and returns quiet hours + timezone for the authed device", async () => {
    const email = `e2e-dev+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.55";

    const reqRes = await api("/auth/magic-link/request", {
      method: "POST",
      headers: { "cf-connecting-ip": ip },
      body: { email },
    });
    expect(reqRes.status).toBe(202);
    const devToken: string = reqRes.json.devToken;

    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST",
      headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { token: devToken },
    });
    expect(verifyRes.status).toBe(200);
    const accessToken: string = verifyRes.json.accessToken;

    const putRes = await api("/devices/me", {
      method: "PUT",
      headers: { authorization: `Bearer ${accessToken}`, "x-device-id": deviceId },
      body: {
        apnsToken: "e2e-apns-hex",
        quietHoursStartMin: 1320,
        quietHoursEndMin: 420,
        timezone: "Australia/Sydney",
      },
    });
    expect(putRes.status).toBe(200);
    expect(putRes.json.hasApnsToken).toBe(true);
    expect(putRes.json.quietHoursStartMin).toBe(1320);
    expect(putRes.json.quietHoursEndMin).toBe(420);
    expect(putRes.json.timezone).toBe("Australia/Sydney");
  });
});
