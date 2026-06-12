import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const wranglerBin = path.join(repoRoot, "node_modules", "wrangler", "bin", "wrangler.js");
let worker: Unstable_DevWorker;
let baseUrl: string;
let persistDir: string;
const userId = crypto.randomUUID();
const profileId = crypto.randomUUID();
const budgetId = crypto.randomUUID();

function wrangler(args: string[]) {
  execFileSync("node", [wranglerBin, ...args], {
    cwd: repoRoot,
    stdio: "pipe",
    env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" },
  });
}
function sql(stmt: string) {
  wrangler(["d1", "execute", "snapceipt", "--local", "--persist-to", persistDir, "--command", stmt]);
}

beforeAll(async () => {
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-cron-"));
  wrangler(["d1", "migrations", "apply", "snapceipt", "--local", "--persist-to", persistDir]);
  // Seed an over-cap budget with NO alert yet, pinned to the EXACT migrations/0001_init.sql
  // columns (verified): profiles.type (not profile_type); accent_1/2/3 NOT NULL; users.updated_at
  // NOT NULL; budgets requires cap_cents/label. The cron evaluates CURRENT-month spend, so
  // txn_date is computed from "now" (NOT a hardcoded 2026-06 literal — that would date-rot).
  const now = Date.now();
  const deviceId = crypto.randomUUID();
  const thisMonthDay05 = new Date().toISOString().slice(0, 8) + "05"; // YYYY-MM-05, current month
  sql(`INSERT INTO users (id, email, created_at, updated_at) VALUES ('${userId}', 'cron@example.com', ${now}, ${now});`);
  sql(`INSERT INTO profiles (id, user_id, name, type, accent_1, accent_2, accent_3, created_at, updated_at) VALUES ('${profileId}', '${userId}', 'Biz', 'business', '#000', '#111', '#222', ${now}, ${now});`);
  sql(`INSERT INTO budgets (id, user_id, profile_id, label, cap_cents, alert_threshold_pct, created_at, updated_at) VALUES ('${budgetId}', '${userId}', '${profileId}', 'CronCap', 100, 90, ${now}, ${now});`);
  sql(`INSERT INTO transactions (id, user_id, profile_id, cat_key, amount_cents, txn_date, created_at, updated_at) VALUES ('${crypto.randomUUID()}', '${userId}', '${profileId}', 'meals', -500, '${thisMonthDay05}', ${now}, ${now});`);
  // budgetCronLogic stamps alert_sent_at ONLY when at least one eligible device was pushed
  // (push_enabled=1 AND apns_token NOT NULL, not in quiet hours). Without a devices row, pushed
  // stays 0 and the alert is never stamped. apns.sendPush stubs safely (no APNS_KEY → {stub:true}).
  sql(`INSERT INTO devices (id, user_id, platform, apns_token, push_enabled, created_at, updated_at) VALUES ('${deviceId}', '${userId}', 'ios', 'e2e-token', 1, ${now}, ${now});`);

  worker = await unstable_dev(path.join(repoRoot, "src", "index.ts"), {
    config: path.join(repoRoot, "wrangler.jsonc"),
    local: true,
    persistTo: persistDir,
    experimental: { disableExperimentalWarning: true, testScheduled: true },
    vars: {
      E2E_TEST_MODE: "1",
      JWT_SIGNING_KEY: "e2e-signing-key-0123456789-abcdefghijklmnop",
      APPLE_BUNDLE_ID: "com.snapceipt.app",
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
    } catch {}
  }
});

describe("e2e cron: over-cap budget stamps alert_sent_at", () => {
  it("J40: triggering the scheduled handler stamps alert_sent_at (APNs stubbed)", async () => {
    // Trigger the cron via the test-scheduled endpoint.
    const res = await fetch(`${baseUrl}/__scheduled?cron=${encodeURIComponent("0 * * * *")}`);
    expect(res.status).toBeLessThan(500);
    // Read the budget back: alert_sent_at must now be non-null.
    const out = execFileSync(
      "node",
      [
        wranglerBin,
        "d1",
        "execute",
        "snapceipt",
        "--local",
        "--persist-to",
        persistDir,
        "--json",
        "--command",
        `SELECT alert_sent_at FROM budgets WHERE id='${budgetId}';`,
      ],
      { cwd: repoRoot, env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } },
    ).toString();
    const parsed = JSON.parse(out);
    const rows = parsed?.[0]?.results ?? parsed?.results ?? [];
    expect(rows[0]?.alert_sent_at ?? null).not.toBeNull();
  });
});
