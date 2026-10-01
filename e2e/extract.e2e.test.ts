// e2e/extract.e2e.test.ts
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

/**
 * E2E for the extraction + image service. Boots the REAL worker over HTTP via
 * unstable_dev (isolated persist dir + applied migrations), drives the
 * magic-link seam to obtain an access token, then exercises /extract (in
 * E2E_EXTRACT_MODE -> deterministic stub) and /images (POST -> GET, cross-user
 * 404, non-existent-txn -> NULL link but still 200). Mirrors snapceipt.e2e.test.ts.
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
      "d1", "migrations", "apply", "snapceipt", "--local", "--persist-to", dir,
    ],
    { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
  );
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-extract-e2e-"));
  applyMigrations(persistDir);
  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true },
    vars: { E2E_TEST_MODE: "1", E2E_EXTRACT_MODE: "1", JWT_SIGNING_KEY, APPLE_BUNDLE_ID },
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

/** Magic-link sign-in -> { accessToken, userId, deviceId }. */
async function signIn(): Promise<{ accessToken: string; userId: string; deviceId: string }> {
  const email = `extract+${Date.now()}-${Math.random()}@example.com`;
  const deviceId = crypto.randomUUID();
  const ip = "203.0.113.42";
  const reqRes = await fetch(`${baseUrl}/auth/magic-link/request`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: JSON.stringify({ email }),
  });
  const { devToken } = (await reqRes.json()) as { devToken: string };
  const verifyRes = await fetch(`${baseUrl}/auth/magic-link/verify`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": ip, "x-device-id": deviceId },
    body: JSON.stringify({ token: devToken }),
  });
  const session = (await verifyRes.json()) as { accessToken: string; user: { id: string } };
  return { accessToken: session.accessToken, userId: session.user.id, deviceId };
}

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0xff, 0xd9]);

describe("e2e: /extract (stub) + /images round-trip + ownership", () => {
  it("POST /extract in E2E_EXTRACT_MODE returns the canned §9 stub shape", async () => {
    const { accessToken } = await signIn();
    const res = await fetch(`${baseUrl}/extract`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ ocrText: "THE GROUNDS\n28/05/2026\nTOTAL 33.00", source: "scan" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(typeof body.requestId).toBe("string");
    expect(body.receipt.currencyCode).toBe("AUD");
    expect(body.receipt.merchant).toBe("ACME HARDWARE PTY LTD");
    expect(body.receipt.total).toBe(33.0);
    expect(body.receipt.gst).toBe(3.0);
    expect(body.receipt.needsReview).toBe(false);
    expect(body.meta.stub).toBe(true);
    expect(body.meta.source).toBe("scan");
  });

  it("POST /images then GET /images/* round-trips for the owner", async () => {
    const { accessToken, deviceId } = await signIn();
    const post = await fetch(`${baseUrl}/images?width=800&height=1000`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG,
    });
    expect(post.status).toBe(200);
    const { imageKey, getUrl, byteSize } = (await post.json()) as { imageKey: string; getUrl: string; byteSize: number };
    expect(getUrl).toBe(`/images/${imageKey}`);
    expect(byteSize).toBe(JPEG.byteLength);

    const get = await fetch(`${baseUrl}${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
    expect(get.headers.get("content-type")).toBe("image/jpeg");
    expect(new Uint8Array(await get.arrayBuffer()).byteLength).toBe(JPEG.byteLength);
  });

  it("cross-user GET /images/* returns 404", async () => {
    const owner = await signIn();
    const post = await fetch(`${baseUrl}/images`, {
      method: "POST",
      headers: { authorization: `Bearer ${owner.accessToken}`, "content-type": "image/jpeg", "x-device-id": owner.deviceId },
      body: JPEG,
    });
    const { imageKey } = (await post.json()) as { imageKey: string };

    const other = await signIn();
    const get = await fetch(`${baseUrl}/images/${imageKey}`, { headers: { authorization: `Bearer ${other.accessToken}` } });
    expect(get.status).toBe(404);
  });

  it("POST /images with a non-existent transactionId stores NULL but still 200s", async () => {
    const { accessToken, deviceId } = await signIn();
    const res = await fetch(`${baseUrl}/images?transactionId=${crypto.randomUUID()}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/jpeg", "x-device-id": deviceId },
      body: JPEG,
    });
    expect(res.status).toBe(200);
    // The image is still retrievable (saved despite the dangling txn link).
    const { getUrl } = (await res.json()) as { getUrl: string };
    const get = await fetch(`${baseUrl}${getUrl}`, { headers: { authorization: `Bearer ${accessToken}` } });
    expect(get.status).toBe(200);
  });
});
