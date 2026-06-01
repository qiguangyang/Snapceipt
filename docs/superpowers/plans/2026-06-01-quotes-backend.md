# Quotes Backend (send route + clients sync + quote PDF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add the F5 Quotes backend — migration `0002` (a synced `clients` address-book table + a server-only `quote_counters` table), register `client` on the generic `/sync` so it round-trips, a `pdf-lib` quote PDF builder, a pure totals helper, an atomic per-user `SN-####` counter, a gated `sendQuoteEmail`, the only new quote route `POST /quotes/:id/send` (recompute totals, mint a number on first send, render → R2, status→sent, queue + send the email gated on `env.EMAIL`, issue a signed link), and the public `GET /quotes/dl/:token` download — keeping the full backend suite green.

**Architecture:** Quote/line-item CRUD already round-trips via the generic `/sync` (the `quote` + `quoteLineItem` tables, registry entries, and D1 schema all exist from prior work). This plan adds the *send* pipeline by cloning F2's export pipeline (`src/routes/export.ts`, `src/lib/pdfExport.ts`, `src/lib/exportToken.ts`, `src/lib/email.ts`). `POST /quotes/:id/send` loads the quote + its non-deleted line items, recomputes totals authoritatively (`recomputeTotals`), assigns the next per-user sequence from `quote_counters` via an atomic `ON CONFLICT … RETURNING` upsert (only when `number` is NULL — re-send keeps the number), builds the PDF (`buildQuotePdf`), stores it in R2, sets `status='sent'`/`sent_at`, logs an `email_outbox` `quote_send` row, sends the email via `sendQuoteEmail` **gated on `env.EMAIL`** (absent → no send, `emailed:false`, outbox left `queued`, no crash — exactly like F2's accountant branch), and issues a 7-day signed download token. The public `GET /quotes/dl/:token` verifies the token and streams the R2 PDF (in `PUBLIC_PATHS`, IP-limited). The new `clients` table is purely a synced entity — registering it in `SYNCABLE_TABLES` + `SYNCABLE_TYPES` is the entire backend wiring (no CRUD route).

**Tech Stack:** TypeScript, Cloudflare Workers (Hono), D1 (SQLite), R2, `pdf-lib` (StandardFonts, no images), `jose` HS256 download tokens, `mimetext/browser` + `cloudflare:email`, Vitest (`@cloudflare/vitest-pool-workers`), e2e via `unstable_dev`.

---

**RULE — no new quote CRUD route.** Quote / quote-line-item / client create-edit-delete stay on the generic `/sync/push` + `/sync/pull`. The ONLY new routes are `POST /quotes/:id/send` and the public `GET /quotes/dl/:token`. The per-user number is minted **server-side only**, **atomically**, and **only on the first send** — a re-send MUST NOT mint a new number. The email send is **gated on `env.EMAIL`** like the F2 accountant export and stubbed in tests via `vi.spyOn(emailModule, "sendQuoteEmail")`.

**Baseline (verified by running the suite on 2026-06-01):** `npm test` = **253** unit tests (32 files); `npm run test:e2e` = **13** e2e tests (4 files); `npm run typecheck` clean. F4 was iOS-only so the backend baseline is unchanged from F3. Every task below states the running count after it lands.

---

## File structure

| File | Create/Modify | Responsibility |
|---|---|---|
| `migrations/0002_quotes_clients.sql` | Create | `clients` (synced) + `quote_counters` (server-only) tables + indexes. Forward-only. |
| `src/schemas/entities.ts` | Modify (`SYNCABLE_TYPES` ~line 154) | Add `"client"` to `SYNCABLE_TYPES` so the push route accepts it (validates via `baseEnvelope`). |
| `src/lib/syncTables.ts` | Modify (`SYNCABLE_TABLES` ~line 16) | Register `client` → `clients` table with `name`/`email` columns (camelCase) and `hasProfileId: true`. |
| `src/lib/pdfQuote.ts` | Create | `buildQuotePdf(quote, lineItems, sender)` — A4 `pdf-lib` quote PDF (header/meta/bill-to/table/totals/footer). |
| `src/lib/quoteTotals.ts` | Create | Pure `recomputeTotals(lineItems, gstEnabled)` → `{ subtotalCents, gstCents, totalCents }` (spec §4.2). |
| `src/lib/quoteCounter.ts` | Create | `assignQuoteNumber(db, userId)` — atomic `quote_counters` upsert → `SN-####`. |
| `src/lib/email.ts` | Modify (after `sendExportEmail`) | Add `sendQuoteEmail(env, msg)` — mirrors `sendExportEmail`; PDF attachment; Reply-To = trader. |
| `src/routes/quotes.ts` | Create | `POST /:id/send` (the send pipeline) + public `GET /dl/:token` (stream R2). |
| `src/app.ts` | Modify | Mount `quotesRoutes` at `/quotes`; add a `quotes` rate tier mount. |
| `src/middleware/rateLimit.ts` | Modify | Add the `quotes` tier (60/user/hr) + `"quotes"` to `RateLimitKind`. |
| `src/middleware/auth.ts` | Modify (`PUBLIC_PATHS` line 11) | Add `/quotes/dl/` to `PUBLIC_PATHS`. |
| `test/schema-clients.test.ts` | Create (test) | Migration test: `clients` columns + sync columns + `quote_counters` shape + round-trip. |
| `test/pdfQuote.test.ts` | Create (test) | `buildQuotePdf` returns a real `%PDF`. |
| `test/quoteTotals.test.ts` | Create (test) | `recomputeTotals` formula incl. GST-off + rounding. |
| `test/quoteCounter.test.ts` | Create (test) | sequential `SN-0001`/`SN-0002`; distinct users independent. |
| `test/quotes-send.test.ts` | Create (test) | `POST /quotes/:id/send` route suite (recompute, mint-once, idempotent re-send, status/sentAt, email gated + spied, response shape, 400) + `GET /quotes/dl/:token`. |
| `test/quotes-app.test.ts` | Create (test) | Route reachability through the real app (401 without auth; public `/quotes/dl/*` is reachable → 403 forged, not 401). |
| `e2e/quotes.e2e.test.ts` | Create (test) | Real-HTTP `POST /quotes/:id/send` (seed quote+lines via `/sync/push`) + `/quotes/dl` round-trip. |

**Pre-existing (do NOT recreate):** the `quotes` + `quote_line_items` D1 tables, `email_outbox.kind` CHECK already includes `'quote_send'` (migration `0001_init.sql` line 440) and the `related_id` column (line 445), and the `quote` + `quoteLineItem` registry entries in `src/lib/syncTables.ts` (lines 126–153) + `SYNCABLE_TYPES` (lines 154–169). This plan touches NONE of those.

---

### Task 1: Migration 0002 — `clients` (synced) + `quote_counters` (server-only)

**Files:**
- Create: `migrations/0002_quotes_clients.sql`
- Create (test): `test/schema-clients.test.ts`

The `clients` table is a normal synced entity (carries the full sync envelope: `id, user_id, profile_id, created_at, updated_at, deleted_at, rev, last_edited_device_id`). `quote_counters` is server-only (the per-user `SN-####` sequence): `user_id TEXT PRIMARY KEY, next_seq INTEGER NOT NULL`. Migration `0002` is a new forward-only file (the project's `0001_init.sql` is edited in place per the convention, but a brand-new feature gets its own numbered migration). `applyD1Migrations(env.DB, env.TEST_MIGRATIONS)` is fed by `readD1Migrations(path.join(__dirname, "migrations"))` in `vitest.config.ts`, which globs the `migrations/` dir — so the new `0002_*.sql` file is picked up automatically with no config change.

- [ ] **Step 1: Write the FAILING migration test.** Create `test/schema-clients.test.ts` with this complete content:

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

async function tableExists(table: string): Promise<boolean> {
  const row = await env.DB
    .prepare(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`)
    .bind(table)
    .first<{ name: string }>();
  return row?.name === table;
}

describe("0002 clients + quote_counters", () => {
  it("creates the clients table with name/email + the sync envelope columns", async () => {
    expect(await tableExists("clients")).toBe(true);
    const cols = await columnsOf("clients");
    for (const c of ["name", "email", "profile_id"]) {
      expect(cols.has(c), `clients missing column ${c}`).toBe(true);
    }
    for (const c of ["id", "user_id", "created_at", "updated_at", "deleted_at", "rev", "last_edited_device_id"]) {
      expect(cols.has(c), `clients missing sync column ${c}`).toBe(true);
    }
  });

  it("creates the quote_counters table with user_id PK + next_seq", async () => {
    expect(await tableExists("quote_counters")).toBe(true);
    const cols = await columnsOf("quote_counters");
    expect(cols.has("user_id")).toBe(true);
    expect(cols.has("next_seq")).toBe(true);
  });

  it("clients round-trips a row (insert + read back)", async () => {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('ucl',1,1)`),
      env.DB.prepare(
        `INSERT INTO clients(id,user_id,profile_id,name,email,created_at,updated_at,rev)
         VALUES('cl1','ucl','pcl','Jane Roe','jane@example.com',1,1,0)`,
      ),
    ]);
    const row = await env.DB.prepare(
      `SELECT name, email, profile_id, deleted_at FROM clients WHERE id='cl1'`,
    ).first<{ name: string; email: string | null; profile_id: string | null; deleted_at: number | null }>();
    expect(row?.name).toBe("Jane Roe");
    expect(row?.email).toBe("jane@example.com");
    expect(row?.profile_id).toBe("pcl");
    expect(row?.deleted_at).toBeNull();
  });

  it("quote_counters atomically upserts next_seq via ON CONFLICT … RETURNING", async () => {
    const first = await env.DB.prepare(
      `INSERT INTO quote_counters(user_id, next_seq) VALUES('uctr', 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    ).first<{ next_seq: number }>();
    expect(first?.next_seq).toBe(1);
    const second = await env.DB.prepare(
      `INSERT INTO quote_counters(user_id, next_seq) VALUES('uctr', 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    ).first<{ next_seq: number }>();
    expect(second?.next_seq).toBe(2);
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- schema-clients`. Expect failure: `clients missing column name` / `tableExists("clients") === false` (the table does not exist yet).

- [ ] **Step 3: Create the migration.** Create `migrations/0002_quotes_clients.sql` with this complete content:

```sql
-- migrations/0002_quotes_clients.sql
-- F5 Quotes: the saved-clients address book (synced) + the server-only per-user
-- quote-number counter. Forward-only.
-- ids = UUIDv7 TEXT. Money = INTEGER cents. Timestamps = INTEGER epoch ms.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- clients — the saved-clients address book (synced via the generic /sync).
-- =========================================================================
CREATE TABLE clients (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT,
  name                  TEXT NOT NULL,
  email                 TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_client_user_updated ON clients(user_id, updated_at);
CREATE INDEX ix_client_profile      ON clients(profile_id) WHERE deleted_at IS NULL;

-- =========================================================================
-- quote_counters — server-only per-user SN-#### sequence. NOT synced. The send
-- route increments next_seq atomically (INSERT … ON CONFLICT … RETURNING) so
-- concurrent sends never collide; quotes.ux_quote_number is the unique backstop.
-- =========================================================================
CREATE TABLE quote_counters (
  user_id  TEXT PRIMARY KEY REFERENCES users(id),
  next_seq INTEGER NOT NULL
);
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- schema-clients`. Expect all 4 tests pass. Also run `npm test -- schema` to confirm the existing `test/schema.test.ts` still passes (it pins a fixed `SYNCABLE`/`OPERATIONAL` table list that does NOT include `clients`/`quote_counters`, and only asserts those listed tables EXIST — extra tables are ignored, so it stays green).

- [ ] **Step 5: Commit.**

```bash
git add migrations/0002_quotes_clients.sql test/schema-clients.test.ts
git commit -m "$(cat <<'EOF'
Add migration 0002: clients (synced) + quote_counters (server-only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 1:** unit `257` (253 + 4 new in `schema-clients`); e2e `13`.

---

### Task 2: Register `client` on the generic `/sync`

**Files:**
- Modify: `src/schemas/entities.ts` (`SYNCABLE_TYPES`, ~line 154)
- Modify: `src/lib/syncTables.ts` (`SYNCABLE_TABLES`, after the `loyaltyCard` entry ~line 125)
- Create (test): part of `test/quotes-send.test.ts` is later; this task's round-trip lives inline here as a focused push+pull test added to `test/schema-clients.test.ts`.

The push/pull routes are fully generic over `SYNCABLE_TABLES` + `SYNCABLE_TYPES` (verified `src/routes/sync.ts`: it reads `tableForEntityType(m.entityType)`, `meta.hasProfileId`, and iterates `meta.columns`). Registering `client` is the entire backend wiring — no route changes. `client.profile_id` is nullable in D1 (the migration declares `profile_id TEXT` without `NOT NULL`), so `client` is deliberately ABSENT from `PROFILE_ID_REQUIRED` (clients may be created before a profile context exists; the iOS layer always sets it, but the server does not force it). `client` has no specialized zod schema, so it validates via `baseEnvelope.passthrough()` (verified `entitySchemaFor` falls back to `baseEnvelope` for unlisted types).

- [ ] **Step 1: Add the round-trip test (FAILING).** Append this `describe` block to `test/schema-clients.test.ts` (after the existing block), and add the two imports shown at the top:

At the top of the file, add after the existing imports:

```ts
import { SELF } from "cloudflare:test";
import { signAccess } from "../src/lib/jwt";
import { uuidv7 } from "../src/lib/ids";
```

Then append:

```ts
describe("client round-trips via /sync", () => {
  const USER = "01890000-0000-7000-8000-0000000000c1";
  const DEVICE = "01890000-0000-7000-8000-0000000000d2";
  const SESSION = "01890000-0000-7000-8000-0000000000e2";
  const PROFILE = "01890000-0000-7000-8000-0000000000a2";

  async function authHeader() {
    const token = await signAccess(env.JWT_SIGNING_KEY, { userId: USER, sessionId: SESSION, deviceId: DEVICE });
    return { Authorization: `Bearer ${token}`, "Content-Type": "application/json" };
  }

  it("push upserts a client; pull returns it for the same user", async () => {
    const now = Date.now();
    await env.DB.prepare(
      `INSERT OR IGNORE INTO users (id, email, email_verified, plan, created_at, updated_at)
       VALUES (?, ?, 1, 'free', ?, ?)`,
    ).bind(USER, `${USER}@example.com`, now, now).run();

    const clientId = uuidv7();
    const headers = await authHeader();
    const pushRes = await SELF.fetch("https://api.test/sync/push", {
      method: "POST",
      headers,
      body: JSON.stringify({
        deviceId: DEVICE,
        mutations: [
          {
            mutationId: uuidv7(),
            entityType: "client",
            entityId: clientId,
            op: "upsert",
            updatedAt: now,
            payload: {
              id: clientId, userId: USER, profileId: PROFILE, type: "client",
              name: "Acme Builders", email: "ap@acme.example",
              createdAt: now, updatedAt: now, deletedAt: null, rev: 0, lastEditedDeviceId: DEVICE,
            },
          },
        ],
      }),
    });
    expect(pushRes.status).toBe(200);
    const pushJson = (await pushRes.json()) as any;
    expect(pushJson.results[0].status).toBe("applied");
    expect(pushJson.results[0].entity.rev).toBe(1);

    // Persisted with the right columns.
    const row = await env.DB.prepare(`SELECT name, email, profile_id FROM clients WHERE id = ?`)
      .bind(clientId).first<{ name: string; email: string; profile_id: string }>();
    expect(row?.name).toBe("Acme Builders");
    expect(row?.email).toBe("ap@acme.example");
    expect(row?.profile_id).toBe(PROFILE);

    // A first/full pull (no cursor) returns the client envelope (camelCase name/email).
    // The pull query is ?cursor=<opaque>&limit=<n>; omitting cursor = full sync,
    // limit defaults to 500 (verified src/schemas/sync.ts pullQuerySchema).
    const pullRes = await SELF.fetch("https://api.test/sync/pull", {
      method: "GET",
      headers,
    });
    expect(pullRes.status).toBe(200);
    const pullJson = (await pullRes.json()) as any;
    const found = (pullJson.changes as any[]).find((ch) => ch.id === clientId);
    expect(found).toBeTruthy();
    expect(found.type).toBe("client");
    expect(found.name).toBe("Acme Builders");
    expect(found.email).toBe("ap@acme.example");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- schema-clients`. Expect the new test fails: the push returns a `rejected`/`unknown entityType` result (or the persisted row is absent) because `client` is not in `SYNCABLE_TYPES` / `SYNCABLE_TABLES` yet.

  > Confirm the exact failure shape first (read `pushJson.results[0]`). The sync push route rejects an unknown `entityType` rather than 500ing; the test asserts `status === "applied"`, which will be false until Step 3 + 4 register `client`.

- [ ] **Step 3: Add `client` to `SYNCABLE_TYPES`.** In `src/schemas/entities.ts`, in the `SYNCABLE_TYPES` array (lines 154–169), add `"client"` after `"loyaltyCard"`:

```ts
export const SYNCABLE_TYPES = [
  "transaction",
  "lineItem",
  "profile",
  "category",
  "smartRule",
  "budget",
  "loyaltyCard",
  "client",
  "quote",
  "quoteLineItem",
  "mileageTrip",
  "wfhLog",
  "taxSettings",
  "vehicle",
  "vehicleYear",
] as const;
```

- [ ] **Step 4: Register the `client` table.** In `src/lib/syncTables.ts`, in `SYNCABLE_TABLES`, add this entry immediately after the `loyaltyCard` entry (after its closing `},` ~line 125, before the `quote:` entry):

```ts
  client: {
    table: "clients",
    hasProfileId: true,
    columns: {
      name: "name",
      email: "email",
    },
  },
```

  Do NOT add `client` to `PROFILE_ID_REQUIRED` — `clients.profile_id` is nullable.

- [ ] **Step 5: Run the test — expect PASS.** Run `npm test -- schema-clients`. Expect all 5 tests pass (the 4 schema tests + the new round-trip). Also run `npm test -- schemas sync-push sync-pull` to confirm the generic sync suites are unaffected (`test/schemas.test.ts` iterates `SYNCABLE_TYPES` and validates each via `entitySchemaFor`; `client` falls back to `baseEnvelope`, which accepts the envelope — no new specialized assertions break).

- [ ] **Step 6: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors (additive const-array entry + registry entry).

- [ ] **Step 7: Commit.**

```bash
git add src/schemas/entities.ts src/lib/syncTables.ts test/schema-clients.test.ts
git commit -m "$(cat <<'EOF'
Register client entity on the generic /sync (clients table)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 2:** unit `258` (257 + 1 round-trip); e2e `13`.

---

### Task 3: `recomputeTotals` — the pure totals helper

**Files:**
- Create: `src/lib/quoteTotals.ts`
- Create (test): `test/quoteTotals.test.ts`

Spec §4.2: `subtotalCents = Σ(quantity × unitPriceCents)`; `gstCents = gstEnabled ? Int(round(subtotal × 0.10)) : 0`; `totalCents = subtotal + gst`. This is the authoritative formula the send route uses. The rounding is `Math.round` over `subtotal * 0.10` (JS `Math.round` rounds half UP toward +∞, matching the iOS `round` for the non-negative money domain here).

- [ ] **Step 1: Write the FAILING test.** Create `test/quoteTotals.test.ts` with this complete content:

```ts
import { describe, expect, it } from "vitest";
import { recomputeTotals, type QuoteLineItemAmounts } from "../src/lib/quoteTotals";

const lines = (...pairs: Array<[qty: number, unit: number]>): QuoteLineItemAmounts[] =>
  pairs.map(([quantity, unitPriceCents]) => ({ quantity, unitPriceCents }));

describe("recomputeTotals", () => {
  it("sums quantity x unitPrice for the subtotal", () => {
    const t = recomputeTotals(lines([2, 5000], [1, 3000]), false);
    expect(t.subtotalCents).toBe(13000);
  });

  it("adds 10% GST (rounded) when gstEnabled", () => {
    const t = recomputeTotals(lines([1, 10000]), true);
    expect(t.subtotalCents).toBe(10000);
    expect(t.gstCents).toBe(1000);
    expect(t.totalCents).toBe(11000);
  });

  it("rounds GST to the nearest cent", () => {
    // subtotal 9999 -> 10% = 999.9 -> round = 1000.
    const t = recomputeTotals(lines([1, 9999]), true);
    expect(t.subtotalCents).toBe(9999);
    expect(t.gstCents).toBe(1000);
    expect(t.totalCents).toBe(10999);
  });

  it("zeroes GST when gstEnabled is false", () => {
    const t = recomputeTotals(lines([3, 2500]), false);
    expect(t.subtotalCents).toBe(7500);
    expect(t.gstCents).toBe(0);
    expect(t.totalCents).toBe(7500);
  });

  it("returns all-zero for no line items", () => {
    const t = recomputeTotals([], true);
    expect(t).toEqual({ subtotalCents: 0, gstCents: 0, totalCents: 0 });
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- quoteTotals`. Expect failure: cannot resolve `../src/lib/quoteTotals` (module does not exist).

- [ ] **Step 3: Write the implementation.** Create `src/lib/quoteTotals.ts` with this complete content:

```ts
/**
 * Pure quote-totals recompute (spec §4.2). The send route calls this to
 * recompute totals authoritatively from the persisted line items before
 * rendering the PDF. iOS computes the identical formula on-device for the live
 * UI; this is the server's source of truth.
 *
 *   subtotalCents = Σ(quantity × unitPriceCents)
 *   gstCents      = gstEnabled ? round(subtotalCents × 0.10) : 0   (10% AU GST)
 *   totalCents    = subtotalCents + gstCents
 */

const GST_RATE = 0.1; // 10% AU GST.

/** The two amounts needed per line item to recompute totals. */
export interface QuoteLineItemAmounts {
  quantity: number;
  unitPriceCents: number;
}

export interface QuoteTotals {
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
}

export function recomputeTotals(
  lineItems: QuoteLineItemAmounts[],
  gstEnabled: boolean,
): QuoteTotals {
  let subtotalCents = 0;
  for (const li of lineItems) {
    subtotalCents += li.quantity * li.unitPriceCents;
  }
  const gstCents = gstEnabled ? Math.round(subtotalCents * GST_RATE) : 0;
  return { subtotalCents, gstCents, totalCents: subtotalCents + gstCents };
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- quoteTotals`. Expect all 5 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add src/lib/quoteTotals.ts test/quoteTotals.test.ts
git commit -m "$(cat <<'EOF'
Add pure recomputeTotals quote helper (subtotal/GST/total)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 3:** unit `263` (258 + 5); e2e `13`.

---

### Task 4: `assignQuoteNumber` — the atomic per-user counter

**Files:**
- Create: `src/lib/quoteCounter.ts`
- Create (test): `test/quoteCounter.test.ts`

Spec §4.3: the counter is the only place numbers are minted. `INSERT INTO quote_counters(user_id, next_seq) VALUES(?, 1) ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1 RETURNING next_seq` returns `1` on the first send for a user, then `2, 3, …`. The atomic upsert means concurrent sends never collide; the format is `SN-` + the seq zero-padded to 4 digits (`String(seq).padStart(4, "0")`). The function returns the formatted number string; the route only calls it when `quote.number` is currently NULL.

- [ ] **Step 1: Write the FAILING test.** Create `test/quoteCounter.test.ts` with this complete content:

```ts
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assignQuoteNumber } from "../src/lib/quoteCounter";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM quote_counters");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uA',1,1)`),
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uB',1,1)`),
  ]);
});

describe("assignQuoteNumber", () => {
  it("returns SN-0001 then SN-0002 for sequential assigns of one user", async () => {
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0002");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0003");
  });

  it("keeps per-user sequences independent", async () => {
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uB")).toBe("SN-0001");
    expect(await assignQuoteNumber(env.DB, "uA")).toBe("SN-0002");
    expect(await assignQuoteNumber(env.DB, "uB")).toBe("SN-0002");
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- quoteCounter`. Expect failure: cannot resolve `../src/lib/quoteCounter` (module does not exist).

- [ ] **Step 3: Write the implementation.** Create `src/lib/quoteCounter.ts` with this complete content:

```ts
/**
 * Per-user quote-number counter (spec §4.3). The send route calls this exactly
 * once per quote — on the FIRST send, when quotes.number is still NULL. A re-send
 * keeps the existing number, so this is never called again for that quote.
 *
 * The assignment is atomic: a single INSERT … ON CONFLICT … RETURNING bumps and
 * returns next_seq in one statement, so two concurrent sends for the same user
 * get distinct sequences (1, 2) and never collide. quotes.ux_quote_number
 * (UNIQUE(user_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL) is
 * the backstop.
 */

/** Format a 1-based sequence as SN-#### (4-digit zero-padded). */
export function formatQuoteNumber(seq: number): string {
  return `SN-${String(seq).padStart(4, "0")}`;
}

/**
 * Atomically allocate the next per-user sequence and return the formatted
 * SN-#### number. First call for a user returns SN-0001, then SN-0002, …
 */
export async function assignQuoteNumber(db: D1Database, userId: string): Promise<string> {
  const row = await db
    .prepare(
      `INSERT INTO quote_counters (user_id, next_seq) VALUES (?, 1)
       ON CONFLICT(user_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    )
    .bind(userId)
    .first<{ next_seq: number }>();
  const seq = row?.next_seq ?? 1;
  return formatQuoteNumber(seq);
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- quoteCounter`. Expect both tests pass.

- [ ] **Step 5: Commit.**

```bash
git add src/lib/quoteCounter.ts test/quoteCounter.test.ts
git commit -m "$(cat <<'EOF'
Add atomic per-user quote-number counter (SN-#### upsert)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 4:** unit `265` (263 + 2); e2e `13`.

---

### Task 5: `buildQuotePdf` — the quote PDF builder

**Files:**
- Create: `src/lib/pdfQuote.ts`
- Create (test): `test/pdfQuote.test.ts`

Spec §4.4: clone `src/lib/pdfExport.ts` (A4, `StandardFonts.Helvetica`/`HelveticaBold`, no images, `doc.save()` returns the bytes, the `draw` paginator). Header = sender `Profile.name`, `ABN: <abn>` if set, "Registered for GST" if `gstRegistered`. Meta = `Quote <number>` (or "Quote (draft)" when number is null), issued date, "Valid until <validUntil>" if set. Bill-to = client `name` + `email`. Body = a line-items table (Description / Qty / Unit / Amount, AUD dollars). Totals = Subtotal, "GST (10%)" only if `gstEnabled`, Total. Footer = "Valid for 14 days. Accepted quotes convert to an invoice." The function takes already-computed totals on the `quote` arg (the route recomputes then passes them in).

- [ ] **Step 1: Write the FAILING test.** Create `test/pdfQuote.test.ts` with this complete content:

```ts
import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import { buildQuotePdf, type QuotePdfData, type QuoteLineItemRow, type QuoteSender } from "../src/lib/pdfQuote";

const sender: QuoteSender = { name: "Acme Pty Ltd", abn: "12 345 678 901", gstRegistered: true };

const lineItems: QuoteLineItemRow[] = [
  { description: "Site inspection", quantity: 1, unitPriceCents: 25000 },
  { description: "Report + drawings", quantity: 2, unitPriceCents: 40000 },
];

const quote: QuotePdfData = {
  number: "SN-0001",
  clientName: "Jane Roe",
  clientEmail: "jane@example.com",
  gstEnabled: true,
  subtotalCents: 105000,
  gstCents: 10500,
  totalCents: 115500,
  validUntil: "2026-06-15",
  issuedDate: "2026-06-01",
};

describe("buildQuotePdf", () => {
  it("returns a real %PDF Uint8Array that opens to >=1 page", async () => {
    const bytes = await buildQuotePdf(quote, lineItems, sender);
    // %PDF magic bytes.
    expect(bytes[0]).toBe(0x25);
    expect(bytes[1]).toBe(0x50);
    expect(bytes[2]).toBe(0x44);
    expect(bytes[3]).toBe(0x46);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders with GST off, no ABN, a null number, and no validUntil", async () => {
    const bytes = await buildQuotePdf(
      {
        number: null,
        clientName: "Bob",
        clientEmail: null,
        gstEnabled: false,
        subtotalCents: 5000,
        gstCents: 0,
        totalCents: 5000,
        validUntil: null,
        issuedDate: "2026-06-01",
      },
      [{ description: "Consult", quantity: 1, unitPriceCents: 5000 }],
      { name: "Solo Trader", abn: null, gstRegistered: false },
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });

  it("paginates a long line-item list", async () => {
    const many: QuoteLineItemRow[] = Array.from({ length: 80 }, (_, i) => ({
      description: `Line ${i}`,
      quantity: 1,
      unitPriceCents: 1000 + i,
    }));
    const bytes = await buildQuotePdf({ ...quote, subtotalCents: 0, gstCents: 0, totalCents: 0 }, many, sender);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- pdfQuote`. Expect failure: cannot resolve `../src/lib/pdfQuote` (module does not exist).

- [ ] **Step 3: Write the implementation.** Create `src/lib/pdfQuote.ts` with this complete content:

```ts
import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * Quote PDF (spec §4.4) — clones src/lib/pdfExport.ts: A4 portrait, pdf-lib
 * StandardFonts (no font file), no embedded images (pure-JS, Workers-safe).
 * Pure: the route recomputes the totals (recomputeTotals) and passes them in.
 * Returns the encoded bytes (%PDF...).
 */

/** The sender block — drawn from the active Business Profile. */
export interface QuoteSender {
  name: string;
  abn: string | null;
  gstRegistered: boolean;
}

/** One line-item row as rendered in the body table. */
export interface QuoteLineItemRow {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

/** The quote header/meta/totals the PDF needs (totals already recomputed). */
export interface QuotePdfData {
  number: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  validUntil: string | null;
  /** YYYY-MM-DD issued date (the route passes today's UTC date). */
  issuedDate: string;
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildQuotePdf(
  quote: QuotePdfData,
  lineItems: QuoteLineItemRow[],
  sender: QuoteSender,
): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page = doc.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - MARGIN;

  const draw = (text: string, f: PDFFont, size: number): void => {
    if (y < BOTTOM) {
      page = doc.addPage([PAGE_W, PAGE_H]);
      y = PAGE_H - MARGIN;
    }
    page.drawText(text, { x: MARGIN, y, size, font: f, color: rgb(0.07, 0.07, 0.07) });
    y -= LINE;
  };

  // Header — the sender (Business profile).
  draw(sender.name, bold, 18);
  if (sender.abn) draw(`ABN: ${sender.abn}`, font, 11);
  if (sender.gstRegistered) draw("Registered for GST", font, 11);
  y -= LINE / 2;

  // Meta.
  draw(`Quote ${quote.number ?? "(draft)"}`, bold, 14);
  draw(`Issued: ${quote.issuedDate}`, font, 11);
  if (quote.validUntil) draw(`Valid until ${quote.validUntil}`, font, 11);
  y -= LINE / 2;

  // Bill-to.
  draw("Bill to", bold, 12);
  draw(quote.clientName ?? "(no client)", font, 11);
  if (quote.clientEmail) draw(quote.clientEmail, font, 11);
  y -= LINE / 2;

  // Line-items table.
  draw("Items", bold, 12);
  draw("description            qty   unit        amount", font, 10);
  for (const li of lineItems) {
    const desc = li.description.length > 22 ? `${li.description.slice(0, 21)}…` : li.description;
    const amount = li.quantity * li.unitPriceCents;
    draw(
      `${desc.padEnd(22)} ${String(li.quantity).padStart(4)}  ${dollars(li.unitPriceCents).padStart(9)}  ${dollars(amount).padStart(9)}`,
      font,
      10,
    );
  }
  y -= LINE / 2;

  // Totals.
  draw(`Subtotal: ${dollars(quote.subtotalCents)}`, font, 12);
  if (quote.gstEnabled) draw(`GST (10%): ${dollars(quote.gstCents)}`, font, 12);
  draw(`Total: ${dollars(quote.totalCents)}`, bold, 14);
  y -= LINE / 2;

  // Footer.
  draw("Valid for 14 days. Accepted quotes convert to an invoice.", font, 9);

  return doc.save();
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- pdfQuote`. Expect all 3 tests pass. (Like `pdfExport`, literal strings such as `SN-0001` are NOT round-trippable via a naive byte decode — assert only structure: magic bytes + page count.)

- [ ] **Step 5: Commit.**

```bash
git add src/lib/pdfQuote.ts test/pdfQuote.test.ts
git commit -m "$(cat <<'EOF'
Add buildQuotePdf (A4 pdf-lib quote: header/items/totals/footer)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 5:** unit `268` (265 + 3); e2e `13`.

---

### Task 6: `sendQuoteEmail` — gated, vi.spyOn-able email seam

**Files:**
- Modify: `src/lib/email.ts` (append `QuoteEmail` interface + `sendQuoteEmail` after `sendExportEmail`, before `base64Bytes`)
- Create (test): `test/email-quote.test.ts`

Spec §5: mirror `sendExportEmail` — `mimetext/browser` MIME, base64 PDF attachment, `cloudflare:email` `EmailMessage`, `env.EMAIL.send`, a `Mailbox` Reply-To = the trader's email. `from` is the magic-link sender (the only allowed sender). The route GATES the call on `env.EMAIL` (so this function is only invoked when the binding exists); tests stub it via `vi.spyOn(emailModule, "sendQuoteEmail")` and also directly exercise the MIME-build with a fake `env.EMAIL.send`, mirroring `test/email.test.ts`. `base64Bytes` already exists in this module (reuse it).

- [ ] **Step 1: Write the FAILING test.** Create `test/email-quote.test.ts` with this complete content:

```ts
/**
 * Unit tests for sendQuoteEmail — mirrors test/email.test.ts. Stubs
 * cloudflare:email so we can capture the raw MIME + envelope addresses without
 * a live binding, and exercises the MIME build with a fake env.EMAIL.send.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { sendQuoteEmail } from "../src/lib/email";

const captured = vi.hoisted(() => ({
  raw: null as string | null,
  from: null as string | null,
  to: null as string | null,
}));

vi.mock("cloudflare:email", () => {
  return {
    EmailMessage: class MockEmailMessage {
      readonly from: string;
      readonly to: string;
      constructor(from: string, to: string, raw: string) {
        this.from = from;
        this.to = to;
        captured.raw = typeof raw === "string" ? raw : String(raw);
        captured.from = from;
        captured.to = to;
      }
    },
  };
});

afterEach(() => {
  vi.restoreAllMocks();
  captured.raw = null;
  captured.from = null;
  captured.to = null;
});

describe("sendQuoteEmail", () => {
  it("calls env.EMAIL.send once with the client envelope addresses", async () => {
    const sent: unknown[] = [];
    const fakeEnv = { EMAIL: { send: async (m: unknown) => { sent.push(m); } } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });
    expect(sent.length).toBe(1);
    expect(captured.from).toBe("noreply@snapceipt.app");
    expect(captured.to).toBe("jane@client.au");
  });

  it("raw MIME carries the PDF attachment + the reply-to + the quote number subject", async () => {
    const fakeEnv = { EMAIL: { send: async () => {} } } as any;
    await sendQuoteEmail(fakeEnv, {
      to: "jane@client.au",
      replyTo: "trader@example.com",
      quoteNumber: "SN-0001",
      clientName: "Jane Roe",
      totalCents: 115500,
      pdf: new Uint8Array([0x25, 0x50, 0x44, 0x46, 1, 2, 3]),
    });
    const raw = captured.raw;
    expect(raw).not.toBeNull();
    expect(raw).toContain("application/pdf");
    expect(raw).toContain("quote-SN-0001.pdf");
    expect(raw).toContain("trader@example.com"); // Reply-To
    expect(raw).toContain("SN-0001"); // subject
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- email-quote`. Expect failure: `sendQuoteEmail` is not exported from `../src/lib/email`.

- [ ] **Step 3: Add `sendQuoteEmail`.** In `src/lib/email.ts`, insert this block immediately AFTER the closing brace of `sendExportEmail` (after line 105) and BEFORE the `base64Bytes` function (line 107):

```ts
/** The quote-send email (PDF attachment). */
export interface QuoteEmail {
  to: string;
  /** The trader's own email — set as Reply-To so the client replies to them. */
  replyTo: string;
  quoteNumber: string;
  clientName: string | null;
  totalCents: number;
  pdf: Uint8Array;
}

/** PDF attachment ceiling — Cloudflare Email Send caps the message. */
const MAX_QUOTE_PDF_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Send the quote email with the PDF attached (spec §5). Mirrors sendExportEmail:
 * mimetext/browser MIME (self-contained, workerd-safe), base64 PDF attachment,
 * cloudflare:email EmailMessage(from,to,raw) + env.EMAIL.send. `from` is the
 * magic-link sender (the only allowed_sender_addresses entry); Reply-To is the
 * trader so the client replies to them. Stubbed in route tests via
 * vi.spyOn(emailModule, "sendQuoteEmail"). The route GATES this on env.EMAIL.
 */
export async function sendQuoteEmail(env: Env, msg: QuoteEmail): Promise<void> {
  if (msg.pdf.byteLength > MAX_QUOTE_PDF_BYTES) {
    throw new Error(`quote PDF exceeds ${MAX_QUOTE_PDF_BYTES} bytes`);
  }

  const { createMimeMessage, Mailbox } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const total = `$${(msg.totalCents / 100).toFixed(2)}`;
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", new Mailbox(msg.replyTo, { type: "Reply-To" } as any));
  mime.setSubject(`Quote ${msg.quoteNumber} — ${total}`);
  mime.addMessage({
    contentType: "text/plain",
    data:
      `${greeting}\n\n` +
      `Please find attached quote ${msg.quoteNumber} for ${total}.\n\n` +
      `Reply to this email if you have any questions.\n`,
  });
  mime.addAttachment({
    filename: `quote-${msg.quoteNumber}.pdf`,
    contentType: "application/pdf",
    encoding: "base64",
    data: base64Bytes(msg.pdf),
  });

  const message = new EmailMessage(MAGIC_LINK_SENDER, msg.to, mime.asRaw());
  await env.EMAIL.send(message);
}
```

- [ ] **Step 4: Run the test — expect PASS.** Run `npm test -- email-quote`. Expect both tests pass. Also run `npm test -- email` to confirm the existing `test/email.test.ts` is unaffected.

- [ ] **Step 5: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors (`MAGIC_LINK_SENDER`, `Env`, and `base64Bytes` are all in-module symbols already defined in `src/lib/email.ts`).

- [ ] **Step 6: Commit.**

```bash
git add src/lib/email.ts test/email-quote.test.ts
git commit -m "$(cat <<'EOF'
Add sendQuoteEmail (PDF attachment, trader Reply-To)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 6:** unit `270` (268 + 2); e2e `13`.

---

### Task 7: `POST /quotes/:id/send` + public `GET /quotes/dl/:token`

**Files:**
- Create: `src/routes/quotes.ts`
- Create (test): `test/quotes-send.test.ts`

The full send pipeline (spec §4.3) cloned from `src/routes/export.ts`. Auth is global (the route reads `c.var.userId`). Steps in order:
1. Load the quote by `id` scoped to `user_id` (`deleted_at IS NULL`); 404 `NOT_FOUND` if absent.
2. Load its non-deleted line items (`ORDER BY sort_order ASC, id ASC`); zero items → 400 `VALIDATION_FAILED`.
3. **Validate email precondition BEFORE any mutation:** if `env.EMAIL` is present AND `clientEmail` is null → 400 `VALIDATION_FAILED`. This MUST happen before minting a number / writing R2 / flipping status (spec §8: a validation failure consumes no number and leaves the quote `draft`).
4. Recompute totals via `recomputeTotals`.
5. If `number IS NULL`, `assignQuoteNumber` (atomic) and set it; otherwise keep the existing number (idempotent re-send).
6. Load the owning profile (`name`, `abn`, `gst_registered`) for the PDF sender block.
7. `buildQuotePdf` → R2 `put` at `${userId}/quotes/${id}.pdf`.
8. Set `status='sent'`, `sent_at=<nowMs>`, persist totals + number in one UPDATE.
9. Issue a 7-day signed token (`signDownloadToken`) for `${origin}/quotes/dl/${token}`.
10. INSERT an `email_outbox` `quote_send` row (`related_id = quoteId`, `to_email = clientEmail`, `status='queued'`, `export_format='pdf'`, `export_r2_key = key`). Then, **gated on `env.EMAIL`**: if the binding is absent → leave the outbox `queued`, `emailed:false`, no send, no crash; if present (and `clientEmail` non-null, guaranteed by step 3) → `sendQuoteEmail` (Reply-To = the authed trader's email from `users`), update outbox `sent`/`failed`, `emailed` accordingly.
11. Respond `{ number, sentAt, status, subtotalCents, gstCents, totalCents, pdfUrl, expiresAt, emailed }`.

Validation: a quote with zero non-deleted line items → 400 `VALIDATION_FAILED` (can't send an empty quote). When `env.EMAIL` is present but `clientEmail` is null → 400 `VALIDATION_FAILED` (missing recipient), thrown in step 3 **before** any mutation so no number is burned and `status` stays `draft`. `sendQuoteEmail` is imported as a namespace (`import * as emailModule`) so tests `vi.spyOn(emailModule, "sendQuoteEmail")` — the exact seam shape used in `test/export-route.test.ts` line 2 + 140.

> **env.EMAIL in the test runtime.** The wrapped `EMAIL` binding IS present in the vitest-pool-workers runtime (wrangler.jsonc declares it), so the gate's truthy branch runs; the actual `env.EMAIL.send` is never reached because `sendQuoteEmail` is spied. Because the binding is always present in this runtime there is NO way to remove it per-request, so the "binding absent → emailed:false, outbox left queued" branch is NOT directly exercised by a unit test here — it is covered structurally (the handler reads `emailEnabled = Boolean(c.env.EMAIL)` once and only sends when true) and by the e2e (Task 10, where a real `EMAIL.send` with no SMTP may make the branch a no-op send-failure). The gate is asserted two ways in this suite: (a) the spied happy path proves `emailed:true` + outbox→sent; (b) a `mockRejectedValue` assertion forces the catch branch — when `sendQuoteEmail` THROWS the outbox→failed and the route still 200s with `emailed:false`, number still minted, status still sent.

- [ ] **Step 1: Write the FAILING test.** Create `test/quotes-send.test.ts` with this complete content:

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken } from "../src/lib/exportToken";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  await env.DB.exec("DELETE FROM email_outbox");
  await env.DB.exec("DELETE FROM quote_line_items");
  await env.DB.exec("DELETE FROM quotes");
  await env.DB.exec("DELETE FROM quote_counters");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, display_name, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'Dev', 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken, email: `${userId}@example.com` };
}

/** Seed a business profile + a draft quote + 2 line items. */
async function seedQuote(userId: string, opts: { clientEmail?: string | null } = {}) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'Jane Roe',?,1,'draft','2026-06-15',?,?)`,
  ).bind(quoteId, userId, profileId, opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

function send(quoteId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/quotes/${quoteId}/send`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /quotes/:id/send", () => {
  it("recomputes totals, mints SN-0001 on first send, sets status=sent + sentAt, emails (spied)", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // Recomputed totals: subtotal 25000 + 80000 = 105000; GST 10500; total 115500.
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(body.number).toBe("SN-0001");
    expect(body.status).toBe("sent");
    expect(typeof body.sentAt).toBe("number");
    expect(typeof body.pdfUrl).toBe("string");
    expect(body.pdfUrl).toContain("/quotes/dl/");
    expect(typeof body.expiresAt).toBe("number");
    expect(body.emailed).toBe(true);

    // Persisted on the quote.
    const row = await env.DB.prepare(
      `SELECT number, status, sent_at, subtotal_cents, gst_cents, total_cents FROM quotes WHERE id=?`,
    ).bind(quoteId).first<any>();
    expect(row.number).toBe("SN-0001");
    expect(row.status).toBe("sent");
    expect(row.sent_at).not.toBeNull();
    expect(row.total_cents).toBe(115500);

    // sendQuoteEmail got the PDF + the trader's reply-to.
    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1] as emailModule.QuoteEmail;
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe(email);
    expect(arg.quoteNumber).toBe("SN-0001");
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    // Outbox queued -> sent.
    const outbox = await env.DB.prepare(
      `SELECT kind, status, to_email, related_id, export_format FROM email_outbox WHERE related_id=?`,
    ).bind(quoteId).first<any>();
    expect(outbox.kind).toBe("quote_send");
    expect(outbox.status).toBe("sent");
    expect(outbox.to_email).toBe("jane@example.com");
    expect(outbox.export_format).toBe("pdf");
  });

  it("is IDEMPOTENT: a re-send keeps the existing number (no new mint)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const first = await send(quoteId, accessToken);
    const firstBody = (await first.json()) as any;
    expect(firstBody.number).toBe("SN-0001");

    const second = await send(quoteId, accessToken);
    const secondBody = (await second.json()) as any;
    expect(secondBody.number).toBe("SN-0001"); // unchanged

    // The per-user counter advanced only ONCE.
    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1);
  });

  it("downstream sends for the same user get the next number (SN-0002)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const a = await seedQuote(userId);
    const b = await seedQuote(userId);

    const r1 = (await (await send(a.quoteId, accessToken)).json()) as any;
    const r2 = (await (await send(b.quoteId, accessToken)).json()) as any;
    expect(r1.number).toBe("SN-0001");
    expect(r2.number).toBe("SN-0002");
  });

  it("when the email send THROWS, outbox -> failed but the route still 200s with emailed:false", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockRejectedValue(new Error("smtp down"));
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(false);
    expect(body.number).toBe("SN-0001"); // number still minted, status still sent
    expect(body.status).toBe("sent");
    expect(typeof body.pdfUrl).toBe("string");

    const outbox = await env.DB.prepare(`SELECT status, error FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ status: string; error: string | null }>();
    expect(outbox.status).toBe("failed");
    expect(outbox.error).toContain("smtp down");
  });

  it("400 VALIDATION_FAILED when the quote has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'Jane','jane@example.com',1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("400 VALIDATION_FAILED when emailing is enabled but the quote has no client email — and consumes NO number / stays draft", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { clientEmail: null });
    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");

    // The precondition fires BEFORE any mutation (spec §8): no email attempted, no
    // number burned, status still draft, no outbox row, the counter never advanced.
    expect(spy).not.toHaveBeenCalled();
    const row = await env.DB.prepare(`SELECT number, status, sent_at FROM quotes WHERE id=?`)
      .bind(quoteId).first<{ number: string | null; status: string; sent_at: number | null }>();
    expect(row?.number).toBeNull();
    expect(row?.status).toBe("draft");
    expect(row?.sent_at).toBeNull();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);
    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number } | null>();
    expect(ctr).toBeNull();
  });

  it("404 NOT_FOUND for an unknown quote id", async () => {
    const { accessToken } = await seedAuthed();
    const res = await send(uuidv7(), accessToken);
    expect(res.status).toBe(404);
  });

  it("404 NOT_FOUND for a quote owned by another user", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(404);
  });
});

describe("GET /quotes/dl/:token", () => {
  it("streams the quote PDF for a valid token (public, no auth)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const sent = (await (await send(quoteId, accessToken)).json()) as any;

    const dl = await SELF.fetch(sent.pdfUrl); // no auth header
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %

    // The token verifies under the test key + points at the quote's R2 key.
    const token = sent.pdfUrl.slice(sent.pdfUrl.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toBe(`${userId}/quotes/${quoteId}.pdf`);
  });

  it("returns 403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/quotes/dl/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/x/quotes/y.pdf", -10);
    const res = await SELF.fetch(`${BASE}/quotes/dl/${token}`);
    expect(res.status).toBe(403);
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- quotes-send`. Expect failures: the route is not mounted yet (every `POST /quotes/:id/send` returns 404 from the app, and the `import` of `../src/routes/quotes` happens transitively only once mounted). Specifically `../src/routes/quotes` does not exist, so the route can't be reached; the assertions on 200/recompute fail.

  > The route file does not exist yet AND is not mounted (Task 9). This test will pass only after BOTH this task (the route file) AND Task 9 (mounting + PUBLIC_PATHS) are done. To keep TDD honest within this task, after Step 3 run the focused unit pieces that don't need mounting are none — so this task's GREEN gate is deferred to Task 9 Step 4. Mark Step 4 below as "expect still FAIL until mounted" and the true GREEN is asserted in Task 9.

- [ ] **Step 3: Write the route.** Create `src/routes/quotes.ts` with this complete content:

```ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { uuidv7 } from "../lib/ids";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignQuoteNumber } from "../lib/quoteCounter";
import { buildQuotePdf, type QuoteLineItemRow, type QuoteSender } from "../lib/pdfQuote";
import * as emailModule from "../lib/email";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";

/**
 * POST /quotes/:id/send        — Bearer (global auth) + rate tier "quotes" (app.ts).
 * GET  /quotes/dl/:token       — PUBLIC (in PUBLIC_PATHS); streams the signed R2 PDF.
 *
 * The ONLY new quote routes — quote/line-item/client CRUD stays on /sync.
 */
export const quotesRoutes = new Hono<AppEnv>();

interface QuoteRow {
  id: string;
  user_id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  gst_enabled: number;
  valid_until: string | null;
}

interface LineItemRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** UTC YYYY-MM-DD for an epoch-ms instant. */
function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

quotesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, valid_until
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<QuoteRow>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  // 2. Load its non-deleted line items (deterministic order).
  const { results: lineItems } = await c.env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM quote_line_items
      WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(quoteId, userId).all<LineItemRow>();
  if (lineItems.length === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot send a quote with no line items");
  }

  // 2b. Email PRECONDITION — validate BEFORE any mutation. When the EMAIL binding
  // is present the route will attempt a send, so a missing client email is a hard
  // 400 that must NOT burn a number / flip status / write R2 / log an outbox row.
  // (When EMAIL is absent we never send, so a null client email is allowed — the
  // PDF + signed link are still returned, emailed:false.) This ordering honours
  // spec §8: on a validation failure no number is consumed and the quote stays draft.
  const emailEnabled = Boolean(c.env.EMAIL);
  if (emailEnabled && !quote.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Quote has no client email to send to");
  }

  // 3. Recompute totals authoritatively.
  const gstEnabled = quote.gst_enabled === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
  );

  // 4. Mint SN-#### only on the first send; a re-send keeps the existing number.
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));

  // 5. Load the owning profile for the PDF sender block.
  const profile = await c.env.DB.prepare(
    `SELECT name, abn, gst_registered FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<{ name: string; abn: string | null; gst_registered: number | null }>();
  if (!profile) throw new ApiError("NOT_FOUND", "Profile not found for this quote");
  const sender: QuoteSender = {
    name: profile.name,
    abn: profile.abn,
    gstRegistered: profile.gst_registered === 1,
  };

  // 6. Build the PDF -> R2.
  const now = nowMs();
  const pdf = await buildQuotePdf(
    {
      number,
      clientName: quote.client_name,
      clientEmail: quote.client_email,
      gstEnabled,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      validUntil: quote.valid_until,
      issuedDate: utcDate(now),
    },
    lineItems.map((li): QuoteLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/quotes/${quoteId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });

  // 7. Persist totals + number + status=sent + sent_at.
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, status = 'sent', sent_at = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, now, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 8. Signed 7-day download link.
  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/quotes/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // 9. email_outbox row + gated send.
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'quote_send', ?, 'queued', 'pdf', ?, ?, ?)`,
  ).bind(outboxId, userId, quote.client_email ?? "", `Quote ${number}`, key, quoteId, now).run();

  let emailed = false;
  // GATED on env.EMAIL exactly like the F2 accountant export: absent -> no send,
  // emailed:false, outbox left queued, no crash. The missing-client-email case is
  // already rejected as a 400 in step 2b BEFORE any mutation, so inside this branch
  // quote.client_email is guaranteed non-null when emailEnabled is true.
  if (emailEnabled && quote.client_email) {
    const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
      .bind(userId).first<{ email: string | null }>();
    try {
      await emailModule.sendQuoteEmail(c.env, {
        to: quote.client_email,
        replyTo: trader?.email ?? "noreply@snapceipt.app",
        quoteNumber: number,
        clientName: quote.client_name,
        totalCents: totals.totalCents,
        pdf,
      });
      await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
        .bind(nowMs(), outboxId).run();
      emailed = true;
    } catch (err) {
      await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
        .bind(String(err instanceof Error ? err.message : err), outboxId).run();
      emailed = false;
    }
  }

  // 10. Response.
  return c.json({
    number,
    sentAt: now,
    status: "sent",
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
    emailed,
  });
});

// PUBLIC: GET /quotes/dl/:token — verify the signed token + stream the R2 PDF.
quotesRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Quote PDF not found");

  // Buffer fully (mirrors export.ts) so the R2 read completes before the response
  // returns — a dangling stream blocks vitest-pool-workers teardown.
  const bytes = await obj.arrayBuffer();
  const contentType = obj.httpMetadata?.contentType ?? "application/octet-stream";
  const filename = r2Key.slice(r2Key.lastIndexOf("/") + 1);
  return new Response(bytes, {
    status: 200,
    headers: {
      "content-type": contentType,
      "content-disposition": `attachment; filename="${filename}"`,
    },
  });
});
```

- [ ] **Step 4: Run the test — expect STILL FAIL (route not mounted).** Run `npm test -- quotes-send`. Expect failures: `POST /quotes/:id/send` returns 404 (the app does not mount `/quotes` yet) and `/quotes/dl/:token` returns 401 (not yet in `PUBLIC_PATHS`). This is expected — the GREEN gate is Task 9. Do NOT attempt to fix it here.

- [ ] **Step 5: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors (the route file references only verified symbols: `recomputeTotals`/`QuoteLineItemAmounts`, `assignQuoteNumber`, `buildQuotePdf`/`QuoteLineItemRow`/`QuoteSender`, `sendQuoteEmail`, `signDownloadToken`/`verifyDownloadToken`/`DOWNLOAD_TTL_SECONDS`, `ApiError`, `nowMs`, `uuidv7`).

- [ ] **Step 6: Commit.**

```bash
git add src/routes/quotes.ts test/quotes-send.test.ts
git commit -m "$(cat <<'EOF'
Add POST /quotes/:id/send + public GET /quotes/dl/:token (unmounted)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 7:** unit `270` (the 11 new `quotes-send` tests are written but RED until Task 9; do not count them as passing yet); e2e `13`. The `quotes-send` file will not be GREEN until Task 9.

---

### Task 8: Add the `quotes` rate tier

**Files:**
- Modify: `src/middleware/rateLimit.ts` (`RATE_LIMIT_TIERS` ~line 36, `RateLimitKind` ~line 52, the tier selector ~line 146)

Spec §4.3/§5: a `quotes` tier of 60/user/hr (the public download is IP-limited via the same tier when unauthenticated, exactly like `export`). This task has no isolated test — the tier is exercised by the route-reachability test in Task 9 and is otherwise a pure additive config. `npm run typecheck` + the existing `test/rateLimit.test.ts` (unaffected) are the gate.

- [ ] **Step 1: Add the tier.** In `src/middleware/rateLimit.ts`, in `RATE_LIMIT_TIERS` (after the `export` entry, line 46), insert:

```ts
  /** quote send — PDF build + email; 60/user/hr. */
  quotes: { name: "quotes", limit: 60, windowMs: HOUR_MS, dimension: "user" },
```

- [ ] **Step 2: Extend `RateLimitKind`.** Replace the `RateLimitKind` type (line 52):

```ts
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "default";
```

with:

```ts
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "quotes" | "default";
```

- [ ] **Step 3: Wire the selector.** In the `rateLimit` factory, replace the tier-selection ternary (lines 146–153):

```ts
    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : kind === "export"
            ? RATE_LIMIT_TIERS.export
            : RATE_LIMIT_TIERS.default;
```

with:

```ts
    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : kind === "export"
            ? RATE_LIMIT_TIERS.export
            : kind === "quotes"
              ? RATE_LIMIT_TIERS.quotes
              : RATE_LIMIT_TIERS.default;
```

- [ ] **Step 4: Run typecheck + the rate-limit suite — expect PASS.** Run `npm run typecheck` then `npm test -- rateLimit`. Expect no type errors and the existing rate-limit tests still pass (additive tier, no behavior change to existing tiers).

- [ ] **Step 5: Commit.**

```bash
git add src/middleware/rateLimit.ts
git commit -m "$(cat <<'EOF'
Add quotes rate tier (60/user/hr)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 8:** unit `270` (no new passing tests); e2e `13`.

---

### Task 9: Mount `/quotes` + add `/quotes/dl/` to `PUBLIC_PATHS`

**Files:**
- Modify: `src/app.ts` (import + rate-tier mount + route mount)
- Modify: `src/middleware/auth.ts` (`PUBLIC_PATHS`, line 11)
- Create (test): `test/quotes-app.test.ts`

This wires the route mounted in Task 7 into the app: the rate-tier mount mirrors `/export` (exact path + wildcard), the route mount mirrors `app.route("/export", exportRoutes)`, and `/quotes/dl/` joins `PUBLIC_PATHS` so the download is reachable without auth. After this task, the Task 7 `quotes-send` suite goes GREEN.

- [ ] **Step 1: Write the FAILING reachability test.** Create `test/quotes-app.test.ts` with this complete content:

```ts
import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("/quotes (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/quotes/some-id/send", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("GET /quotes/dl/* is public (no auth) — a forged token is 403, not 401", async () => {
    const res = await SELF.fetch("https://x/quotes/dl/forged");
    expect(res.status).toBe(403);
  });
});
```

- [ ] **Step 2: Run the test — expect FAIL.** Run `npm test -- quotes-app`. Expect the second test fails: `/quotes/dl/forged` returns 401 (not yet public) instead of 403. (The first test may pass already because an unmounted `/quotes/*` is also auth-gated; the public-path test is the discriminator.)

- [ ] **Step 3: Add `/quotes/dl/` to `PUBLIC_PATHS`.** In `src/middleware/auth.ts`, replace the `PUBLIC_PATHS` line (line 11):

```ts
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/"];
```

with:

```ts
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/quotes/dl/"];
```

- [ ] **Step 4: Mount the route + rate tier in `src/app.ts`.** First add the import after the `exportRoutes` import (line 14):

```ts
import { quotesRoutes } from "./routes/quotes";
```

Then add the rate-tier mount immediately after the `/export` + `/export/*` block (line 68):

```ts
// Quote send — PDF build + email; 60/hr. Mount on BOTH the exact path
// (POST /quotes/:id/send) AND the wildcard so the limiter runs for the actual
// POST too. The wildcard also covers the public GET /quotes/dl/* download:
// since that route is unauthenticated, the "quotes" tier (dimension: user)
// falls back to IP-keyed limiting on the public endpoint.
app.use("/quotes", rateLimit("quotes"));
app.use("/quotes/*", rateLimit("quotes"));
```

Then add the route mount immediately after `app.route("/export", exportRoutes);` (line 84):

```ts
// Protected: POST /quotes/:id/send (+ public GET /quotes/dl/:token via PUBLIC_PATHS).
app.route("/quotes", quotesRoutes);
```

- [ ] **Step 5: Run the reachability + send suites — expect PASS.** Run `npm test -- quotes-app quotes-send`. Expect `quotes-app` (2) + `quotes-send` (11) all pass: the route is now mounted, `/quotes/dl/` is public, the send pipeline recomputes/mints/sends/streams correctly, and the email is spied.

- [ ] **Step 6: Run typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors.

- [ ] **Step 7: Commit.**

```bash
git add src/app.ts src/middleware/auth.ts test/quotes-app.test.ts
git commit -m "$(cat <<'EOF'
Mount /quotes route + quotes rate tier + public /quotes/dl path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 9:** unit `283` (270 + the 11 now-GREEN `quotes-send` tests + 2 `quotes-app` tests); e2e `13`.

---

### Task 10: e2e — real-HTTP `POST /quotes/:id/send` + `/quotes/dl` round-trip

**Files:**
- Create: `e2e/quotes.e2e.test.ts`

Boots the real worker via `unstable_dev` (mirrors `e2e/snapceipt-export.e2e.test.ts` exactly: `applyMigrations` helper, `unstable_dev` with `E2E_TEST_MODE="1"`, the `api()` JSON helper, the magic-link `devToken` seam). The quote + line items are seeded through the real `/sync/push` (the test seam — no CRUD route), then `POST /quotes/:id/send` is exercised over a real socket, and the returned `pdfUrl` is downloaded back (public, no auth). The migrations apply picks up `0002` automatically (the `d1 migrations apply` globs the dir).

> **⚠ LIVE `EMAIL.send` in e2e — verify the local Miniflare behavior FIRST.** Unlike the F2 export e2e (which only exercises `csv` + the accountant-validation *rejection*, and so NEVER reaches a live `EMAIL.send`), this quotes e2e seeds a quote WITH a client email, so with the `send_email` binding present in `unstable_dev` local mode the route WILL invoke `c.env.EMAIL.send` for real. Local `workerd`/Miniflare's `send_email` binding does not deliver mail; depending on the runtime version it either (a) resolves/no-ops, (b) throws synchronously (→ the route catch sets `emailed:false`, outbox `failed`, still 200), or — the risk — (c) blocks. The route's try/catch isolates (a)/(b), and the e2e asserts ONLY the structural response (`number`/`status`/`pdfUrl`/`subtotalCents`/`gstCents`/`totalCents`) + the PDF download — never `emailed` (environment-dependent). **Before marking Step 2 GREEN, the implementer MUST run the e2e once and confirm the send returns within the timeout.** If local `EMAIL.send` hangs/times out, fall back to the deterministic variant below (Step 1b) which makes the send a guaranteed fast no-op by mocking `globalThis`'s SendEmail is NOT possible black-box — instead seed the quote so the trader's own profile + a real recipient still produce a valid send attempt, and bump `testTimeout`; if it still hangs, narrow the e2e to assert the send pipeline up to the 200 + download and drop the re-send leg.

- [ ] **Step 1: Write the e2e test.** Create `e2e/quotes.e2e.test.ts` with this complete content:

```ts
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-quotes-"));
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

describe("e2e (real HTTP): POST /quotes/:id/send -> /quotes/dl round-trip", () => {
  it("seeds a quote via /sync, sends it, mints SN-0001, downloads the PDF back", async () => {
    const email = `e2e-quote+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.91";

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
    const quoteId = crypto.randomUUID();
    const li1 = crypto.randomUUID();
    const li2 = crypto.randomUUID();
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
              profileType: "business", abn: "12 345 678 901", gstRegistered: true,
              accent1: "#000", accent2: "#111", accent3: "#222",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quote", entityId: quoteId,
            op: "upsert", updatedAt: t,
            payload: {
              id: quoteId, userId, profileId, type: "quote",
              clientName: "Jane Roe", clientEmail: "jane@example.com",
              gstEnabled: true, currency: "AUD", status: "draft", validUntil: "2026-06-15",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quoteLineItem", entityId: li1,
            op: "upsert", updatedAt: t,
            payload: {
              id: li1, userId, type: "quoteLineItem", quoteId,
              description: "Site inspection", quantity: 1, unitPriceCents: 25000, sortOrder: 0,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "quoteLineItem", entityId: li2,
            op: "upsert", updatedAt: t,
            payload: {
              id: li2, userId, type: "quoteLineItem", quoteId,
              description: "Report", quantity: 2, unitPriceCents: 40000, sortOrder: 1,
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushRes.status).toBe(200);

    // Send the quote.
    const sendRes = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: authHeaders, body: {} });
    expect(sendRes.status).toBe(200);
    expect(sendRes.json.number).toBe("SN-0001");
    expect(sendRes.json.status).toBe("sent");
    expect(sendRes.json.subtotalCents).toBe(105000);
    expect(sendRes.json.gstCents).toBe(10500);
    expect(sendRes.json.totalCents).toBe(115500);
    expect(typeof sendRes.json.sentAt).toBe("number");
    expect(typeof sendRes.json.pdfUrl).toBe("string");
    expect(sendRes.json.pdfUrl).toContain("/quotes/dl/");

    // Download the PDF back (public, no auth) — slice off the absolute origin.
    const dlPath = sendRes.json.pdfUrl.slice(baseUrl.length);
    const dl = await api(dlPath);
    expect(dl.status).toBe(200);
    expect(dl.text.startsWith("%PDF")).toBe(true);

    // Re-send keeps the number.
    const resend = await api(`/quotes/${quoteId}/send`, { method: "POST", headers: authHeaders, body: {} });
    expect(resend.status).toBe(200);
    expect(resend.json.number).toBe("SN-0001");
  });

  it("returns 403 for a forged quote download token", async () => {
    const res = await api("/quotes/dl/not.a.real.token");
    expect(res.status).toBe(403);
  });
});
```

- [ ] **Step 2: Run the e2e test — expect PASS.** Run `npm run test:e2e -- quotes`. Expect both tests pass (boots a worker, signs in, syncs a quote, sends it, downloads the PDF, re-sends).

- [ ] **Step 3: Run the full e2e suite — expect GREEN (15 = 13 + 2).** Run `npm run test:e2e`. Expect all pass; the new file adds two tests on top of the prior 13.

- [ ] **Step 4: Commit.**

```bash
git add e2e/quotes.e2e.test.ts
git commit -m "$(cat <<'EOF'
Add e2e quotes send + dl round-trip over real HTTP

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Running totals after Task 10:** unit `283`; e2e `15` (13 + 2).

---

### Task 11: Full-suite verification gate

**Files:** none (verification only).

- [ ] **Step 1: Typecheck — expect PASS.** Run `npm run typecheck`. Expect no errors.

- [ ] **Step 2: Full unit suite — expect GREEN (283).** Run `npm test`. Expect all pass: the prior 253 baseline plus the new `test/schema-clients.test.ts` (5: 4 schema + 1 round-trip), `test/quoteTotals.test.ts` (5), `test/quoteCounter.test.ts` (2), `test/pdfQuote.test.ts` (3), `test/email-quote.test.ts` (2), `test/quotes-send.test.ts` (11), `test/quotes-app.test.ts` (2) = 253 + 30 = **283**, with no regressions to the existing 253 (verify `test/schema.test.ts`, `test/schemas.test.ts`, `test/sync-push.test.ts`, `test/sync-pull.test.ts`, `test/email.test.ts`, `test/export-route.test.ts`, `test/rateLimit.test.ts` are all still green).

- [ ] **Step 3: Full e2e suite — expect GREEN (15).** Run `npm run test:e2e`. Expect 15 (13 prior + the new `e2e/quotes.e2e.test.ts` 2).

- [ ] **Step 4: Final review.** Run `git log --oneline -10` to confirm the feature commits are present (Tasks 1–10 = 10 commits) and the tree is clean (`git status`).
