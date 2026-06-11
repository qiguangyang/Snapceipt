import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * HTTP END-TO-END EDGE TESTS for the Snapceipt Worker auth surface.
 *
 * Same `unstable_dev` boot pattern as e2e/snapceipt.e2e.test.ts (verified
 * beforeAll/afterAll/api harness copied verbatim): boots the REAL worker over a
 * real HTTP socket, applies migrations to an isolated persist dir, and drives the
 * auth routes black-box. Proves three backend auth edges end-to-end:
 *   - J04: a tampered magic-link token fails verify with a 4xx error envelope.
 *   - J06: replaying an already-rotated refresh token is rejected (reuse detection).
 *   - J51: the GET /auth/magic bridge forwards a valid token and 400s a bad one.
 */

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const JWT_SIGNING_KEY = "e2e-signing-key-0123456789-abcdefghijklmnop";
const APPLE_BUNDLE_ID = "com.snapceipt.app";

let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;

/** Apply the D1 migrations to the isolated local persist dir (one-time, pre-boot). */
function applyMigrations(dir: string): void {
  // Non-interactive: wrangler auto-proceeds without a TTY. CI=1 silences prompts/metrics.
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-"));
  applyMigrations(persistDir);

  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    // E2E-only vars (NOT in wrangler.jsonc): the test seam + a test signing key.
    vars: {
      E2E_TEST_MODE: "1",
      JWT_SIGNING_KEY,
      APPLE_BUNDLE_ID,
    },
    logLevel: "warn",
  });

  // Real HTTP endpoint exposed by the booted workerd dev server.
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

describe("e2e (real HTTP): auth edges — bad magic-link (J04), refresh reuse (J06), magic bridge (J51)", () => {
  it("J04: a tampered magic-link token fails verify with a 4xx error envelope", async () => {
    const email = `e2e+${Date.now()}-j04@example.com`;
    const ip = "203.0.113.41";
    const reqRes = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    expect(reqRes.status).toBe(202);
    const good: string = reqRes.json.devToken;
    // Tamper: flip the last char so the sha256 lookup misses.
    const bad = good.slice(0, -1) + (good.endsWith("a") ? "b" : "a");
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": crypto.randomUUID() },
      body: { token: bad },
    });
    expect(verifyRes.status).toBeGreaterThanOrEqual(400);
    expect(verifyRes.status).toBeLessThan(500);
    expect(verifyRes.json.error).toBeDefined();
    expect(typeof verifyRes.json.error.code).toBe("string");
  });

  it("J06: replaying an already-rotated refresh token is rejected", async () => {
    const email = `e2e+${Date.now()}-j06@example.com`;
    const ip = "203.0.113.42";
    const deviceId = crypto.randomUUID();
    const req = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const verify = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { token: req.json.devToken },
    });
    const firstRefresh: string = verify.json.refreshToken;
    // Rotate once (valid) → first refresh is now superseded.
    const rot1 = await api("/auth/refresh", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { refreshToken: firstRefresh },
    });
    expect(rot1.status).toBe(200);
    expect(rot1.json.refreshToken).not.toBe(firstRefresh);
    // Replay the SUPERSEDED token → must be rejected (reuse detection).
    const replay = await api("/auth/refresh", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { refreshToken: firstRefresh },
    });
    expect(replay.status).toBeGreaterThanOrEqual(400);
    expect(replay.status).toBeLessThan(500);
  });

  it("J51: GET /auth/magic bridge forwards a valid token and 400s a bad one", async () => {
    const email = `e2e+${Date.now()}-j51@example.com`;
    const ip = "203.0.113.43";
    const req = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const token: string = req.json.devToken;
    const ok = await api(`/auth/magic?token=${encodeURIComponent(token)}`);
    expect(ok.status).toBe(200);
    expect(ok.text).toContain("snapceipt://auth/verify");
    expect(ok.text).toContain(token);
    const missing = await api("/auth/magic");
    expect(missing.status).toBe(400);
    expect(missing.text).not.toContain("snapceipt://auth/verify");
  });
});
