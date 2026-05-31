# Budgets Backend (cron + APNs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add the hourly Cloudflare Worker cron that recomputes monthly budget spend and fires gated APNs push when a budget crosses its alert threshold, plus extend `PUT /devices/me` with quiet-hours + timezone, keeping the full backend suite green.

**Architecture:** A `scheduled(event, env, ctx)` Worker handler runs hourly and calls a pure-ish `budgetCronLogic(db, env, nowMs)` that computes per-budget spend from `transactions`, applies threshold + dedup + per-device quiet-hours rules, and calls `sendPush` for each eligible device. APNs is gated behind an `APNS_KEY` stub seam: absent → log + no-op; present → ES256-signed JWT bearer call to `api.push.apple.com`. The `devices` migration adds quiet-hours minute columns + IANA timezone, surfaced through the existing `PUT /devices/me` upsert.

**Tech Stack:** TypeScript, Cloudflare Workers (Hono), D1 (SQLite), `jose` ES256 (`importPKCS8` + `SignJWT`), Vitest (`@cloudflare/vitest-pool-workers`), e2e via `unstable_dev`.

---

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `migrations/0001_init.sql` | Modify (devices block ~lines 75–94) | Add `quiet_hours_start_min`, `quiet_hours_end_min` (INTEGER nullable), `timezone` (TEXT nullable) to the `devices` CREATE TABLE. |
| `src/env.ts` | Modify (Env type ~lines 8–47) | Add optional `APNS_KEY?`, `APNS_KEY_ID?`, `APNS_TEAM_ID?` bindings (absence = stub mode). |
| `src/lib/apns.ts` | Create | `signApnsJwt(env)` (ES256 JWT, ~50-min token cache) + `sendPush(env, apnsToken, payload)` (stub when no `APNS_KEY`, else POST to APNs). Test seam via `vi.spyOn`. |
| `src/cron/budgetAlert.ts` | Create | `budgetCronLogic(db, env, nowMs)` — per live budget: compute spend, threshold-fire, dedup, quiet-hours suppression, set `alert_sent_at` only if ≥1 device pushed. |
| `src/index.ts` | Modify (whole file, 7 lines) | `export default { fetch: app.fetch, scheduled }`; `scheduled` calls `ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()))`. |
| `src/routes/devices.ts` | Modify (PUT /devices/me, ~lines 16–92) | Extend the zod body + upsert to accept + persist `quietHoursStartMin`, `quietHoursEndMin`, `timezone`. |
| `wrangler.jsonc` | Modify (~after line 7) | Add `"triggers": { "crons": ["0 * * * *"] }`. |
| `test/schema-budgets.test.ts` | Create (test) | Migration test: the three new `devices` columns exist + are nullable. |
| `test/apns.test.ts` | Create (test) | `signApnsJwt` → ES256 JWT carrying `kid`/`iss`; `sendPush` stub no-op without `APNS_KEY`. |
| `test/budgetAlert.test.ts` | Create (test) | `budgetCronLogic` unit suite: spend math, fire, dedup, rollover, quiet hours, push filtering (`sendPush` spied). |
| `test/devices-quiet-hours.test.ts` | Create (test) | `PUT /devices/me` stores quiet hours + tz + token. |
| `e2e/devices.e2e.test.ts` | Create (test) | `PUT /devices/me` round-trip over real HTTP (quiet hours + tz). |

---

### Task 1: Migration — add quiet-hours + timezone columns to `devices`

**Files:**
- Modify: `migrations/0001_init.sql` (devices `CREATE TABLE`, lines 75–90)
- Test: `test/schema-budgets.test.ts` (Create)

The existing devices block (lines 75–90) is:

```sql
CREATE TABLE devices (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  platform              TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios')),
  model                 TEXT,
  os_version            TEXT,
  apns_token            TEXT,
  push_enabled          INTEGER NOT NULL DEFAULT 1,
  last_sync_cursor      INTEGER,
  last_seen_at          INTEGER,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
```

This migration is forward-only and edited in place (the project resets local `.wrangler` D1; tests rebuild from migrations via `applyD1Migrations`).

- [ ] **Step 1: Write the FAILING migration test.** Create `test/schema-budgets.test.ts` with this complete content:

```ts
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

// The migrations array is injected as a Miniflare binding by vitest.config.ts.
declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

async function columnsOf(table: string): Promise<Set<string>> {
  const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
  return new Set(results.map((r) => r.name));
}

describe("devices quiet-hours + timezone columns", () => {
  it("adds quiet_hours_start_min, quiet_hours_end_min, timezone to devices", async () => {
    const cols = await columnsOf("devices");
    for (const c of ["quiet_hours_start_min", "quiet_hours_end_min", "timezone"]) {
      expect(cols.has(c), `devices missing column ${c}`).toBe(true);
    }
  });

  it("makes the three new columns nullable (a device row inserts without them)", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uqh',1,1)`),
      env.DB.prepare(
        `INSERT INTO devices(id,user_id,platform,push_enabled,created_at,updated_at)
         VALUES('dqh','uqh','ios',1,1,1)`,
      ),
    ]);
    const row = await env.DB.prepare(
      `SELECT quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id='dqh'`,
    ).first<{
      quiet_hours_start_min: number | null;
      quiet_hours_end_min: number | null;
      timezone: string | null;
    }>();
    expect(row?.quiet_hours_start_min).toBeNull();
    expect(row?.quiet_hours_end_min).toBeNull();
    expect(row?.timezone).toBeNull();

    // And they round-trip values.
    await env.DB.prepare(
      `UPDATE devices SET quiet_hours_start_min=?, quiet_hours_end_min=?, timezone=? WHERE id='dqh'`,
    )
      .bind(1320, 420, "Australia/Sydney")
      .run();
    const updated = await env.DB.prepare(
      `SELECT quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id='dqh'`,
    ).first<{
      quiet_hours_start_min: number;
      quiet_hours_end_min: number;
      timezone: string;
    }>();
    expect(updated?.quiet_hours_start_min).toBe(1320);
    expect(updated?.quiet_hours_end_min).toBe(420);
    expect(updated?.timezone).toBe("Australia/Sydney");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- schema-budgets`. Expect failure: `devices missing column quiet_hours_start_min` (the columns do not exist yet).

- [ ] **Step 3: Add the three columns to the migration.** In `migrations/0001_init.sql`, replace the `push_enabled` line in the `devices` table with the line plus the three new columns. Change:

```sql
  push_enabled          INTEGER NOT NULL DEFAULT 1,
  last_sync_cursor      INTEGER,
```

to:

```sql
  push_enabled          INTEGER NOT NULL DEFAULT 1,
  quiet_hours_start_min INTEGER,
  quiet_hours_end_min   INTEGER,
  timezone              TEXT,
  last_sync_cursor      INTEGER,
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- schema-budgets`. Expect both tests pass. Also run `npm test -- schema` to confirm the existing `test/schema.test.ts` still passes (devices is not column-pinned there, so it stays green).

- [ ] **Step 5: Commit.**

```bash
git add migrations/0001_init.sql test/schema-budgets.test.ts
git commit -m "$(cat <<'EOF'
Add devices quiet-hours + timezone columns

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Env — add optional APNS bindings

**Files:**
- Modify: `src/env.ts` (Env type, after the `APPLE_BUNDLE_ID` field ~line 29)

There is no test for this task in isolation — it is a pure type addition consumed by Tasks 3 and 4. `tsc --noEmit` is the gate.

- [ ] **Step 1: Add the three optional bindings.** In `src/env.ts`, immediately after the `APPLE_BUNDLE_ID: string;` field (line 29), insert:

```ts
  /**
   * APNs auth-key (.p8 PKCS8 PEM). When undefined/empty, sendPush runs in STUB
   * mode: it logs and returns { stub: true } with no network call. Set via
   * `wrangler secret put APNS_KEY` once the key is provisioned.
   */
  APNS_KEY?: string;
  /** APNs auth-key id (the .p8 Key ID) — the JWT `kid` header. Optional => stub. */
  APNS_KEY_ID?: string;
  /** Apple developer Team ID — the JWT `iss` claim. Optional => stub. */
  APNS_TEAM_ID?: string;
```

- [ ] **Step 2: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors (additive optional fields).

- [ ] **Step 3: Commit.**

```bash
git add src/env.ts
git commit -m "$(cat <<'EOF'
Add optional APNS_KEY/APNS_KEY_ID/APNS_TEAM_ID env bindings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: APNs library — `signApnsJwt` + `sendPush` (stub-gated)

**Files:**
- Create: `src/lib/apns.ts`
- Test: `test/apns.test.ts` (Create)

`jose` 5.10.0 is already a dependency. Verified signatures:
- `importPKCS8(pkcs8: string, alg: string): Promise<KeyLike>` (`jose/dist/types/key/import.d.ts`).
- `new SignJWT(payload).setProtectedHeader(header).sign(key): Promise<string>` (`jose/dist/types/jwt/sign.d.ts`). The spec sets `iat` in the constructor payload (`{ iss, iat }`), NOT via `setIssuedAt()`.

`APPLE_BUNDLE_ID` is the apns-topic (verified: `src/env.ts` line 29, `wrangler.jsonc` line 27 = `"com.snapceipt.app"`). The `vi.spyOn(module, "fn")` seam mirrors `src/lib/email.ts` (verified `test/rateLimit.test.ts` / `test/integration.test.ts`).

- [ ] **Step 1: Write the FAILING test.** Create `test/apns.test.ts` with this complete content:

```ts
import { describe, expect, it } from "vitest";
import { decodeProtectedHeader, decodeJwt } from "jose";
import { signApnsJwt, sendPush, type ApnsPayload } from "../src/lib/apns";
import type { Env } from "../src/env";

// A throwaway ES256 PKCS8 PEM generated for tests only (never a real APNs key).
// Generated via: openssl ecparam -genkey -name prime256v1 -noout
//   | openssl pkcs8 -topk8 -nocrypt
// VERIFIED: this exact literal parses + signs via jose.importPKCS8(.,"ES256")
// + SignJWT().sign(). If a future edit changes it and it fails to parse,
// regenerate with the openssl pipeline above and paste the result.
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

function stubEnv(over: Partial<Env> = {}): Env {
  return {
    APPLE_BUNDLE_ID: "com.snapceipt.app",
    ...over,
  } as Env;
}

const PAYLOAD: ApnsPayload = {
  aps: { alert: { title: "Budget alert", body: "Meals: $90.00 of $100.00 (90%)" }, sound: "default" },
  budgetId: "b1",
  deepLink: "snapceipt://budget/b1",
};

describe("signApnsJwt", () => {
  it("produces an ES256 JWT carrying kid + iss", async () => {
    const env = stubEnv({ APNS_KEY: TEST_P8, APNS_KEY_ID: "KID123", APNS_TEAM_ID: "TEAM456" });
    const jwt = await signApnsJwt(env);
    const header = decodeProtectedHeader(jwt);
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe("KID123");
    const claims = decodeJwt(jwt);
    expect(claims.iss).toBe("TEAM456");
    expect(typeof claims.iat).toBe("number");
  });
});

describe("sendPush (stub seam)", () => {
  it("is a no-op returning { stub: true } when APNS_KEY is absent", async () => {
    const env = stubEnv(); // no APNS_KEY
    const res = await sendPush(env, "devicetokenhex", PAYLOAD);
    expect(res).toEqual({ stub: true });
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- apns`. Expect failure: cannot resolve `../src/lib/apns` (module does not exist).

- [ ] **Step 3: Write the minimal implementation.** Create `src/lib/apns.ts` with this complete content:

```ts
import { SignJWT, importPKCS8 } from "jose";
import type { Env } from "../env";

/** The APNs JSON payload (spec §4.5). */
export interface ApnsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: string;
  };
  budgetId: string;
  deepLink: string;
}

/** sendPush result. `stub` is true when APNS_KEY is absent (no network call made). */
export type SendPushResult = { stub: true } | { stub: false; status: number };

// Module-scoped JWT cache. APNs provider tokens are valid up to 60 min; we
// refresh at ~50 min. Caching is per-isolate and harmless across requests since
// the token only depends on the (static) team/key id + signing key.
let cachedJwt: string | null = null;
let cachedAtMs = 0;
const JWT_TTL_MS = 50 * 60 * 1000;

/**
 * Sign (or return the cached) APNs provider JWT: ES256 over { iss: TEAM, iat },
 * protected header { alg: ES256, kid: KEY_ID }. Caller must ensure env.APNS_KEY,
 * APNS_KEY_ID and APNS_TEAM_ID are present (sendPush gates on APNS_KEY first).
 */
export async function signApnsJwt(env: Env): Promise<string> {
  const now = Date.now();
  if (cachedJwt && now - cachedAtMs < JWT_TTL_MS) return cachedJwt;
  const key = await importPKCS8(env.APNS_KEY as string, "ES256");
  const jwt = await new SignJWT({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })
    .setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID as string })
    .sign(key);
  cachedJwt = jwt;
  cachedAtMs = now;
  return jwt;
}

/**
 * Send one APNs alert push. GATED: when env.APNS_KEY is absent the .p8 is not
 * provisioned, so this logs and returns { stub: true } with NO network call.
 * Otherwise it POSTs to api.push.apple.com with the ES256 bearer JWT, the
 * bundle-id apns-topic, alert push-type, and priority 10.
 */
export async function sendPush(
  env: Env,
  apnsToken: string,
  payload: ApnsPayload,
): Promise<SendPushResult> {
  if (!env.APNS_KEY) {
    console.log(`[apns:stub] would push to ${apnsToken}: ${payload.aps.alert.title}`);
    return { stub: true };
  }
  const jwt = await signApnsJwt(env);
  const res = await fetch(`https://api.push.apple.com/3/device/${apnsToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APPLE_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  return { stub: false, status: res.status };
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- apns`. Expect both tests pass. The cached-JWT module state is fine here: there is exactly one `signApnsJwt` call (the stub test never calls it), so the cache is never read back. NOTE for future test authors: `cachedJwt` is module-scoped and is NOT keyed on env, so a second `signApnsJwt` test that expects different `kid`/`iss` within the same isolate would read the stale cached token and silently pass — such a test must reset module state (re-import via `vi.resetModules()` or assert only the first call). `budgetCronLogic` tests are unaffected: they spy `sendPush` and never reach `signApnsJwt`.

- [ ] **Step 5: Commit.**

```bash
git add src/lib/apns.ts test/apns.test.ts
git commit -m "$(cat <<'EOF'
Add APNs library: ES256 signApnsJwt + stub-gated sendPush

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Budget cron logic — `budgetCronLogic(db, env, nowMs)`

**Files:**
- Create: `src/cron/budgetAlert.ts`
- Test: `test/budgetAlert.test.ts` (Create)

Authoritative math + semantics (spec §4.3, §4.4, §4.6). Verified schema facts:
- `transactions`: `amount_cents INTEGER NOT NULL` (signed; expenses are `< 0`), `txn_date TEXT NOT NULL`, `category_id TEXT`, `month_key TEXT GENERATED ALWAYS AS (substr(txn_date,1,7)) STORED`, `deleted_at INTEGER`, `profile_id`, `user_id` (verified `migrations/0001_init.sql` lines 165–192). The spec says match on `substr(txn_date,1,7)` — we use that expression directly (do not depend on `month_key` existing, though it does).
- `budgets`: `category_id TEXT` (NULL = whole profile), `cap_cents INTEGER NOT NULL`, `alert_threshold_pct INTEGER`, `alert_sent_at INTEGER`, `month_key TEXT` (NULL = recurring), `label TEXT NOT NULL`, `currency`, `profile_id`, `user_id`, `deleted_at` (verified lines 249–270).
- `devices`: `apns_token`, `push_enabled`, `quiet_hours_start_min`, `quiet_hours_end_min`, `timezone` (Task 1), `deleted_at`.

Spend: `SUM` of the magnitude of `amount_cents` over expenses (`amount_cents < 0`) for `(user_id, profile_id, deleted_at IS NULL, substr(txn_date,1,7) == targetMonth, AND (budget.category_id IS NULL → all | else category_id == budget.category_id))`. Target month = `budget.month_key` if set, else the current UTC `YYYY-MM` derived from `nowMs`.

Fire when `spent_cents >= cap_cents * alert_threshold_pct / 100` AND (`alert_sent_at` is NULL OR `UTC-YYYY-MM(alert_sent_at) != targetMonth`). On fire, for each of the user's devices with `push_enabled = 1` AND `apns_token` not null AND NOT currently in quiet hours: `sendPush`. Set `alert_sent_at = nowMs` only if ≥ 1 device was actually pushed.

Quiet hours (§4.6): compute device-local minutes-from-midnight from `nowMs` + `timezone` (IANA) via `Intl.DateTimeFormat`. Null start/end → never quiet. Wrap-around: if `start > end`, quiet = `local >= start OR local < end`; else `start <= local < end`.

The payload (§4.5) `body` is `"<label>: <spent> of <cap> (<pct>%)"`. Money is formatted as AUD dollars with 2 dp (cents/100). `pct` = `Math.round(spent_cents / cap_cents * 100)`.

`sendPush` is imported as a namespace (`import * as apns`) so tests can `vi.spyOn(apns, "sendPush")` — the same seam shape as `emailModule` (verified `test/integration.test.ts` lines 1–3, 24).

- [ ] **Step 1: Write the FAILING test.** Create `test/budgetAlert.test.ts` with this complete content:

```ts
import { env, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as apns from "../src/lib/apns";
import { budgetCronLogic } from "../src/cron/budgetAlert";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const U = "ucron";
const P = "pcron";
const D = "dcron";
// 2026-05-15 06:00:00 UTC — a deterministic "now" for the cron.
const NOW = Date.UTC(2026, 4, 15, 6, 0, 0);

async function seedBase(): Promise<void> {
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM budgets");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM categories");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO users(id,created_at,updated_at) VALUES(?,1,1)`).bind(U),
    env.DB.prepare(
      `INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES(?,?,'Personal','personal','#0E7C72','#DCF0ED','#0A5950',1,1)`,
    ).bind(P, U),
    env.DB.prepare(
      `INSERT INTO devices(id,user_id,platform,apns_token,push_enabled,created_at,updated_at)
       VALUES(?,?,'ios','tok-hex',1,1,1)`,
    ).bind(D, U),
  ]);
}

async function addTxn(id: string, cents: number, date: string, categoryId: string | null): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO transactions(id,user_id,profile_id,cat_key,amount_cents,txn_date,category_id,created_at,updated_at)
     VALUES(?,?,?,'meals',?,?,?,1,1)`,
  )
    .bind(id, U, P, cents, date, categoryId)
    .run();
}

async function addBudget(
  id: string,
  opts: { categoryId?: string | null; capCents: number; thresholdPct?: number; alertSentAt?: number | null; monthKey?: string | null },
): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO budgets(id,user_id,profile_id,category_id,label,period,month_key,cap_cents,alert_threshold_pct,alert_sent_at,created_at,updated_at)
     VALUES(?,?,?,?,?,'monthly',?,?,?,?,1,1)`,
  )
    .bind(
      id,
      U,
      P,
      opts.categoryId ?? null,
      "Meals",
      opts.monthKey ?? null,
      opts.capCents,
      opts.thresholdPct ?? 90,
      opts.alertSentAt ?? null,
    )
    .run();
}

async function alertSentAt(budgetId: string): Promise<number | null> {
  const row = await env.DB.prepare(`SELECT alert_sent_at FROM budgets WHERE id=?`)
    .bind(budgetId)
    .first<{ alert_sent_at: number | null }>();
  return row?.alert_sent_at ?? null;
}

beforeEach(seedBase);

describe("budgetCronLogic", () => {
  it("fires for a whole-profile budget when month spend crosses the threshold; payload asserted", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await addBudget("bw", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -6000, "2026-05-03", null);
    await addTxn("t2", -3000, "2026-05-10", null);
    // Income / positive amounts are ignored.
    await addTxn("t3", 5000, "2026-05-11", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    const [, token, payload] = spy.mock.calls[0]!;
    expect(token).toBe("tok-hex");
    expect(payload.budgetId).toBe("bw");
    expect(payload.deepLink).toBe("snapceipt://budget/bw");
    expect(payload.aps.alert.title).toBe("Budget alert");
    expect(payload.aps.alert.body).toBe("Meals: $90.00 of $100.00 (90%)");
    expect(await alertSentAt("bw")).toBe(NOW);
  });

  it("scopes spend per category for a per-category budget", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await env.DB.prepare(
      `INSERT INTO categories(id,user_id,profile_id,key,label,icon,tint,soft,created_at,updated_at)
       VALUES('cat1',?,?,'meals','Meals','fork','#111','#222',1,1)`,
    ).bind(U, P).run();
    await addBudget("bc", { categoryId: "cat1", capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -9500, "2026-05-03", "cat1"); // counts
    await addTxn("t2", -9000, "2026-05-04", null);   // other category — ignored

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(spy.mock.calls[0]![2].budgetId).toBe("bc");
  });

  it("does NOT fire below threshold", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await addBudget("bu", { categoryId: null, capCents: 10000, thresholdPct: 90 });
    await addTxn("t1", -8000, "2026-05-03", null); // 80% < 90%

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bu")).toBeNull();
  });

  it("dedups: a same-month alert_sent_at suppresses a re-send", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    const earlierThisMonth = Date.UTC(2026, 4, 12, 0, 0, 0);
    await addBudget("bd", { categoryId: null, capCents: 10000, alertSentAt: earlierThisMonth });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bd")).toBe(earlierThisMonth); // unchanged
  });

  it("re-arms after a month rollover (alert_sent_at in a prior month)", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    const lastMonth = Date.UTC(2026, 3, 20, 0, 0, 0); // 2026-04
    await addBudget("br", { categoryId: null, capCents: 10000, alertSentAt: lastMonth });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("br")).toBe(NOW);
  });

  it("suppresses pushes during quiet hours and leaves alert_sent_at unset", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    // NOW = 06:00 UTC = 16:00 Australia/Sydney (UTC+10, no DST in May).
    // Quiet window 15:00 (900) -> 17:00 (1020) covers 16:00 -> suppressed.
    await env.DB.prepare(
      `UPDATE devices SET timezone='Australia/Sydney', quiet_hours_start_min=900, quiet_hours_end_min=1020 WHERE id=?`,
    ).bind(D).run();
    await addBudget("bq", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bq")).toBeNull(); // not set — next run outside quiet hours delivers
  });

  it("delivers when the device is OUTSIDE its wrap-around quiet window", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    // 16:00 Sydney with a 22:00 (1320) -> 07:00 (420) wrap window: 16:00 is awake.
    await env.DB.prepare(
      `UPDATE devices SET timezone='Australia/Sydney', quiet_hours_start_min=1320, quiet_hours_end_min=420 WHERE id=?`,
    ).bind(D).run();
    await addBudget("bw2", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).toHaveBeenCalledTimes(1);
    expect(await alertSentAt("bw2")).toBe(NOW);
  });

  it("skips devices with push_enabled=0 or a null apns_token", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: true });
    await env.DB.prepare(`UPDATE devices SET push_enabled=0 WHERE id=?`).bind(D).run();
    // A second device with no token.
    await env.DB.prepare(
      `INSERT INTO devices(id,user_id,platform,apns_token,push_enabled,created_at,updated_at)
       VALUES('d2',?,'ios',NULL,1,1,1)`,
    ).bind(U).run();
    await addBudget("bf", { categoryId: null, capCents: 10000 });
    await addTxn("t1", -9500, "2026-05-03", null);

    await budgetCronLogic(env.DB, env, NOW);

    expect(spy).not.toHaveBeenCalled();
    expect(await alertSentAt("bf")).toBeNull(); // no device pushed -> unset
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- budgetAlert`. Expect failure: cannot resolve `../src/cron/budgetAlert` (module does not exist).

- [ ] **Step 3: Write the minimal implementation.** Create `src/cron/budgetAlert.ts` with this complete content:

```ts
import type { Env } from "../env";
import * as apns from "../lib/apns";

interface BudgetRow {
  id: string;
  user_id: string;
  profile_id: string;
  category_id: string | null;
  label: string;
  month_key: string | null;
  cap_cents: number;
  alert_threshold_pct: number;
  alert_sent_at: number | null;
}

interface DeviceRow {
  apns_token: string;
  timezone: string | null;
  quiet_hours_start_min: number | null;
  quiet_hours_end_min: number | null;
}

/** UTC `YYYY-MM` for an epoch-ms instant. */
function utcMonthKey(ms: number): string {
  const d = new Date(ms);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

/** AUD dollars with 2 dp from signed/unsigned cents. */
function fmtMoney(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/**
 * Device-local minutes-from-midnight at `ms` in the given IANA timezone, using
 * Intl (available under workerd). Falls back to UTC when timezone is null.
 */
function localMinutes(ms: number, timezone: string | null): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone ?? "UTC",
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(new Date(ms));
  const hour = Number(parts.find((p) => p.type === "hour")?.value ?? "0") % 24;
  const minute = Number(parts.find((p) => p.type === "minute")?.value ?? "0");
  return hour * 60 + minute;
}

/** True if the device is currently in its quiet window (spec §4.6). */
function inQuietHours(device: DeviceRow, nowMs: number): boolean {
  const { quiet_hours_start_min: start, quiet_hours_end_min: end } = device;
  if (start === null || end === null) return false;
  const local = localMinutes(nowMs, device.timezone);
  if (start > end) return local >= start || local < end; // wrap-around
  return local >= start && local < end;
}

/**
 * Hourly budget-alert cron core (spec §4.3–4.6). Pure-ish: db + env + nowMs are
 * injected so it is unit-testable without the scheduled() runtime. For each live
 * budget it computes month spend, fires when over the threshold (unless already
 * alerted this month), pushes to each eligible non-quiet device, and stamps
 * alert_sent_at only when at least one device was actually pushed.
 */
export async function budgetCronLogic(db: D1Database, env: Env, nowMs: number): Promise<void> {
  const { results: budgets } = await db
    .prepare(
      `SELECT id, user_id, profile_id, category_id, label, month_key, cap_cents,
              alert_threshold_pct, alert_sent_at
         FROM budgets
        WHERE deleted_at IS NULL AND cap_cents > 0`,
    )
    .all<BudgetRow>();

  for (const b of budgets) {
    const targetMonth = b.month_key ?? utcMonthKey(nowMs);

    // Already alerted this month? (dedup; month rollover re-arms.)
    if (b.alert_sent_at !== null && utcMonthKey(b.alert_sent_at) === targetMonth) continue;

    // Spend = magnitude of expense cents for this profile + month (+ category).
    const spendRow = await db
      .prepare(
        `SELECT COALESCE(SUM(-amount_cents), 0) AS spent
           FROM transactions
          WHERE user_id = ? AND profile_id = ? AND deleted_at IS NULL
            AND amount_cents < 0
            AND substr(txn_date,1,7) = ?
            AND (? IS NULL OR category_id = ?)`,
      )
      .bind(b.user_id, b.profile_id, targetMonth, b.category_id, b.category_id)
      .first<{ spent: number }>();
    const spent = spendRow?.spent ?? 0;

    // Fire threshold: spent >= cap * pct / 100.
    if (spent * 100 < b.cap_cents * b.alert_threshold_pct) continue;

    // Eligible devices: push_enabled, token present, not currently quiet.
    const { results: devices } = await db
      .prepare(
        `SELECT apns_token, timezone, quiet_hours_start_min, quiet_hours_end_min
           FROM devices
          WHERE user_id = ? AND deleted_at IS NULL
            AND push_enabled = 1 AND apns_token IS NOT NULL`,
      )
      .bind(b.user_id)
      .all<DeviceRow>();

    const pct = Math.round((spent / b.cap_cents) * 100);
    const payload: apns.ApnsPayload = {
      aps: {
        alert: {
          title: "Budget alert",
          body: `${b.label}: ${fmtMoney(spent)} of ${fmtMoney(b.cap_cents)} (${pct}%)`,
        },
        sound: "default",
      },
      budgetId: b.id,
      deepLink: `snapceipt://budget/${b.id}`,
    };

    let pushed = 0;
    for (const d of devices) {
      if (inQuietHours(d, nowMs)) continue;
      await apns.sendPush(env, d.apns_token, payload);
      pushed++;
    }

    // Stamp only if at least one device was actually pushed (quiet-suppressed
    // budgets re-fire on the next hourly run outside the quiet window).
    if (pushed > 0) {
      await db.prepare(`UPDATE budgets SET alert_sent_at = ? WHERE id = ?`).bind(nowMs, b.id).run();
    }
  }
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- budgetAlert`. Expect all 8 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add src/cron/budgetAlert.ts test/budgetAlert.test.ts
git commit -m "$(cat <<'EOF'
Add budget-alert cron logic with threshold, dedup, and quiet hours

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire the `scheduled` handler + the cron trigger

**Files:**
- Modify: `src/index.ts` (whole file)
- Modify: `wrangler.jsonc` (add `triggers` after `observability`, line 7)

The current `src/index.ts` (verified, 7 lines) is:

```ts
import { app } from "./app";

// Worker entrypoint. fetch only for now; email + scheduled handlers land
// with the email-in and budget-push phases.
export default {
  fetch: app.fetch,
};
```

The `scheduled` handler is NOT directly invocable in vitest-pool-workers, so this task has no unit test — the cron core is covered by Task 4. The gate is `npm run typecheck` plus the full suite staying green.

- [ ] **Step 1: Replace `src/index.ts`.** Overwrite the whole file with:

```ts
import { app } from "./app";
import type { Env } from "./env";
import { budgetCronLogic } from "./cron/budgetAlert";

/**
 * Hourly scheduled handler (wrangler.jsonc triggers.crons = "0 * * * *").
 * Runs the budget-alert cron core with the current epoch-ms; waitUntil keeps the
 * isolate alive until the recompute + APNs sends settle. Errors are logged (a
 * thrown error would surface in the cron dashboard); the next hourly run retries.
 */
const scheduled: ExportedHandlerScheduledHandler<Env> = (_event, env, ctx) => {
  ctx.waitUntil(budgetCronLogic(env.DB, env, Date.now()));
};

// Worker entrypoint: HTTP fetch + the hourly budget-push scheduled handler.
export default {
  fetch: app.fetch,
  scheduled,
};
```

- [ ] **Step 2: Add the cron trigger to `wrangler.jsonc`.** After the `"observability": { "enabled": true },` line (line 7), insert:

```jsonc
  "triggers": { "crons": ["0 * * * *"] },
```

- [ ] **Step 3: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors. `ExportedHandlerScheduledHandler<Env, Props>` is a verified global from `@cloudflare/workers-types` (the `"types": ["@cloudflare/workers-types"]` default `index.d.ts`, line ~503): its signature is `(controller: ScheduledController, env: Env, ctx: ExecutionContext) => void | Promise<void>`, so the `(_event, env, ctx) => { ctx.waitUntil(...) }` form above type-checks exactly (the first param is the `ScheduledController`, deliberately unused). No fallback is needed.

- [ ] **Step 4: Run the full unit suite — expect GREEN (249 = 237 baseline + 12 from the three new files).** Run `npm test`. Expect all pass; specifically the new `schema-budgets` (2), `apns` (2), `budgetAlert` (8) files are green and the prior 237 are unaffected. (`test/devices-quiet-hours.test.ts` and the e2e file land in Tasks 6–7, so they are NOT in this count yet.) The scheduled handler is not collected by any test; this step proves the new wiring did not break the app boot / config parse.

- [ ] **Step 5: Commit.**

```bash
git add src/index.ts wrangler.jsonc
git commit -m "$(cat <<'EOF'
Wire hourly scheduled budget-push handler + cron trigger

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Extend `PUT /devices/me` with quiet hours + timezone

**Files:**
- Modify: `src/routes/devices.ts` (PUT /devices/me handler, lines 16–92)
- Test: `test/devices-quiet-hours.test.ts` (Create)

The existing handler (verified `src/routes/devices.ts`) destructures `{ apnsToken, osVersion, model, pushEnabled }`, runs a keyed upsert with `ON CONFLICT(id) DO UPDATE`, and returns a device-state JSON. We add the three new optional fields to the zod body, the INSERT column list + binds, the `DO UPDATE SET` clause (with `COALESCE` so a partial update never clobbers an existing value), and the response. The `validate("json", putBody)` middleware (verified `validate` is exported from `src/routes/auth.ts` line 33) already throws `VALIDATION_FAILED` on a bad body.

- [ ] **Step 1: Write the FAILING test.** Create `test/devices-quiet-hours.test.ts` with this complete content:

```ts
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedAuthedDevice() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, ?, 'free', ?, ?)`,
  )
    .bind(userId, "qh@example.com", "QH User", now, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  )
    .bind(deviceId, userId, now, now)
    .run();
  const { accessToken } = await issueSession(env.DB, {
    userId,
    deviceId,
    signingKey: env.JWT_SIGNING_KEY,
  });
  return { userId, deviceId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("PUT /devices/me — quiet hours + timezone", () => {
  it("persists quietHoursStartMin/quietHoursEndMin/timezone alongside apnsToken", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();

    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({
        apnsToken: "apns-hex-1",
        quietHoursStartMin: 1320,
        quietHoursEndMin: 420,
        timezone: "Australia/Sydney",
      }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      `SELECT apns_token, quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{
        apns_token: string;
        quiet_hours_start_min: number;
        quiet_hours_end_min: number;
        timezone: string;
      }>();
    expect(row?.apns_token).toBe("apns-hex-1");
    expect(row?.quiet_hours_start_min).toBe(1320);
    expect(row?.quiet_hours_end_min).toBe(420);
    expect(row?.timezone).toBe("Australia/Sydney");
  });

  it("a partial update does not clobber previously-stored quiet hours", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();
    const put = (body: unknown) =>
      SELF.fetch("https://x/devices/me", {
        method: "PUT",
        headers: {
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
          "x-device-id": deviceId,
        },
        body: JSON.stringify(body),
      });

    await put({ quietHoursStartMin: 1320, quietHoursEndMin: 420, timezone: "Australia/Perth" });
    // A later call that only updates the token must keep the quiet hours.
    const res = await put({ apnsToken: "tok-2" });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      `SELECT apns_token, quiet_hours_start_min, quiet_hours_end_min, timezone FROM devices WHERE id = ?`,
    )
      .bind(deviceId)
      .first<{
        apns_token: string;
        quiet_hours_start_min: number;
        quiet_hours_end_min: number;
        timezone: string;
      }>();
    expect(row?.apns_token).toBe("tok-2");
    expect(row?.quiet_hours_start_min).toBe(1320);
    expect(row?.quiet_hours_end_min).toBe(420);
    expect(row?.timezone).toBe("Australia/Perth");
  });

  it("rejects an out-of-range quietHoursStartMin with 400 VALIDATION_FAILED", async () => {
    const { accessToken, deviceId } = await seedAuthedDevice();
    const res = await SELF.fetch("https://x/devices/me", {
      method: "PUT",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
        "x-device-id": deviceId,
      },
      body: JSON.stringify({ quietHoursStartMin: 5000 }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as { error: { code: string } }).error.code).toBe("VALIDATION_FAILED");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- devices-quiet-hours`. Expect failures: the first two assert columns that the handler never writes (so they stay `null`), and the third returns 200 (no range validation yet).

`appVersion` stays in the schema but is intentionally NOT persisted (there is no `app_version` column on `devices`; the current handler already accepts-and-ignores it). Keep that behavior — do not add an `app_version` column.

- [ ] **Step 3: Extend the zod body.** In `src/routes/devices.ts`, replace the `putBody` schema (lines 16–22):

```ts
const putBody = z.object({
  apnsToken: z.string().min(1).optional(),
  appVersion: z.string().optional(),
  osVersion: z.string().optional(),
  model: z.string().optional(),
  pushEnabled: z.boolean().optional(),
});
```

with:

```ts
const putBody = z.object({
  apnsToken: z.string().min(1).optional(),
  appVersion: z.string().optional(),
  osVersion: z.string().optional(),
  model: z.string().optional(),
  pushEnabled: z.boolean().optional(),
  quietHoursStartMin: z.number().int().min(0).max(1439).optional(),
  quietHoursEndMin: z.number().int().min(0).max(1439).optional(),
  timezone: z.string().min(1).optional(),
});
```

- [ ] **Step 4: Destructure + persist the new fields.** In the same handler, replace the destructure line (line 37):

```ts
  const { apnsToken, osVersion, model, pushEnabled } = c.req.valid("json");
```

with:

```ts
  const { apnsToken, osVersion, model, pushEnabled, quietHoursStartMin, quietHoursEndMin, timezone } =
    c.req.valid("json");
```

Then replace the upsert + bind block (lines 40–64) — the whole `await c.env.DB.prepare(...).bind(...).run();` statement — with:

```ts
  await c.env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, model, os_version, apns_token, push_enabled,
                          quiet_hours_start_min, quiet_hours_end_min, timezone,
                          last_seen_at, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, COALESCE(?, 1), ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       model                 = COALESCE(excluded.model, devices.model),
       os_version            = COALESCE(excluded.os_version, devices.os_version),
       apns_token            = COALESCE(excluded.apns_token, devices.apns_token),
       push_enabled          = COALESCE(excluded.push_enabled, devices.push_enabled),
       quiet_hours_start_min = COALESCE(excluded.quiet_hours_start_min, devices.quiet_hours_start_min),
       quiet_hours_end_min   = COALESCE(excluded.quiet_hours_end_min, devices.quiet_hours_end_min),
       timezone              = COALESCE(excluded.timezone, devices.timezone),
       last_seen_at          = excluded.last_seen_at,
       updated_at            = excluded.updated_at,
       deleted_at            = NULL
     WHERE devices.user_id = excluded.user_id`,
  )
    .bind(
      deviceId,
      userId,
      model ?? null,
      osVersion ?? null,
      apnsToken ?? null,
      pushEnabled !== undefined ? (pushEnabled ? 1 : 0) : null,
      quietHoursStartMin ?? null,
      quietHoursEndMin ?? null,
      timezone ?? null,
      now,
      now,
      now,
    )
    .run();
```

- [ ] **Step 5: Surface the new fields on the response.** Replace the SELECT (lines 66–79) and the response (lines 83–91). First the SELECT:

```ts
  const row = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled, last_seen_at
       FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  )
    .bind(deviceId, userId)
    .first<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      apns_token: string | null;
      push_enabled: number;
      last_seen_at: number | null;
    }>();
```

becomes:

```ts
  const row = await c.env.DB.prepare(
    `SELECT id, platform, model, os_version, apns_token, push_enabled,
            quiet_hours_start_min, quiet_hours_end_min, timezone, last_seen_at
       FROM devices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  )
    .bind(deviceId, userId)
    .first<{
      id: string;
      platform: string;
      model: string | null;
      os_version: string | null;
      apns_token: string | null;
      push_enabled: number;
      quiet_hours_start_min: number | null;
      quiet_hours_end_min: number | null;
      timezone: string | null;
      last_seen_at: number | null;
    }>();
```

Then the response:

```ts
  return c.json({
    id: row.id,
    platform: row.platform,
    model: row.model,
    osVersion: row.os_version,
    hasApnsToken: row.apns_token !== null,
    pushEnabled: row.push_enabled === 1,
    lastSeenAt: row.last_seen_at,
  });
```

becomes:

```ts
  return c.json({
    id: row.id,
    platform: row.platform,
    model: row.model,
    osVersion: row.os_version,
    hasApnsToken: row.apns_token !== null,
    pushEnabled: row.push_enabled === 1,
    quietHoursStartMin: row.quiet_hours_start_min,
    quietHoursEndMin: row.quiet_hours_end_min,
    timezone: row.timezone,
    lastSeenAt: row.last_seen_at,
  });
```

- [ ] **Step 6: Run the new + existing devices tests — expect PASS.** Run `npm test -- devices-quiet-hours devices`. Expect all pass (the existing `test/devices.test.ts` is unaffected — its asserted response fields are a subset).

- [ ] **Step 7: Commit.**

```bash
git add src/routes/devices.ts test/devices-quiet-hours.test.ts
git commit -m "$(cat <<'EOF'
Persist quiet hours + timezone on PUT /devices/me

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: e2e — `PUT /devices/me` round-trip over real HTTP

**Files:**
- Create: `e2e/devices.e2e.test.ts`

This boots the real worker via `unstable_dev` and applies migrations to an isolated persist dir, mirroring `e2e/snapceipt.e2e.test.ts` exactly (verified lines 1–124): the `applyMigrations` helper, the `unstable_dev` boot with `E2E_TEST_MODE="1"`, the `api()` JSON helper, and the magic-link `devToken` seam to get an authed session. The `scheduled()` handler is intentionally NOT exercised here (it is not invocable in this runtime; the cron is covered by Task 4's pure-function unit tests). This is a new file, so it does not touch the existing e2e count (12) beyond adding to it.

- [ ] **Step 1: Write the e2e test.** Create `e2e/devices.e2e.test.ts` with this complete content:

```ts
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
```

- [ ] **Step 2: Run the e2e test — expect PASS.** Run `npm run test:e2e -- devices`. Expect the single test passes (boots a worker, signs in, round-trips the device update).

- [ ] **Step 3: Run the full e2e suite — expect GREEN (13 = 12 + 1).** Run `npm run test:e2e`. Expect all pass; the new file adds one test on top of the prior 12.

- [ ] **Step 4: Commit.**

```bash
git add e2e/devices.e2e.test.ts
git commit -m "$(cat <<'EOF'
Add e2e PUT /devices/me quiet-hours round-trip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors.

- [ ] **Step 2: Full unit suite — expect GREEN.** Run `npm test`. Expect all pass: the prior 237 plus the new `test/schema-budgets.test.ts` (2), `test/apns.test.ts` (2), `test/budgetAlert.test.ts` (8), `test/devices-quiet-hours.test.ts` (3) = 252 total, with no regressions to the existing `test/devices.test.ts` / `test/schema.test.ts`.

- [ ] **Step 3: Full e2e suite — expect GREEN.** Run `npm run test:e2e`. Expect 13 (12 prior + the new `e2e/devices.e2e.test.ts`).

- [ ] **Step 4: Final review.** Run `git log --oneline -7` to confirm the seven feature commits are present and the tree is clean (`git status`).
