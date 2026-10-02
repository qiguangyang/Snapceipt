import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * HTTP END-TO-END RATE-LIMIT TEST for the Snapceipt Worker auth surface.
 *
 * Same `unstable_dev` boot pattern as e2e/auth-edges.e2e.test.ts (verified
 * beforeAll/afterAll/api harness copied verbatim): boots the REAL worker over a
 * real HTTP socket, applies migrations to an isolated persist dir, and drives the
 * auth routes black-box. Proves the per-email rate-limit tier end-to-end:
 *   - J55: the authEmail tier (8/email/hr) trips on the 9th magic-link request
 *     for one email, returning 429 with a Retry-After header. The first eight
 *     come from distinct IPs so the 20/IP/hr ceiling never fires first.
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

describe("e2e (real HTTP): rate-limit tier breach — authEmail 8/email/hr (J55)", () => {
  it("J55: a 9th magic-link request for the same email is rate-limited (429 + Retry-After)", async () => {
    const email = `e2e+${Date.now()}-rl@example.com`;
    // 8 requests from 8 distinct IPs consume the 8/email/hr budget without tripping 20/IP/hr.
    for (let i = 0; i < 8; i++) {
      const r = await api("/auth/magic-link/request", {
        method: "POST", headers: { "cf-connecting-ip": `198.51.100.${10 + i}` }, body: { email },
      });
      expect(r.status).toBe(202);
    }
    const ninth = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": "198.51.100.99" }, body: { email },
    });
    expect(ninth.status).toBe(429);
    // The breach sets a Retry-After header.
    // (header access via a raw fetch since api() only surfaces status/json/text)
    const raw = await fetch(`${baseUrl}/auth/magic-link/request`, {
      method: "POST",
      headers: { "content-type": "application/json", "cf-connecting-ip": "198.51.100.98" },
      body: JSON.stringify({ email }),
    });
    expect(raw.status).toBe(429);
    expect(raw.headers.get("retry-after")).not.toBeNull();
  });
});
