import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * HTTP END-TO-END TEST for the Snapceipt Worker.
 *
 * Unlike test/integration.test.ts (which drives the worker in-process via
 * `SELF.fetch` inside vitest-pool-workers), this boots the REAL worker over a
 * real HTTP socket using wrangler's programmatic `unstable_dev` (Miniflare /
 * workerd in a child process) and drives the full authenticated flow black-box
 * with the global `fetch` against `http://<address>:<port>`. It proves:
 *   - the backend actually runs as an HTTP server, and
 *   - its wire shapes match the iOS Codable DTO contract (Snapceipt/Sync/DTOs.swift).
 *
 * D1 schema: `unstable_dev` runs Miniflare locally with the wrangler.jsonc
 * bindings but does NOT auto-apply migrations. We make the run self-contained by
 * applying migrations/0001_init.sql to a FRESH isolated persist dir via
 * `wrangler d1 migrations apply snapceipt --local --persist-to <dir>`, then boot
 * `unstable_dev({ persistTo: <dir> })` so the dev server reads that migrated DB.
 * The dir is created per-run (mkdtemp) and removed in afterAll, so the suite
 * never depends on or pollutes the repo's .wrangler/state.
 *
 * Magic-link blocker: the server stores only `ml:<sha256(token)>` and EMAILS the
 * raw token, so a black-box client can't recover it. The e2e-only seam
 * (E2E_TEST_MODE="1", injected here via vars) makes /auth/magic-link/request
 * ALSO return `{ devToken }`. That flag is never set in production.
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

describe("e2e (real HTTP): health -> banks 501 -> auth gate -> magic-link -> push -> pull -> refresh", () => {
  it("GET /health returns 200 { ok: true }", async () => {
    const r = await api("/health");
    expect(r.status).toBe(200);
    expect(r.json.ok).toBe(true);
  });

  it("POST /banks returns 501 NOT_IMPLEMENTED", async () => {
    const r = await api("/banks", { method: "POST", body: {} });
    expect(r.status).toBe(501);
    expect(r.json.error.code).toBe("NOT_IMPLEMENTED");
  });

  it("GET /sync/pull WITHOUT auth returns 401 (auth gate works)", async () => {
    const r = await api("/sync/pull");
    expect(r.status).toBe(401);
  });

  it("drives the full authenticated flow black-box over HTTP", async () => {
    const email = `e2e+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.9";

    // 1. Magic-link request -> 202 with the e2e devToken (seam under E2E_TEST_MODE).
    const reqRes = await api("/auth/magic-link/request", {
      method: "POST",
      headers: { "cf-connecting-ip": ip },
      body: { email },
    });
    expect(reqRes.status).toBe(202);
    const devToken: string = reqRes.json.devToken;
    expect(typeof devToken).toBe("string");
    expect(devToken.length).toBeGreaterThan(0);

    // 2. Verify the token (+ X-Device-Id) -> 200 session envelope.
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST",
      headers: { "cf-connecting-ip": ip, "x-device-id": deviceId },
      body: { token: devToken },
    });
    expect(verifyRes.status).toBe(200);
    const session = verifyRes.json;

    // --- iOS SessionResponse contract: { accessToken, refreshToken, expiresIn, user } ---
    expect(typeof session.accessToken).toBe("string");
    expect(typeof session.refreshToken).toBe("string");
    expect(session.expiresIn).toBe(900);
    expect(typeof session.user.id).toBe("string");
    expect(session.user.email).toBe(email);
    // SessionUser declares displayName (nullable) — the key must be present.
    expect("displayName" in session.user).toBe(true);

    const userId: string = session.user.id;
    const accessToken: string = session.accessToken;
    const authHeaders = { authorization: `Bearer ${accessToken}` };

    // 3a. Push a profile upsert (the transaction's profile_id FK needs it first).
    const profileId = crypto.randomUUID();
    const txnId = crypto.randomUUID();
    const clientUpdatedAt = Date.now();

    const pushProfileRes = await api("/sync/push", {
      method: "POST",
      headers: authHeaders,
      body: {
        deviceId,
        mutations: [
          {
            mutationId: crypto.randomUUID(),
            entityType: "profile",
            entityId: profileId,
            op: "upsert",
            updatedAt: clientUpdatedAt,
            payload: {
              id: profileId,
              userId,
              type: "profile",
              name: "Business",
              profileType: "business",
              accent1: "#000",
              accent2: "#111",
              accent3: "#222",
              createdAt: clientUpdatedAt,
              updatedAt: clientUpdatedAt,
              deletedAt: null,
              rev: 0,
              lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushProfileRes.status).toBe(200);
    expect(pushProfileRes.json.results[0].status).toBe("applied");

    // 3b. Push a transaction upsert referencing the profile.
    const txnMutationId = crypto.randomUUID();
    const pushTxnRes = await api("/sync/push", {
      method: "POST",
      headers: authHeaders,
      body: {
        deviceId,
        mutations: [
          {
            mutationId: txnMutationId,
            entityType: "transaction",
            entityId: txnId,
            op: "upsert",
            updatedAt: clientUpdatedAt,
            payload: {
              id: txnId,
              userId,
              profileId,
              type: "transaction",
              merchant: "Test Cafe",
              catKey: "meals",
              amountCents: -1250,
              currency: "AUD",
              txnDate: "2026-05-30",
              mode: "business",
              createdAt: clientUpdatedAt,
              updatedAt: clientUpdatedAt,
              deletedAt: null,
              rev: 0,
              lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushTxnRes.status).toBe(200);

    // --- iOS PushResponse contract: { results:[{ mutationId, status, reason?, entity }], serverTime } ---
    const pushBody = pushTxnRes.json;
    expect(Array.isArray(pushBody.results)).toBe(true);
    expect(typeof pushBody.serverTime).toBe("number");
    const txnResult = pushBody.results[0];
    expect(txnResult.mutationId).toBe(txnMutationId);
    expect(txnResult.status).toBe("applied");
    expect(txnResult.entity.id).toBe(txnId);
    expect(txnResult.entity.rev).toBe(1);

    // 4. Pull everything -> the profile + transaction come back; hasMore:false.
    const pullRes = await api("/sync/pull?limit=500", { headers: authHeaders });
    expect(pullRes.status).toBe(200);

    // --- iOS PullResponse contract: { changes:[PullChange], nextCursor?, hasMore, serverTime } ---
    const pullBody = pullRes.json;
    expect(Array.isArray(pullBody.changes)).toBe(true);
    expect(pullBody.hasMore).toBe(false);
    expect(typeof pullBody.serverTime).toBe("number");

    const pulledTxn = pullBody.changes.find((ch: any) => ch.id === txnId);
    expect(pulledTxn).toBeDefined();
    // PullChange contract fields: type, id, updatedAt + the fixed sync columns.
    expect(pulledTxn.type).toBe("transaction");
    expect(pulledTxn.id).toBe(txnId);
    expect(typeof pulledTxn.updatedAt).toBe("number");
    expect(pulledTxn.userId).toBe(userId);
    expect(pulledTxn.profileId).toBe(profileId);
    expect(typeof pulledTxn.createdAt).toBe("number");
    expect(pulledTxn.rev).toBe(1);
    expect(pulledTxn.merchant).toBe("Test Cafe");

    const pulledProfile = pullBody.changes.find(
      (ch: any) => ch.id === profileId && ch.type === "profile",
    );
    expect(pulledProfile).toBeDefined();

    // 5. Refresh -> new tokens (rotation): both rotate; access changes.
    const refreshRes = await api("/auth/refresh", {
      method: "POST",
      headers: { "cf-connecting-ip": ip },
      body: { refreshToken: session.refreshToken },
    });
    expect(refreshRes.status).toBe(200);
    const refreshed = refreshRes.json;
    expect(typeof refreshed.accessToken).toBe("string");
    expect(typeof refreshed.refreshToken).toBe("string");
    expect(refreshed.expiresIn).toBe(900);
    // Rotation: a NEW refresh token (the old one is now superseded).
    expect(refreshed.refreshToken).not.toBe(session.refreshToken);
    expect(refreshed.user.id).toBe(userId);
  });
});
