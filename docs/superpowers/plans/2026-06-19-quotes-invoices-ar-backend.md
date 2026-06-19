# Quotes PDF + Invoices & Accounts-Receivable — Backend Implementation Plan

> REQUIRED SUB-SKILL: superpowers:test-driven-development — every task is written as a
> red→green→commit TDD loop. Use the agentic-workers executing-plans flow with a review
> checkpoint after each task.

## Goal

Ship the **backend slice** of the Quotes-PDF + Invoices/A-R feature (spec §9 "backend plan"):
the additive migration `0009`, sync wiring for the three new entities (`invoice`,
`invoiceLineItem`, `payment`), the tax-invoice PDF builder (`pdfInvoice.ts`), the per-profile
invoice counter (`invoiceCounter.ts`), and the five new routes:

- `POST /quotes/:id/pdf` — build/store the quote PDF, persist `pdf_r2_key`, mint the number if
  absent. **No email, no status change.**
- `POST /invoices/:id/issue` — mint the invoice number, build the tax-invoice PDF → R2, set
  `status=issued` + dates + `pdf_r2_key`.
- `POST /invoices/:id/send` — ensure a PDF, email the client (reuse the quote email path),
  `email_outbox.kind='invoice_send'`.
- `POST /invoices/:id/pdf` — (re)build/return the invoice PDF for share.
- `GET /invoices/dl/:token` — public PDF download (mirror `quotes/dl`).

Invoice drafts, invoice line items, and payments are created/edited purely through the generic
`/sync` upsert — **no bespoke CRUD routes** (spec §6).

The iOS slice (models, mappers, editors, list views, convert flow, record-payment) is a
**separate plan** and is out of scope here.

## Architecture

Cloudflare Workers + Hono. Routes mount at module scope in `src/app.ts`. The global bearer-auth
middleware (`src/middleware/auth.ts`) resolves `c.var.userId` / `c.var.deviceId` for protected
routes; public paths live in `PUBLIC_PATHS`. State lives in D1 (`c.env.DB`); generated PDFs live
in R2 (`c.env.RECEIPTS`). Email goes through the `src/lib/email.ts` seam (spy-able under vitest;
the live `EMAIL` binding is not materialized in the test runtime). Download links are signed
HS256 tokens (`src/lib/exportToken.ts`) verified on the public `dl` route.

The new routes **mirror `POST /quotes/:id/send` exactly**: load row scoped to `user_id`, load
non-deleted line items in deterministic order, recompute totals authoritatively
(`recomputeTotals`), mint a number atomically when absent, build a PDF, `put` to R2, persist
authoritative fields, sign a 7-day token, and (for send) write an `email_outbox` row + attempt
the send inside try/catch.

## Tech Stack

- Runtime: Cloudflare Workers (`workerd`), Hono `^4.12`.
- DB: D1 (SQLite). Migrations are forward-only SQL files under `migrations/`.
- Storage: R2 (`RECEIPTS` binding).
- PDF: `pdf-lib` `^1.17` StandardFonts (no font file, no images — pure-JS, Workers-safe).
- Validation: `zod` `^3.23`.
- Tests: `vitest` `~2.1` via `@cloudflare/vitest-pool-workers` `^0.8.71`. Run with `npm test`.
  Focus a single file with `npm test -- <path>` (vitest passes the path as a name/file filter).

## Global Constraints

- **SPINE conventions:** ids = UUIDv7 TEXT; money = INTEGER cents; timestamps = INTEGER epoch
  ms; dates = TEXT `YYYY-MM-DD`. Booleans persist as `0/1`.
- **Tenancy:** every D1 read/write is scoped `WHERE ... user_id = ?` (the authed `c.var.userId`).
  Never trust a client-sent `userId`.
- **GST rate:** 10% AU GST. Exclusive: `subtotal=gross`, `gst=round(gross*0.10)`,
  `total=gross+gst`. Inclusive: `total=gross`, `gst=round(gross*0.10/1.10)`,
  `subtotal=gross-gst`. Invariant `subtotalCents + gstCents === totalCents` holds in every mode.
  Reuse `recomputeTotals` from `src/lib/quoteTotals.ts` — do not re-derive.
- **Quote PDF generation does NOT change status** (spec §2.1): it mints `number` if absent but
  leaves `status='draft'`; it persists `quotes.pdf_r2_key`.
- **Invoice numbering** is per-profile monotonic, minted atomically **only on issue**, format
  `INV-####` (4-digit zero-padded). Re-issue keeps the existing number.
- **Invoice statuses:** `draft | issued | void`. Payment state is **derived** (not stored).
- **Download TTL:** 7 days (`DOWNLOAD_TTL_SECONDS`). Download tokens carry the R2 key claim `rk`.
- **R2 key layout:** quotes → `${userId}/quotes/${quoteId}.pdf`; invoices →
  `${userId}/invoices/${invoiceId}.pdf`.
- **Rate tiers** reuse the `quotes` tier for `/invoices/*` (PDF build + email, 60/hr).
- **No push, no payment gateway, no recurring invoices, no multi-currency** beyond AUD.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

```
migrations/
  0009_invoices_ar.sql                 (CREATE) migration 0009

src/
  lib/
    invoiceCounter.ts                  (CREATE) per-profile INV-#### counter
    pdfInvoice.ts                      (CREATE) tax-invoice PDF builder
    invoiceTotals.ts                   (CREATE) derived A/R helpers (amountPaid / paymentState / isOverdue)
    email.ts                           (MODIFY) add sendInvoiceEmail seam
  schemas/
    entities.ts                        (MODIFY) + invoice/invoiceLineItem/payment schemas + SYNCABLE_TYPES
  lib/
    syncTables.ts                      (MODIFY) + 3 table maps; invoice in PROFILE_ID_REQUIRED
  routes/
    quotes.ts                          (MODIFY) + POST /:id/pdf
    invoices.ts                        (CREATE) issue / send / pdf / dl
  middleware/
    auth.ts                            (MODIFY) + "/invoices/dl/" in PUBLIC_PATHS
  app.ts                               (MODIFY) mount invoicesRoutes + rate tier

test/
  invoiceCounter.test.ts               (CREATE) Task 2
  invoiceTotals.test.ts                (CREATE) Task 3
  pdfInvoice.test.ts                   (CREATE) Task 4
  schemas-invoices.test.ts             (CREATE) Task 5 (schemas)
  sync-invoices.test.ts                (CREATE) Task 6 (sync round-trip)
  quotes-pdf.test.ts                   (CREATE) Task 7 (POST /quotes/:id/pdf)
  invoices-issue.test.ts               (CREATE) Task 8 (POST /invoices/:id/issue + dl)
  invoices-send-pdf.test.ts            (CREATE) Task 9 (send + pdf + app mount)
```

Task order (each independently testable; migration + sync wiring land before the routes that
depend on them):

1. Migration `0009` (tables + columns + `email_outbox` rebuild).
2. `invoiceCounter.ts` (depends on migration table `invoice_counters`).
3. `invoiceTotals.ts` (pure; no DB).
4. `pdfInvoice.ts` (pure; no DB).
5. Schemas (`entities.ts`) for the 3 new entities + `SYNCABLE_TYPES`.
6. Sync wiring (`syncTables.ts`) + sync round-trip test.
7. `POST /quotes/:id/pdf` (depends on migration `quotes.pdf_r2_key`).
8. `POST /invoices/:id/issue` + `GET /invoices/dl/:token` (depends on 1,2,4 + mount in 9).
9. `POST /invoices/:id/send` + `POST /invoices/:id/pdf` + mount in `app.ts` + `PUBLIC_PATHS`.

---

## Task 1 — Migration 0009: invoices, invoice_line_items, payments, quotes columns, email_outbox rebuild

**Files**
- CREATE `migrations/0009_invoices_ar.sql`
- TEST: covered transitively — the migration is exercised by every later route/sync test via
  `applyD1Migrations(env.DB, env.TEST_MIGRATIONS)`. This task adds no standalone test file; its
  verification is `npm run typecheck` (no TS change) plus the `invoiceCounter` test in Task 2,
  which is the first consumer of a new table. A focused smoke assertion lives in Task 6's
  sync test (`invoices`/`payments` tables are queryable).

**Interfaces**
- Produces (D1 schema):
  - `invoices(id, user_id, profile_id, number, quote_id, client_name, client_email, gst_enabled,
    gst_inclusive, subtotal_cents, gst_cents, total_cents, currency, status, issue_date, due_date,
    issued_at, pdf_r2_key, created_at, updated_at, deleted_at, rev, last_edited_device_id)`
  - `invoice_line_items(id, user_id, invoice_id, description, quantity, unit_price_cents,
    line_total_cents GENERATED, sort_order, …sync cols)`
  - `payments(id, user_id, invoice_id, amount_cents, paid_on, method, note, …sync cols)`
  - `invoice_counters(profile_id PRIMARY KEY, next_seq)`
  - `quotes` gains `pdf_r2_key TEXT`, `invoice_id TEXT`.
  - `email_outbox.kind` CHECK gains `'invoice_send'`.
- Note: `invoice_line_items.line_total_cents` is a STORED generated column
  (`quantity * unit_price_cents`) — mirror `quote_line_items`; it is NOT a sync-writable column.
- Note: SQLite cannot ALTER a CHECK constraint, so `email_outbox` is rebuilt (new table → copy →
  drop → rename → recreate indexes), mirroring the additive style of `0001`.

### Step 1.1 — Write the migration

CREATE `migrations/0009_invoices_ar.sql`:

```sql
-- 0009_invoices_ar.sql — Invoices + accounts-receivable (spec §3, §4.1, §4.5).
-- Forward-only. Additive new tables + two additive quotes columns; the email_outbox
-- rebuild adds 'invoice_send' to the kind CHECK (SQLite cannot ALTER a CHECK, so the
-- table is recreated: copy rows, drop, rename, recreate indexes). ids = UUIDv7 TEXT.
-- Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
-- Syncable tables carry: id, user_id, created_at, updated_at, deleted_at, rev, last_edited_device_id.
PRAGMA foreign_keys = OFF;

-- =========================================================================
-- invoices — issued tax invoices (synced via the generic /sync upsert).
-- status: draft (editable) | issued (number + PDF + dates minted) | void.
-- number is minted on issue only; quote_id links back to the origin quote.
-- =========================================================================
CREATE TABLE invoices (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  profile_id            TEXT NOT NULL REFERENCES profiles(id),
  number                TEXT,
  quote_id              TEXT REFERENCES quotes(id),
  client_name           TEXT,
  client_email          TEXT,
  gst_enabled           INTEGER NOT NULL DEFAULT 1,
  gst_inclusive         INTEGER NOT NULL DEFAULT 0,
  subtotal_cents        INTEGER NOT NULL DEFAULT 0,
  gst_cents             INTEGER NOT NULL DEFAULT 0,
  total_cents           INTEGER NOT NULL DEFAULT 0,
  currency              TEXT NOT NULL DEFAULT 'AUD',
  status                TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','void')),
  issue_date            TEXT,
  due_date              TEXT,
  issued_at             INTEGER,
  pdf_r2_key            TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_invoice_user_updated   ON invoices(user_id, updated_at);
CREATE INDEX ix_invoice_profile_status ON invoices(profile_id, status) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX ux_invoice_number  ON invoices(profile_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL;

-- =========================================================================
-- invoice_line_items — clone of quote_line_items (line_total_cents generated).
-- =========================================================================
CREATE TABLE invoice_line_items (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  invoice_id            TEXT NOT NULL REFERENCES invoices(id),
  description           TEXT NOT NULL,
  quantity              INTEGER NOT NULL DEFAULT 1,
  unit_price_cents      INTEGER NOT NULL,
  line_total_cents      INTEGER GENERATED ALWAYS AS (quantity * unit_price_cents) STORED,
  sort_order            INTEGER NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_ili_invoice      ON invoice_line_items(invoice_id);
CREATE INDEX ix_ili_user_updated ON invoice_line_items(user_id, updated_at);

-- =========================================================================
-- payments — multiple rows per invoice; payment state is DERIVED, never stored.
-- =========================================================================
CREATE TABLE payments (
  id                    TEXT PRIMARY KEY,
  user_id               TEXT NOT NULL REFERENCES users(id),
  invoice_id            TEXT NOT NULL REFERENCES invoices(id),
  amount_cents          INTEGER NOT NULL,
  paid_on               TEXT NOT NULL,
  method                TEXT,
  note                  TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  deleted_at            INTEGER,
  rev                   INTEGER NOT NULL DEFAULT 0,
  last_edited_device_id TEXT
);
CREATE INDEX ix_payment_invoice      ON payments(invoice_id);
CREATE INDEX ix_payment_user_updated ON payments(user_id, updated_at);

-- =========================================================================
-- invoice_counters — server-only per-PROFILE INV-#### sequence. NOT synced. The
-- issue route increments next_seq atomically (INSERT … ON CONFLICT … RETURNING) so
-- concurrent issues never collide; invoices.ux_invoice_number is the unique backstop.
-- =========================================================================
CREATE TABLE invoice_counters (
  profile_id TEXT PRIMARY KEY REFERENCES profiles(id),
  next_seq   INTEGER NOT NULL
);

-- =========================================================================
-- quotes — additive columns: the persisted quote-PDF R2 key (re-shareable from
-- history) and the one-to-one origin link to the converted invoice. Pure ADD
-- COLUMN (non-rewriting in SQLite/D1).
-- =========================================================================
ALTER TABLE quotes ADD COLUMN pdf_r2_key TEXT;
ALTER TABLE quotes ADD COLUMN invoice_id TEXT;

-- =========================================================================
-- email_outbox — rebuild to add 'invoice_send' to the kind CHECK. SQLite cannot
-- ALTER a CHECK, so recreate the table, copy rows, drop, rename, recreate indexes.
-- =========================================================================
CREATE TABLE email_outbox_new (
  id            TEXT PRIMARY KEY,
  user_id       TEXT REFERENCES users(id),
  to_email      TEXT NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('magic_link','export_accountant','quote_send','invoice_send')),
  subject       TEXT,
  status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed')),
  export_format TEXT CHECK (export_format IN ('pdf','csv') OR export_format IS NULL),
  export_r2_key TEXT,
  related_id    TEXT,
  error         TEXT,
  attempts      INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  sent_at       INTEGER
);
INSERT INTO email_outbox_new
  (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, error, attempts, created_at, sent_at)
SELECT
  id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, error, attempts, created_at, sent_at
FROM email_outbox;
DROP TABLE email_outbox;
ALTER TABLE email_outbox_new RENAME TO email_outbox;
CREATE INDEX ix_outbox_status ON email_outbox(status, created_at);
CREATE INDEX ix_outbox_user   ON email_outbox(user_id);
```

### Step 1.2 — Apply locally + verify it parses

```
npm run migrate:local
```

Expected output (tail): the wrangler D1 migration runner lists `0009_invoices_ar.sql` as applied
with no SQL error, e.g.

```
🌀 Executing on local database snapceipt ...
🚣 9 migrations applied successfully.
```

(If the local DB already has 0001–0008, the runner reports only `0009_invoices_ar.sql` newly
applied. The exact count depends on local state; the success line + zero errors is the gate.)

### Step 1.3 — Commit

```
git add migrations/0009_invoices_ar.sql
git commit -m "$(cat <<'EOF'
feat(db): migration 0009 — invoices, invoice_line_items, payments, counters + quotes pdf/invoice cols + email_outbox invoice_send

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — invoiceCounter.ts: per-profile INV-#### sequence

**Files**
- CREATE `src/lib/invoiceCounter.ts`
- TEST: CREATE `test/invoiceCounter.test.ts`

**Interfaces**
- Consumes: `D1Database`, `profileId: string`; table `invoice_counters(profile_id, next_seq)`.
- Produces:
  - `export function formatInvoiceNumber(seq: number): string` → `INV-0001`, `INV-0012`, …
  - `export async function assignInvoiceNumber(db: D1Database, profileId: string): Promise<string>`
    — atomic `INSERT … ON CONFLICT(profile_id) DO UPDATE SET next_seq = next_seq + 1 RETURNING
    next_seq`; first call for a profile returns `INV-0001`.

### Step 2.1 — Write the failing test

CREATE `test/invoiceCounter.test.ts`:

```ts
import { env, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { assignInvoiceNumber, formatInvoiceNumber } from "../src/lib/invoiceCounter";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM invoice_counters");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM users");
  await env.DB.batch([
    env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('u1',1,1)`),
    env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES ('pA','u1','A','business','#1','#2','#3',1,1)`,
    ),
    env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES ('pB','u1','B','business','#1','#2','#3',1,1)`,
    ),
  ]);
});

describe("formatInvoiceNumber", () => {
  it("zero-pads to 4 digits with the INV- prefix", () => {
    expect(formatInvoiceNumber(1)).toBe("INV-0001");
    expect(formatInvoiceNumber(42)).toBe("INV-0042");
    expect(formatInvoiceNumber(12345)).toBe("INV-12345");
  });
});

describe("assignInvoiceNumber", () => {
  it("returns INV-0001 then INV-0002 for sequential assigns of one profile", async () => {
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0002");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0003");
  });

  it("keeps per-profile sequences independent", async () => {
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pB")).toBe("INV-0001");
    expect(await assignInvoiceNumber(env.DB, "pA")).toBe("INV-0002");
    expect(await assignInvoiceNumber(env.DB, "pB")).toBe("INV-0002");
  });
});
```

### Step 2.2 — Run it (red)

```
npm test -- test/invoiceCounter.test.ts
```

Expected: the suite fails to load — `Failed to resolve import "../src/lib/invoiceCounter"` (the
module does not exist yet).

### Step 2.3 — Implement

CREATE `src/lib/invoiceCounter.ts`:

```ts
/**
 * Per-PROFILE invoice-number counter (spec §5). The issue route calls this exactly
 * once per invoice — on the FIRST issue, when invoices.number is still NULL. A
 * re-issue keeps the existing number, so this is never called again for that invoice.
 *
 * The assignment is atomic: a single INSERT … ON CONFLICT … RETURNING bumps and
 * returns next_seq in one statement, so two concurrent issues for the same profile
 * get distinct sequences (1, 2) and never collide. invoices.ux_invoice_number
 * (UNIQUE(profile_id, number) WHERE number IS NOT NULL AND deleted_at IS NULL) is
 * the backstop.
 */

/** Format a 1-based sequence as INV-#### (4-digit zero-padded). */
export function formatInvoiceNumber(seq: number): string {
  return `INV-${String(seq).padStart(4, "0")}`;
}

/**
 * Atomically allocate the next per-profile sequence and return the formatted
 * INV-#### number. First call for a profile returns INV-0001, then INV-0002, …
 */
export async function assignInvoiceNumber(db: D1Database, profileId: string): Promise<string> {
  const row = await db
    .prepare(
      `INSERT INTO invoice_counters (profile_id, next_seq) VALUES (?, 1)
       ON CONFLICT(profile_id) DO UPDATE SET next_seq = next_seq + 1
       RETURNING next_seq`,
    )
    .bind(profileId)
    .first<{ next_seq: number }>();
  const seq = row?.next_seq ?? 1;
  return formatInvoiceNumber(seq);
}
```

### Step 2.4 — Run it (green)

```
npm test -- test/invoiceCounter.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  3 passed (3)`.

### Step 2.5 — Commit

```
git add src/lib/invoiceCounter.ts test/invoiceCounter.test.ts
git commit -m "$(cat <<'EOF'
feat(invoices): per-profile INV-#### counter (assignInvoiceNumber)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — invoiceTotals.ts: derived A/R helpers (amountPaid / paymentState / isOverdue)

**Files**
- CREATE `src/lib/invoiceTotals.ts`
- TEST: CREATE `test/invoiceTotals.test.ts`

**Interfaces**
- Consumes: a list of non-deleted payment amounts; the invoice total; status; `dueDate`; today.
- Produces (pure, no DB; identical formula to iOS per spec §4.1):
  - `export interface PaymentAmount { amountCents: number; }`
  - `export function amountPaidCents(payments: PaymentAmount[]): number` — Σ `amountCents`.
  - `export type PaymentState = "unpaid" | "partial" | "paid";`
  - `export function paymentState(totalCents: number, amountPaidCents: number): PaymentState`
    — `paid` if `amountPaid >= total`, else `partial` if `amountPaid > 0`, else `unpaid`.
  - `export function isOverdue(args: { status: string; paymentState: PaymentState; dueDate: string | null; today: string }): boolean`
    — `status === "issued" && paymentState !== "paid" && dueDate != null && today > dueDate`
    (string compare of `YYYY-MM-DD` is lexicographically correct).

### Step 3.1 — Write the failing test

CREATE `test/invoiceTotals.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  amountPaidCents,
  paymentState,
  isOverdue,
  type PaymentAmount,
} from "../src/lib/invoiceTotals";

describe("amountPaidCents", () => {
  it("sums payment amounts", () => {
    const ps: PaymentAmount[] = [{ amountCents: 5000 }, { amountCents: 2500 }, { amountCents: 100 }];
    expect(amountPaidCents(ps)).toBe(7600);
  });

  it("returns 0 for no payments", () => {
    expect(amountPaidCents([])).toBe(0);
  });
});

describe("paymentState", () => {
  it("is unpaid when nothing is paid", () => {
    expect(paymentState(115500, 0)).toBe("unpaid");
  });

  it("is partial when some (but not all) is paid", () => {
    expect(paymentState(115500, 50000)).toBe("partial");
  });

  it("is paid when the full total is paid", () => {
    expect(paymentState(115500, 115500)).toBe("paid");
  });

  it("is paid when overpaid (amountPaid > total)", () => {
    expect(paymentState(115500, 120000)).toBe("paid");
  });

  it("treats a zero-total invoice as paid (degenerate but consistent)", () => {
    expect(paymentState(0, 0)).toBe("paid");
  });
});

describe("isOverdue", () => {
  const base = { status: "issued", paymentState: "unpaid" as const, dueDate: "2026-06-15" };

  it("is overdue when issued, unpaid, and today is past the due date", () => {
    expect(isOverdue({ ...base, today: "2026-06-16" })).toBe(true);
  });

  it("is NOT overdue on the due date itself (boundary)", () => {
    expect(isOverdue({ ...base, today: "2026-06-15" })).toBe(false);
  });

  it("is NOT overdue before the due date", () => {
    expect(isOverdue({ ...base, today: "2026-06-14" })).toBe(false);
  });

  it("is NOT overdue when fully paid even if past due", () => {
    expect(isOverdue({ ...base, paymentState: "paid", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue for a draft invoice", () => {
    expect(isOverdue({ ...base, status: "draft", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue for a void invoice", () => {
    expect(isOverdue({ ...base, status: "void", today: "2026-07-01" })).toBe(false);
  });

  it("is NOT overdue when there is no due date", () => {
    expect(isOverdue({ ...base, dueDate: null, today: "2026-07-01" })).toBe(false);
  });

  it("a partially-paid past-due invoice is overdue", () => {
    expect(isOverdue({ ...base, paymentState: "partial", today: "2026-06-16" })).toBe(true);
  });
});
```

### Step 3.2 — Run it (red)

```
npm test -- test/invoiceTotals.test.ts
```

Expected: fails to load — `Failed to resolve import "../src/lib/invoiceTotals"`.

### Step 3.3 — Implement

CREATE `src/lib/invoiceTotals.ts`:

```ts
/**
 * Derived accounts-receivable helpers (spec §4.1). PURE — no DB, no I/O. The iOS
 * app computes the IDENTICAL formula on-device for badges; the issue/send routes
 * and the PDF builder reuse these on the server. Keep the two in lock-step.
 *
 * Money in cents; dates are "YYYY-MM-DD" (lexicographic compare == chronological).
 *   amountPaidCents = Σ non-deleted Payment.amountCents.
 *   paymentState    = paid (amountPaid >= total) | partial (amountPaid > 0) | unpaid.
 *   isOverdue       = status==issued && paymentState!=paid && today > dueDate.
 */

/** The single amount needed per payment to derive A/R state. */
export interface PaymentAmount {
  amountCents: number;
}

export type PaymentState = "unpaid" | "partial" | "paid";

/** Σ of the (already non-deleted) payment amounts. */
export function amountPaidCents(payments: PaymentAmount[]): number {
  let sum = 0;
  for (const p of payments) sum += p.amountCents;
  return sum;
}

/** Derive the payment state from the invoice total and the amount paid. */
export function paymentState(totalCents: number, paidCents: number): PaymentState {
  if (paidCents >= totalCents) return "paid";
  if (paidCents > 0) return "partial";
  return "unpaid";
}

/**
 * An invoice is overdue when it is issued, not fully paid, has a due date, and
 * today is strictly past that due date. `today` and `dueDate` are "YYYY-MM-DD"
 * strings, which compare correctly with `>`.
 */
export function isOverdue(args: {
  status: string;
  paymentState: PaymentState;
  dueDate: string | null;
  today: string;
}): boolean {
  return (
    args.status === "issued" &&
    args.paymentState !== "paid" &&
    args.dueDate != null &&
    args.today > args.dueDate
  );
}
```

### Step 3.4 — Run it (green)

```
npm test -- test/invoiceTotals.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  17 passed (17)`.

### Step 3.5 — Commit

```
git add src/lib/invoiceTotals.ts test/invoiceTotals.test.ts
git commit -m "$(cat <<'EOF'
feat(invoices): derived A/R helpers — amountPaid / paymentState / isOverdue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — pdfInvoice.ts: tax-invoice PDF builder

**Files**
- CREATE `src/lib/pdfInvoice.ts`
- TEST: CREATE `test/pdfInvoice.test.ts`

**Interfaces**
- Consumes (pure; route recomputes totals + passes them in):
  - `export interface InvoiceSender { name: string; abn: string | null; gstRegistered: boolean; }`
  - `export interface InvoiceLineItemRow { description: string; quantity: number; unitPriceCents: number; }`
  - `export interface InvoicePdfData { number: string | null; clientName: string | null;
    clientEmail: string | null; gstEnabled: boolean; gstInclusive: boolean; subtotalCents: number;
    gstCents: number; totalCents: number; issueDate: string; dueDate: string | null;
    amountPaidCents: number; }`
- Produces:
  - `export async function buildInvoicePdf(invoice: InvoicePdfData, lineItems: InvoiceLineItemRow[],
    sender: InvoiceSender): Promise<Uint8Array>` — returns encoded `%PDF` bytes.
- Content (spec §4.3): **"Tax invoice"** heading; seller name + ABN + "Registered for GST";
  invoice number; issue date + due date; bill-to; line items (desc · qty · unit · line total);
  subtotal / GST(10%) / total; "Total price includes GST $X" in inclusive mode; plus an
  **Amount paid / Balance due** ledger when `amountPaidCents > 0`. Mirrors `pdfQuote.ts` drawing
  helpers (A4, StandardFonts, `draw()` paginator).

### Step 4.1 — Write the failing test

CREATE `test/pdfInvoice.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import {
  buildInvoicePdf,
  type InvoicePdfData,
  type InvoiceLineItemRow,
  type InvoiceSender,
} from "../src/lib/pdfInvoice";

const sender: InvoiceSender = { name: "Acme Pty Ltd", abn: "12 345 678 901", gstRegistered: true };

const lineItems: InvoiceLineItemRow[] = [
  { description: "Site inspection", quantity: 1, unitPriceCents: 25000 },
  { description: "Report + drawings", quantity: 2, unitPriceCents: 40000 },
];

const invoice: InvoicePdfData = {
  number: "INV-0001",
  clientName: "Jane Roe",
  clientEmail: "jane@example.com",
  gstEnabled: true,
  gstInclusive: false,
  subtotalCents: 105000,
  gstCents: 10500,
  totalCents: 115500,
  issueDate: "2026-06-19",
  dueDate: "2026-07-03",
  amountPaidCents: 0,
};

describe("buildInvoicePdf", () => {
  it("returns a real %PDF Uint8Array that opens to >=1 page", async () => {
    const bytes = await buildInvoicePdf(invoice, lineItems, sender);
    expect(bytes[0]).toBe(0x25); // %
    expect(bytes[1]).toBe(0x50); // P
    expect(bytes[2]).toBe(0x44); // D
    expect(bytes[3]).toBe(0x46); // F
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders with GST off, no ABN, a null number, and no due date", async () => {
    const bytes = await buildInvoicePdf(
      {
        number: null,
        clientName: "Bob",
        clientEmail: null,
        gstEnabled: false,
        gstInclusive: false,
        subtotalCents: 5000,
        gstCents: 0,
        totalCents: 5000,
        issueDate: "2026-06-19",
        dueDate: null,
        amountPaidCents: 0,
      },
      [{ description: "Consult", quantity: 1, unitPriceCents: 5000 }],
      { name: "Solo Trader", abn: null, gstRegistered: false },
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });

  it("renders a GST-inclusive invoice (ex-GST subtotal + embedded GST)", async () => {
    const bytes = await buildInvoicePdf(
      { ...invoice, gstInclusive: true, subtotalCents: 95455, gstCents: 9545, totalCents: 105000 },
      lineItems,
      sender,
    );
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("renders the amount-paid / balance-due ledger on a partially-paid invoice", async () => {
    const bytes = await buildInvoicePdf({ ...invoice, amountPaidCents: 50000 }, lineItems, sender);
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThanOrEqual(1);
  });

  it("paginates a long line-item list", async () => {
    const many: InvoiceLineItemRow[] = Array.from({ length: 80 }, (_, i) => ({
      description: `Line ${i}`,
      quantity: 1,
      unitPriceCents: 1000 + i,
    }));
    const bytes = await buildInvoicePdf({ ...invoice, subtotalCents: 0, gstCents: 0, totalCents: 0 }, many, sender);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });
});
```

### Step 4.2 — Run it (red)

```
npm test -- test/pdfInvoice.test.ts
```

Expected: fails to load — `Failed to resolve import "../src/lib/pdfInvoice"`.

### Step 4.3 — Implement

CREATE `src/lib/pdfInvoice.ts`:

```ts
import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * Tax-invoice PDF (spec §4.3) — clones src/lib/pdfQuote.ts: A4 portrait, pdf-lib
 * StandardFonts (no font file), no embedded images (pure-JS, Workers-safe). Pure:
 * the route recomputes the totals (recomputeTotals) and passes them in along with
 * the derived amountPaidCents. Returns the encoded bytes (%PDF...).
 */

/** The seller block — drawn from the active Business Profile. */
export interface InvoiceSender {
  name: string;
  abn: string | null;
  gstRegistered: boolean;
}

/** One line-item row as rendered in the body table. */
export interface InvoiceLineItemRow {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

/** The invoice header/meta/totals the PDF needs (totals already recomputed). */
export interface InvoicePdfData {
  number: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  /** When true (and gstEnabled), prices include GST: subtotal is ex-GST, GST is the
   *  embedded portion, and the total equals the entered sum. */
  gstInclusive: boolean;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  /** YYYY-MM-DD issue date (the route passes the issued UTC date). */
  issueDate: string;
  dueDate: string | null;
  /** Σ non-deleted Payment.amountCents; when > 0 the paid/balance ledger renders. */
  amountPaidCents: number;
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildInvoicePdf(
  invoice: InvoicePdfData,
  lineItems: InvoiceLineItemRow[],
  sender: InvoiceSender,
): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  let page: PDFPage = doc.addPage([PAGE_W, PAGE_H]);
  let y = PAGE_H - MARGIN;

  const draw = (text: string, f: PDFFont, size: number): void => {
    if (y < BOTTOM) {
      page = doc.addPage([PAGE_W, PAGE_H]);
      y = PAGE_H - MARGIN;
    }
    page.drawText(text, { x: MARGIN, y, size, font: f, color: rgb(0.07, 0.07, 0.07) });
    y -= LINE;
  };

  // Heading — ATO "Tax invoice".
  draw("Tax invoice", bold, 18);
  y -= LINE / 2;

  // Seller (Business profile) — name + ABN + GST registration line.
  draw(sender.name, bold, 14);
  if (sender.abn) draw(`ABN: ${sender.abn}`, font, 11);
  if (sender.gstRegistered) draw("Registered for GST", font, 11);
  y -= LINE / 2;

  // Meta — number + issue/due dates.
  draw(`Invoice ${invoice.number ?? "(draft)"}`, bold, 14);
  draw(`Issue date: ${invoice.issueDate}`, font, 11);
  if (invoice.dueDate) draw(`Due date: ${invoice.dueDate}`, font, 11);
  y -= LINE / 2;

  // Bill-to.
  draw("Bill to", bold, 12);
  draw(invoice.clientName ?? "(no client)", font, 11);
  if (invoice.clientEmail) draw(invoice.clientEmail, font, 11);
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

  // Totals. Inclusive mode relabels the ledger exactly as the quote PDF does: the
  // subtotal is the ex-GST base and the GST line is the embedded portion (the total
  // equals the entered, GST-inclusive sum). Amounts are already recomputed for the mode.
  const inclusive = invoice.gstEnabled && invoice.gstInclusive;
  draw(`${inclusive ? "Subtotal (ex GST)" : "Subtotal"}: ${dollars(invoice.subtotalCents)}`, font, 12);
  if (invoice.gstEnabled) {
    draw(`GST (10%)${inclusive ? " included" : ""}: ${dollars(invoice.gstCents)}`, font, 12);
  }
  draw(`Total: ${dollars(invoice.totalCents)}`, bold, 14);
  if (inclusive) draw(`Total price includes GST ${dollars(invoice.gstCents)}.`, font, 9);

  // Accounts-receivable ledger — only when something has been paid.
  if (invoice.amountPaidCents > 0) {
    y -= LINE / 2;
    draw(`Amount paid: ${dollars(invoice.amountPaidCents)}`, font, 12);
    draw(`Balance due: ${dollars(invoice.totalCents - invoice.amountPaidCents)}`, bold, 13);
  }
  y -= LINE / 2;

  // Footer.
  draw("Please remit payment by the due date. Thank you.", font, 9);

  return doc.save();
}
```

### Step 4.4 — Run it (green)

```
npm test -- test/pdfInvoice.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  5 passed (5)`.

### Step 4.5 — Commit

```
git add src/lib/pdfInvoice.ts test/pdfInvoice.test.ts
git commit -m "$(cat <<'EOF'
feat(invoices): tax-invoice PDF builder (buildInvoicePdf)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — Schemas: invoice / invoiceLineItem / payment + SYNCABLE_TYPES

**Files**
- MODIFY `src/schemas/entities.ts`
- TEST: CREATE `test/schemas-invoices.test.ts`; MODIFY `test/schemas.test.ts` (the
  `SYNCABLE_TYPES.length` assertion changes from 15 to 18).

**Interfaces**
- Produces (Zod schemas, all extending `baseEnvelope`, all `.passthrough()` via the base):
  - `invoiceEntity` (`type: "invoice"`): `number?`, `quoteId?` (uuid, nullable+optional),
    `clientName?`, `clientEmail?`, `gstEnabled?`, `gstInclusive?`, `subtotalCents?`, `gstCents?`,
    `totalCents?`, `currency?` (len 3), `status?` (`draft|issued|void`), `issueDate?` (isoDate),
    `dueDate?` (isoDate), `issuedAt?` (epochMs), `pdfR2Key?`.
  - `invoiceLineItemEntity` (`type: "invoiceLineItem"`): `invoiceId` (uuid, required),
    `itemDescription` (min 1), `quantity?` (int ≥1), `unitPriceCents` (cents), `sortOrder?`.
  - `paymentEntity` (`type: "payment"`): `invoiceId` (uuid, required), `amountCents` (cents),
    `paidOn` (isoDate), `method?`, `note?`.
  - `SYNCABLE_TYPES` gains `"invoice"`, `"invoiceLineItem"`, `"payment"` (length → 18).
  - `SPECIALIZED` maps `invoice`/`invoiceLineItem`/`payment` to their schemas.
- Note (binding cross-plan contract): the line-item description field is **`itemDescription`**
  (not `description`) per spec §4.1's "a clone of `QuoteLineItem`" rendered with the invoice's
  own naming; the iOS plan + `syncTables.ts` (Task 6) map `itemDescription → description`. The
  quote line item used `description`; the invoice line item uses `itemDescription` consistently
  across schema + sync map + iOS. (See "Spec ambiguities resolved" at the bottom.)

### Step 5.1 — Write the failing test

CREATE `test/schemas-invoices.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  invoiceEntity,
  invoiceLineItemEntity,
  paymentEntity,
  entitySchemaFor,
  SYNCABLE_TYPES,
} from "../src/schemas/entities";

const UID = "0190f8a0-1111-7000-8000-000000000001";
const PID = "0190f8a0-2222-7000-8000-000000000002";
const EID = "0190f8a0-3333-7000-8000-000000000003";
const DID = "0190f8a0-4444-7000-8000-000000000004";
const INV = "0190f8a0-5555-7000-8000-000000000005";

function env(overrides: Record<string, unknown> = {}) {
  return {
    id: EID,
    userId: UID,
    profileId: PID,
    createdAt: 1748563200000,
    updatedAt: 1748563200000,
    deletedAt: null,
    rev: 1,
    lastEditedDeviceId: DID,
    ...overrides,
  };
}

describe("invoiceEntity", () => {
  it("accepts a full invoice payload with integer cents + dates", () => {
    const r = invoiceEntity.safeParse(
      env({
        type: "invoice",
        number: "INV-0001",
        quoteId: INV,
        clientName: "Jane Roe",
        clientEmail: "jane@example.com",
        gstEnabled: true,
        gstInclusive: false,
        subtotalCents: 105000,
        gstCents: 10500,
        totalCents: 115500,
        currency: "AUD",
        status: "issued",
        issueDate: "2026-06-19",
        dueDate: "2026-07-03",
        issuedAt: 1748563200000,
        pdfR2Key: "u/invoices/x.pdf",
      }),
    );
    expect(r.success).toBe(true);
  });

  it("accepts a draft invoice with the optional fields omitted", () => {
    const r = invoiceEntity.safeParse(env({ type: "invoice", status: "draft" }));
    expect(r.success).toBe(true);
  });

  it("rejects a bad status", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", status: "paid" })).success).toBe(false);
  });

  it("rejects a non-integer totalCents (money must be cents)", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", totalCents: 12.5 })).success).toBe(false);
  });

  it("rejects a malformed dueDate", () => {
    expect(invoiceEntity.safeParse(env({ type: "invoice", dueDate: "03/07/2026" })).success).toBe(false);
  });

  it("rejects the wrong type discriminator", () => {
    expect(invoiceEntity.safeParse(env({ type: "payment" })).success).toBe(false);
  });
});

describe("invoiceLineItemEntity", () => {
  it("accepts a line item (itemDescription + unitPriceCents)", () => {
    const r = invoiceLineItemEntity.safeParse(
      env({
        type: "invoiceLineItem",
        profileId: undefined,
        invoiceId: INV,
        itemDescription: "Site inspection",
        quantity: 1,
        unitPriceCents: 25000,
        sortOrder: 0,
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a missing invoiceId", () => {
    expect(
      invoiceLineItemEntity.safeParse(
        env({ type: "invoiceLineItem", itemDescription: "x", unitPriceCents: 1 }),
      ).success,
    ).toBe(false);
  });

  it("rejects an empty itemDescription", () => {
    expect(
      invoiceLineItemEntity.safeParse(
        env({ type: "invoiceLineItem", invoiceId: INV, itemDescription: "", unitPriceCents: 1 }),
      ).success,
    ).toBe(false);
  });
});

describe("paymentEntity", () => {
  it("accepts a payment (amountCents + paidOn + optional method/note)", () => {
    const r = paymentEntity.safeParse(
      env({
        type: "payment",
        profileId: undefined,
        invoiceId: INV,
        amountCents: 50000,
        paidOn: "2026-06-20",
        method: "bank transfer",
        note: "deposit",
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer amountCents", () => {
    expect(
      paymentEntity.safeParse(env({ type: "payment", invoiceId: INV, amountCents: 1.5, paidOn: "2026-06-20" }))
        .success,
    ).toBe(false);
  });

  it("rejects a malformed paidOn", () => {
    expect(
      paymentEntity.safeParse(env({ type: "payment", invoiceId: INV, amountCents: 1, paidOn: "20-06-2026" }))
        .success,
    ).toBe(false);
  });
});

describe("entitySchemaFor / SYNCABLE_TYPES (invoices)", () => {
  it("exposes the three new syncable types", () => {
    expect(SYNCABLE_TYPES).toContain("invoice");
    expect(SYNCABLE_TYPES).toContain("invoiceLineItem");
    expect(SYNCABLE_TYPES).toContain("payment");
    expect(SYNCABLE_TYPES.length).toBe(18);
  });

  it("returns the specialized invoice schemas", () => {
    expect(entitySchemaFor("invoice")).toBe(invoiceEntity);
    expect(entitySchemaFor("invoiceLineItem")).toBe(invoiceLineItemEntity);
    expect(entitySchemaFor("payment")).toBe(paymentEntity);
  });
});
```

### Step 5.2 — Run it (red)

```
npm test -- test/schemas-invoices.test.ts
```

Expected: fails to load — `entities.ts` does not export `invoiceEntity` /
`invoiceLineItemEntity` / `paymentEntity` (import error / `undefined` is not a Zod schema).

### Step 5.3 — Implement

In `src/schemas/entities.ts`, add the three schemas after `vehicleYearEntity` (before
`SYNCABLE_TYPES`). Insert exactly:

```ts
/** invoice — issued tax invoice (spec §4.1). Money in cents, dates date-only. */
export const invoiceEntity = baseEnvelope.extend({
  type: z.literal("invoice"),
  number: z.string().nullable().optional(),
  quoteId: uuid.nullable().optional(),
  clientName: z.string().nullable().optional(),
  clientEmail: z.string().nullable().optional(),
  gstEnabled: z.boolean().optional(),
  gstInclusive: z.boolean().optional(),
  subtotalCents: cents.optional(),
  gstCents: cents.optional(),
  totalCents: cents.optional(),
  currency: z.string().length(3).optional(),
  status: z.enum(["draft", "issued", "void"]).optional(),
  issueDate: isoDate.nullable().optional(),
  dueDate: isoDate.nullable().optional(),
  issuedAt: epochMs.nullable().optional(),
  pdfR2Key: z.string().nullable().optional(),
});

/** invoiceLineItem — child of an invoice; a clone of quoteLineItem (profileId nil). */
export const invoiceLineItemEntity = baseEnvelope.extend({
  type: z.literal("invoiceLineItem"),
  invoiceId: uuid,
  itemDescription: z.string().min(1),
  quantity: z.number().int().min(1).optional(),
  unitPriceCents: cents,
  sortOrder: z.number().int().optional(),
});

/** payment — one A/R payment record against an invoice (spec §4.1). */
export const paymentEntity = baseEnvelope.extend({
  type: z.literal("payment"),
  invoiceId: uuid,
  amountCents: cents,
  paidOn: isoDate,
  method: z.string().nullable().optional(),
  note: z.string().nullable().optional(),
});
```

Then add the three types to `SYNCABLE_TYPES` (append after `"vehicleYear"`):

```ts
  "vehicle",
  "vehicleYear",
  "invoice",
  "invoiceLineItem",
  "payment",
] as const;
```

And register them in `SPECIALIZED`:

```ts
const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
  vehicle: vehicleEntity,
  vehicleYear: vehicleYearEntity,
  invoice: invoiceEntity,
  invoiceLineItem: invoiceLineItemEntity,
  payment: paymentEntity,
};
```

In `test/schemas.test.ts`, update the count assertion (the only edit). Change:

```ts
    expect(SYNCABLE_TYPES.length).toBe(15);
```

to:

```ts
    expect(SYNCABLE_TYPES.length).toBe(18);
```

### Step 5.4 — Run it (green)

```
npm test -- test/schemas-invoices.test.ts test/schemas.test.ts
```

Expected: both files pass — `Test Files  2 passed (2)`; the new file's 15 assertions and the
updated `schemas.test.ts` count assertion are green.

### Step 5.5 — Commit

```
git add src/schemas/entities.ts test/schemas-invoices.test.ts test/schemas.test.ts
git commit -m "$(cat <<'EOF'
feat(sync): invoice / invoiceLineItem / payment Zod schemas + SYNCABLE_TYPES

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Sync wiring: syncTables maps for the 3 new entities

**Files**
- MODIFY `src/lib/syncTables.ts`
- TEST: CREATE `test/sync-invoices.test.ts`

**Interfaces**
- Produces (table/column maps consumed by the generic `/sync` push + pull):
  - `SYNCABLE_TABLES.invoice` → table `invoices`, `hasProfileId: true`, columns: `number→number`,
    `quoteId→quote_id`, `clientName→client_name`, `clientEmail→client_email`,
    `gstEnabled→gst_enabled`, `gstInclusive→gst_inclusive`, `subtotalCents→subtotal_cents`,
    `gstCents→gst_cents`, `totalCents→total_cents`, `currency→currency`, `status→status`,
    `issueDate→issue_date`, `dueDate→due_date`, `issuedAt→issued_at`, `pdfR2Key→pdf_r2_key`.
    (`line_total_cents` is generated and intentionally omitted; route-only fields are written by
    the issue route, not the sync push — but they are still pullable, so they appear in the
    column map so a pulled invoice carries them.)
  - `SYNCABLE_TABLES.invoiceLineItem` → table `invoice_line_items`, `hasProfileId: false`,
    columns: `invoiceId→invoice_id`, `itemDescription→description`, `quantity→quantity`,
    `unitPriceCents→unit_price_cents`, `sortOrder→sort_order`.
  - `SYNCABLE_TABLES.payment` → table `payments`, `hasProfileId: false`, columns:
    `invoiceId→invoice_id`, `amountCents→amount_cents`, `paidOn→paid_on`, `method→method`,
    `note→note`.
  - `PROFILE_ID_REQUIRED` gains `"invoice"` (its `profile_id` is NOT NULL).
- Round-trip contract: a push of `{type:"invoice"}` upserts into `invoices` and a subsequent
  `/sync/pull` echoes the camelCase envelope (incl. `profileId`). A payment/line-item push
  round-trips with `profileId` omitted.

### Step 6.1 — Write the failing test

CREATE `test/sync-invoices.test.ts`:

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM payments");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM processed_mutations");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

async function seedAuthed() {
  const userId = uuidv7();
  const deviceId = uuidv7();
  const profileId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, profileId, accessToken };
}

function push(accessToken: string, deviceId: string, mutations: unknown[]) {
  return SELF.fetch(`${BASE}/sync/push`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ deviceId, mutations }),
  });
}

function pull(accessToken: string) {
  return SELF.fetch(`${BASE}/sync/pull?limit=500`, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
}

describe("sync round-trip — invoice / invoiceLineItem / payment", () => {
  it("upserts + pulls an invoice (profile-scoped) with its camelCase envelope", async () => {
    const { userId, deviceId, profileId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const now = nowMs();
    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoice",
        entityId: invoiceId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: invoiceId,
          userId,
          profileId,
          type: "invoice",
          quoteId: null,
          clientName: "Jane Roe",
          clientEmail: "jane@example.com",
          gstEnabled: true,
          gstInclusive: false,
          subtotalCents: 105000,
          gstCents: 10500,
          totalCents: 115500,
          currency: "AUD",
          status: "draft",
          dueDate: "2026-07-03",
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results[0].status).toBe("applied");

    // Persisted in D1 with snake_case columns.
    const row = await env.DB.prepare(
      `SELECT profile_id, client_name, total_cents, status, due_date FROM invoices WHERE id=?`,
    ).bind(invoiceId).first<any>();
    expect(row.profile_id).toBe(profileId);
    expect(row.client_name).toBe("Jane Roe");
    expect(row.total_cents).toBe(115500);
    expect(row.status).toBe("draft");
    expect(row.due_date).toBe("2026-07-03");

    // Pull echoes the camelCase envelope.
    const pulled = (await (await pull(accessToken)).json()) as any;
    const inv = pulled.changes.find((ch: any) => ch.type === "invoice" && ch.id === invoiceId);
    expect(inv).toBeTruthy();
    expect(inv.profileId).toBe(profileId);
    expect(inv.clientName).toBe("Jane Roe");
    expect(inv.totalCents).toBe(115500);
    expect(inv.gstEnabled).toBe(1); // booleans persist as 0/1
  });

  it("upserts an invoiceLineItem (itemDescription -> description) and a payment", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const liId = uuidv7();
    const payId = uuidv7();
    const now = nowMs();
    // Seed a parent invoice row directly so the FK on the children is satisfied.
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,status,created_at,updated_at)
       VALUES (?,?,(SELECT id FROM profiles WHERE user_id=?),'draft',?,?)`,
    ).bind(invoiceId, userId, userId, now, now).run();

    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoiceLineItem",
        entityId: liId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: liId,
          userId,
          type: "invoiceLineItem",
          invoiceId,
          itemDescription: "Site inspection",
          quantity: 1,
          unitPriceCents: 25000,
          sortOrder: 0,
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
      {
        mutationId: uuidv7(),
        entityType: "payment",
        entityId: payId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: payId,
          userId,
          type: "payment",
          invoiceId,
          amountCents: 50000,
          paidOn: "2026-06-20",
          method: "bank transfer",
          note: "deposit",
          createdAt: now,
          updatedAt: now,
          deletedAt: null,
          rev: 0,
          lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results.every((r: any) => r.status === "applied")).toBe(true);

    // Line item: itemDescription mapped to the description column; line_total generated.
    const li = await env.DB.prepare(
      `SELECT description, unit_price_cents, line_total_cents FROM invoice_line_items WHERE id=?`,
    ).bind(liId).first<any>();
    expect(li.description).toBe("Site inspection");
    expect(li.unit_price_cents).toBe(25000);
    expect(li.line_total_cents).toBe(25000);

    // Payment persisted.
    const pay = await env.DB.prepare(
      `SELECT amount_cents, paid_on, method FROM payments WHERE id=?`,
    ).bind(payId).first<any>();
    expect(pay.amount_cents).toBe(50000);
    expect(pay.paid_on).toBe("2026-06-20");
    expect(pay.method).toBe("bank transfer");

    // Pull echoes itemDescription back (column -> camelCase via the map).
    const pulled = (await (await pull(accessToken)).json()) as any;
    const liPulled = pulled.changes.find((ch: any) => ch.type === "invoiceLineItem" && ch.id === liId);
    expect(liPulled.itemDescription).toBe("Site inspection");
    const payPulled = pulled.changes.find((ch: any) => ch.type === "payment" && ch.id === payId);
    expect(payPulled.paidOn).toBe("2026-06-20");
  });

  it("rejects an invoice upsert that omits the required profileId", async () => {
    const { userId, deviceId, accessToken } = await seedAuthed();
    const invoiceId = uuidv7();
    const now = nowMs();
    const res = await push(accessToken, deviceId, [
      {
        mutationId: uuidv7(),
        entityType: "invoice",
        entityId: invoiceId,
        op: "upsert",
        baseRev: 0,
        updatedAt: now,
        payload: {
          id: invoiceId, userId, type: "invoice", status: "draft",
          createdAt: now, updatedAt: now, deletedAt: null, rev: 0, lastEditedDeviceId: null,
        },
      },
    ]);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.results[0].status).toBe("rejected");
    expect(body.results[0].reason).toBe("VALIDATION_FAILED");
  });
});
```

### Step 6.2 — Run it (red)

```
npm test -- test/sync-invoices.test.ts
```

Expected: failures — pushes of `invoice`/`invoiceLineItem`/`payment` are `rejected`
(`VALIDATION_FAILED`) because `tableForEntityType` returns `null` for the unknown entity types,
so the "applied" / persisted-row assertions fail.

### Step 6.3 — Implement

In `src/lib/syncTables.ts`, add the three table maps inside `SYNCABLE_TABLES` (place after the
`quoteLineItem` entry, before `mileageTrip`):

```ts
  invoice: {
    table: "invoices",
    hasProfileId: true,
    columns: {
      number: "number",
      quoteId: "quote_id",
      clientName: "client_name",
      clientEmail: "client_email",
      gstEnabled: "gst_enabled",
      gstInclusive: "gst_inclusive",
      subtotalCents: "subtotal_cents",
      gstCents: "gst_cents",
      totalCents: "total_cents",
      currency: "currency",
      status: "status",
      issueDate: "issue_date",
      dueDate: "due_date",
      issuedAt: "issued_at",
      pdfR2Key: "pdf_r2_key",
    },
  },
  invoiceLineItem: {
    table: "invoice_line_items",
    hasProfileId: false,
    columns: {
      invoiceId: "invoice_id",
      itemDescription: "description",
      quantity: "quantity",
      unitPriceCents: "unit_price_cents",
      sortOrder: "sort_order",
    },
  },
  payment: {
    table: "payments",
    hasProfileId: false,
    columns: {
      invoiceId: "invoice_id",
      amountCents: "amount_cents",
      paidOn: "paid_on",
      method: "method",
      note: "note",
    },
  },
```

Add `"invoice"` to `PROFILE_ID_REQUIRED` (its `profile_id` is NOT NULL; line items + payments
have no `profile_id`, so they are intentionally absent):

```ts
export const PROFILE_ID_REQUIRED: ReadonlySet<string> = new Set([
  "transaction",
  "budget",
  "mileageTrip",
  "wfhLog",
  "vehicle",
  "vehicleYear",
  "quote",
  "invoice",
  "taxSettings",
]);
```

### Step 6.4 — Run it (green)

```
npm test -- test/sync-invoices.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  3 passed (3)`.

### Step 6.5 — Commit

```
git add src/lib/syncTables.ts test/sync-invoices.test.ts
git commit -m "$(cat <<'EOF'
feat(sync): syncTables maps for invoice / invoiceLineItem / payment + profile_id guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — POST /quotes/:id/pdf — build/store quote PDF, persist key, mint number, no status change

**Files**
- MODIFY `src/routes/quotes.ts`
- TEST: CREATE `test/quotes-pdf.test.ts`

**Interfaces**
- Route (binding cross-plan contract; iOS calls this):
  - Request: `POST /quotes/:id/pdf`, bearer auth, body `{}` (no body fields read).
  - Response 200 JSON:
    ```json
    { "number": "SN-0001", "status": "draft", "subtotalCents": 105000,
      "gstCents": 10500, "totalCents": 115500, "pdfUrl": "https://.../quotes/dl/<token>",
      "expiresAt": 1751000000000 }
    ```
  - 400 `VALIDATION_FAILED` if the quote has no non-deleted line items.
  - 404 `NOT_FOUND` if the quote is unknown or owned by another user.
  - Side effects: mints `quotes.number` (via `assignQuoteNumber`) **only if absent**; recomputes
    + persists `subtotal_cents`/`gst_cents`/`total_cents`; writes the PDF to R2 at
    `${userId}/quotes/${quoteId}.pdf`; persists `quotes.pdf_r2_key`; **does NOT change `status`,
    does NOT set `sent_at`, does NOT write `email_outbox`, does NOT email**.
- Consumes: `recomputeTotals`, `assignQuoteNumber`, `buildQuotePdf`, `signDownloadToken`,
  `DOWNLOAD_TTL_SECONDS` (all already imported in `quotes.ts`).

### Step 7.1 — Write the failing test

CREATE `test/quotes-pdf.test.ts`:

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
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

async function seedQuote(userId: string) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'Jane','jane@example.com',1,0,'draft','2026-06-30',?,?)`,
  ).bind(quoteId, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

function genPdf(quoteId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/quotes/${quoteId}/pdf`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /quotes/:id/pdf", () => {
  it("mints SN-0001, persists totals + pdf_r2_key, leaves status=draft, does NOT email", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.number).toBe("SN-0001");
    expect(body.status).toBe("draft");
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/quotes/dl/");
    expect(typeof body.expiresAt).toBe("number");

    // Persisted: number + totals + pdf_r2_key set; status STILL draft; sent_at null.
    const row = await env.DB.prepare(
      `SELECT number, status, sent_at, total_cents, pdf_r2_key FROM quotes WHERE id=?`,
    ).bind(quoteId).first<any>();
    expect(row.number).toBe("SN-0001");
    expect(row.status).toBe("draft");
    expect(row.sent_at).toBeNull();
    expect(row.total_cents).toBe(115500);
    expect(row.pdf_r2_key).toBe(`${userId}/quotes/${quoteId}.pdf`);

    // No email, no outbox row.
    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);

    // The PDF is downloadable via the signed token.
    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const token = body.pdfUrl.slice(body.pdfUrl.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toBe(`${userId}/quotes/${quoteId}.pdf`);
  });

  it("does NOT re-mint a number on a second PDF build (keeps SN-0001), refreshes pdf_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const first = (await (await genPdf(quoteId, accessToken)).json()) as any;
    expect(first.number).toBe("SN-0001");
    const second = (await (await genPdf(quoteId, accessToken)).json()) as any;
    expect(second.number).toBe("SN-0001");

    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1); // advanced only once
  });

  it("400 VALIDATION_FAILED when the quote has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,client_name,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'Jane',1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();

    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("404 NOT_FOUND for an unknown quote", async () => {
    const { accessToken } = await seedAuthed();
    const res = await genPdf(uuidv7(), accessToken);
    expect(res.status).toBe(404);
  });

  it("404 NOT_FOUND for a quote owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await genPdf(quoteId, accessToken);
    expect(res.status).toBe(404);
  });
});
```

### Step 7.2 — Run it (red)

```
npm test -- test/quotes-pdf.test.ts
```

Expected: failures — `POST /quotes/:id/pdf` is not registered, so the route returns 404 for the
happy path (and the body/persistence assertions fail). (Hono falls through to a 404 for an
unmatched method+path under the mounted `/quotes` router.)

### Step 7.3 — Implement

In `src/routes/quotes.ts`, add the new route handler **above** the existing
`quotesRoutes.post("/:id/send", …)` (so the `:id/pdf` and `:id/send` patterns are both
registered on the same router; order between distinct paths does not matter). Insert:

```ts
quotesRoutes.post("/:id/pdf", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive, valid_until
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
    throw new ApiError("VALIDATION_FAILED", "Cannot build a PDF for a quote with no line items");
  }

  // 3. Recompute totals authoritatively.
  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );

  // 4. Mint SN-#### only if the quote has none yet (so the PDF shows a real number).
  //    A re-build keeps the existing number — generating a PDF never changes status (§2.1).
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

  // 6. Build the PDF -> R2 (same key as the send path; a re-build overwrites it).
  const now = nowMs();
  const pdf = await buildQuotePdf(
    {
      number,
      clientName: quote.client_name,
      clientEmail: quote.client_email,
      gstEnabled,
      gstInclusive,
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

  // 7. Persist number + totals + pdf_r2_key. NO status change, NO sent_at (§2.1).
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, pdf_r2_key = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 8. Signed 7-day download link.
  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/quotes/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // 9. Response — status stays draft (no email, no outbox).
  return c.json({
    number,
    status: "draft",
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
  });
});
```

### Step 7.4 — Run it (green)

```
npm test -- test/quotes-pdf.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  5 passed (5)`. Re-run the existing quotes-send
suite to confirm no regression:

```
npm test -- test/quotes-send.test.ts
```

Expected: still green (`12 passed` per the existing file's count).

### Step 7.5 — Commit

```
git add src/routes/quotes.ts test/quotes-pdf.test.ts
git commit -m "$(cat <<'EOF'
feat(quotes): POST /quotes/:id/pdf — build+persist PDF, mint number, no status change

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — POST /invoices/:id/issue + GET /invoices/dl/:token

**Files**
- CREATE `src/routes/invoices.ts` (issue + dl; send + pdf are appended in Task 9)
- MODIFY `src/app.ts` (mount `invoicesRoutes` + rate tier)
- MODIFY `src/middleware/auth.ts` (`/invoices/dl/` in `PUBLIC_PATHS`)
- TEST: CREATE `test/invoices-issue.test.ts`

> Task 8 wires the mount + public path here so the issue/dl routes are reachable; Task 9 appends
> the send + pdf handlers onto the same `invoicesRoutes` router (no further app.ts change).

**Interfaces**
- Route (binding cross-plan contract; iOS calls this):
  - Request: `POST /invoices/:id/issue`, bearer auth, body `{}`.
  - Response 200 JSON:
    ```json
    { "number": "INV-0001", "status": "issued", "issueDate": "2026-06-19",
      "issuedAt": 1750291200000, "subtotalCents": 105000, "gstCents": 10500,
      "totalCents": 115500, "pdfUrl": "https://.../invoices/dl/<token>", "expiresAt": 1751000000000 }
    ```
  - 400 `VALIDATION_FAILED` if the invoice has no non-deleted line items.
  - 404 `NOT_FOUND` if unknown / other-user / profile missing.
  - Side effects: mints `invoices.number` via `assignInvoiceNumber(profile_id)` **only if absent**;
    sets `status='issued'`, `issue_date=utcDate(now)`, `issued_at=now` (only when not already
    issued — `due_date` is left as whatever the draft synced); recomputes + persists totals;
    writes the tax-invoice PDF to `${userId}/invoices/${invoiceId}.pdf`; persists `pdf_r2_key`.
    A re-issue keeps the existing number/issue_date/issued_at and refreshes the PDF + totals.
  - Public download: `GET /invoices/dl/:token` verifies the signed token and streams the R2 PDF
    (mirror `quotes/dl`); 403 on a bad/expired token, 404 if the object is missing.

### Step 8.1 — Write the failing test

CREATE `test/invoices-issue.test.ts`:

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken, signDownloadToken } from "../src/lib/exportToken";

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
  await env.DB.exec("DELETE FROM payments");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM invoice_counters");
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
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken };
}

async function seedInvoice(userId: string, opts: { gstInclusive?: boolean } = {}) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,status,due_date,created_at,updated_at)
     VALUES (?,?,?,'Jane','jane@example.com',1,?, 'draft','2026-07-03',?,?)`,
  ).bind(invoiceId, userId, profileId, opts.gstInclusive ? 1 : 0, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return { profileId, invoiceId };
}

function issue(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/issue`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /invoices/:id/issue", () => {
  it("mints INV-0001, recomputes totals, sets issued + dates + pdf_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await issue(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.number).toBe("INV-0001");
    expect(body.status).toBe("issued");
    expect(body.subtotalCents).toBe(105000);
    expect(body.gstCents).toBe(10500);
    expect(body.totalCents).toBe(115500);
    expect(typeof body.issueDate).toBe("string");
    expect(typeof body.issuedAt).toBe("number");
    expect(body.pdfUrl).toContain("/invoices/dl/");

    const row = await env.DB.prepare(
      `SELECT number, status, issue_date, issued_at, total_cents, pdf_r2_key FROM invoices WHERE id=?`,
    ).bind(invoiceId).first<any>();
    expect(row.number).toBe("INV-0001");
    expect(row.status).toBe("issued");
    expect(row.issue_date).not.toBeNull();
    expect(row.issued_at).not.toBeNull();
    expect(row.total_cents).toBe(115500);
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);

    // PDF downloadable.
    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const token = body.pdfUrl.slice(body.pdfUrl.lastIndexOf("/") + 1);
    expect((await verifyDownloadToken(env.JWT_SIGNING_KEY, token)).r2Key)
      .toBe(`${userId}/invoices/${invoiceId}.pdf`);
  });

  it("recomputes GST-INCLUSIVE totals (total == entered sum)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { gstInclusive: true });
    const body = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(body.totalCents).toBe(105000);
    expect(body.gstCents).toBe(9545);
    expect(body.subtotalCents).toBe(95455);
  });

  it("is IDEMPOTENT: a re-issue keeps INV-0001 + the original issued_at (no new mint)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const first = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(first.number).toBe("INV-0001");
    const firstIssuedAt = (await env.DB.prepare(`SELECT issued_at FROM invoices WHERE id=?`)
      .bind(invoiceId).first<{ issued_at: number }>())!.issued_at;

    const second = (await (await issue(invoiceId, accessToken)).json()) as any;
    expect(second.number).toBe("INV-0001");

    const ctr = await env.DB.prepare(`SELECT next_seq FROM invoice_counters WHERE profile_id=(SELECT profile_id FROM invoices WHERE id=?)`)
      .bind(invoiceId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1); // advanced only once
    const afterIssuedAt = (await env.DB.prepare(`SELECT issued_at FROM invoices WHERE id=?`)
      .bind(invoiceId).first<{ issued_at: number }>())!.issued_at;
    expect(afterIssuedAt).toBe(firstIssuedAt); // unchanged
  });

  it("downstream issues for the same PROFILE get INV-0002", async () => {
    const { userId, accessToken } = await seedAuthed();
    // Two invoices under the SAME profile.
    const profileId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    const mk = async () => {
      const id = uuidv7();
      await env.DB.prepare(
        `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
         VALUES (?,?,?,1,'draft',?,?)`,
      ).bind(id, userId, profileId, now, now).run();
      await env.DB.prepare(
        `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
         VALUES (?,?,?,'X',1,1000,0,?,?)`,
      ).bind(uuidv7(), userId, id, now, now).run();
      return id;
    };
    const a = await mk();
    const b = await mk();
    expect(((await (await issue(a, accessToken)).json()) as any).number).toBe("INV-0001");
    expect(((await (await issue(b, accessToken)).json()) as any).number).toBe("INV-0002");
  });

  it("400 VALIDATION_FAILED when the invoice has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,1,'draft',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    const res = await issue(invoiceId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("404 NOT_FOUND for an unknown invoice", async () => {
    const { accessToken } = await seedAuthed();
    expect((await issue(uuidv7(), accessToken)).status).toBe(404);
  });

  it("404 NOT_FOUND for another user's invoice", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { invoiceId } = await seedInvoice(other.userId);
    expect((await issue(invoiceId, accessToken)).status).toBe(404);
  });
});

describe("GET /invoices/dl/:token", () => {
  it("streams the invoice PDF for a valid token (public, no auth)", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);
    const issued = (await (await issue(invoiceId, accessToken)).json()) as any;

    const dl = await SELF.fetch(issued.pdfUrl); // no auth header
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %
  });

  it("returns 403 for a forged token", async () => {
    expect((await SELF.fetch(`${BASE}/invoices/dl/not.a.valid.token`)).status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/invoices/y.pdf", -10);
    expect((await SELF.fetch(`${BASE}/invoices/dl/${token}`)).status).toBe(403);
  });
});
```

### Step 8.2 — Run it (red)

```
npm test -- test/invoices-issue.test.ts
```

Expected: failures — `/invoices/*` is not mounted (404 for issue; the public `dl` returns 401,
not 403, because `/invoices/dl/` is not yet in `PUBLIC_PATHS` and the router does not exist).

### Step 8.3 — Implement

CREATE `src/routes/invoices.ts`:

```ts
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignInvoiceNumber } from "../lib/invoiceCounter";
import { buildInvoicePdf, type InvoiceLineItemRow, type InvoiceSender } from "../lib/pdfInvoice";
import { amountPaidCents } from "../lib/invoiceTotals";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";

/**
 * POST /invoices/:id/issue  — Bearer (global auth) + rate tier "quotes" (app.ts).
 * GET  /invoices/dl/:token  — PUBLIC (in PUBLIC_PATHS); streams the signed R2 PDF.
 *
 * Invoice/line-item/payment CRUD stays on /sync; only issue/send/pdf/dl live here.
 * (POST /invoices/:id/send and POST /invoices/:id/pdf are appended onto this router.)
 */
export const invoicesRoutes = new Hono<AppEnv>();

interface InvoiceRow {
  id: string;
  user_id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  gst_enabled: number;
  gst_inclusive: number;
  status: string;
  issue_date: string | null;
  due_date: string | null;
  issued_at: number | null;
  pdf_r2_key: string | null;
}

interface InvoiceLineRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** UTC YYYY-MM-DD for an epoch-ms instant. */
function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/** Shared loader: invoice + its non-deleted line items + the owning profile/sender. */
async function loadInvoiceForPdf(
  c: Parameters<Parameters<typeof invoicesRoutes.post>[1]>[0],
  invoiceId: string,
  userId: string,
): Promise<{
  invoice: InvoiceRow;
  lineItems: InvoiceLineRow[];
  sender: InvoiceSender;
}> {
  const invoice = await c.env.DB.prepare(
    `SELECT id, user_id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive,
            status, issue_date, due_date, issued_at, pdf_r2_key
       FROM invoices WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoiceId, userId).first<InvoiceRow>();
  if (!invoice) throw new ApiError("NOT_FOUND", "Invoice not found for this user");

  const { results: lineItems } = await c.env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM invoice_line_items
      WHERE invoice_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(invoiceId, userId).all<InvoiceLineRow>();
  if (lineItems.length === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot build a PDF for an invoice with no line items");
  }

  const profile = await c.env.DB.prepare(
    `SELECT name, abn, gst_registered FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoice.profile_id, userId).first<{ name: string; abn: string | null; gst_registered: number | null }>();
  if (!profile) throw new ApiError("NOT_FOUND", "Profile not found for this invoice");

  return {
    invoice,
    lineItems,
    sender: { name: profile.name, abn: profile.abn, gstRegistered: profile.gst_registered === 1 },
  };
}

/** Σ non-deleted payment amounts for the invoice (derived, never stored). */
async function invoiceAmountPaidCents(
  db: D1Database,
  invoiceId: string,
  userId: string,
): Promise<number> {
  const { results } = await db.prepare(
    `SELECT amount_cents FROM payments WHERE invoice_id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(invoiceId, userId).all<{ amount_cents: number }>();
  return amountPaidCents(results.map((p) => ({ amountCents: p.amount_cents })));
}

invoicesRoutes.post("/:id/issue", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");

  const { invoice, lineItems, sender } = await loadInvoiceForPdf(c, invoiceId, userId);

  // Recompute totals authoritatively.
  const gstEnabled = invoice.gst_enabled === 1;
  const gstInclusive = invoice.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );

  // Mint INV-#### per PROFILE only on the FIRST issue; a re-issue keeps the number,
  // issue_date, and issued_at (idempotent). status flips to issued either way.
  const now = nowMs();
  const number = invoice.number ?? (await assignInvoiceNumber(c.env.DB, invoice.profile_id));
  const issueDate = invoice.issue_date ?? utcDate(now);
  const issuedAt = invoice.issued_at ?? now;

  // Build the tax-invoice PDF (incl. the derived amount-paid ledger) -> R2.
  const paidCents = await invoiceAmountPaidCents(c.env.DB, invoiceId, userId);
  const pdf = await buildInvoicePdf(
    {
      number,
      clientName: invoice.client_name,
      clientEmail: invoice.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      issueDate,
      dueDate: invoice.due_date,
      amountPaidCents: paidCents,
    },
    lineItems.map((li): InvoiceLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/invoices/${invoiceId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });

  // Persist: number, status=issued, dates, totals, pdf_r2_key.
  await c.env.DB.prepare(
    `UPDATE invoices
        SET number = ?, status = 'issued', issue_date = ?, issued_at = ?, pdf_r2_key = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?, updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, issueDate, issuedAt, key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, invoiceId, userId).run();

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  return c.json({
    number,
    status: "issued",
    issueDate,
    issuedAt,
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    pdfUrl,
    expiresAt,
  });
});

// PUBLIC: GET /invoices/dl/:token — verify the signed token + stream the R2 PDF.
invoicesRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Invoice PDF not found");

  // Buffer fully (mirrors quotes/dl) so the R2 read completes before the response
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

In `src/middleware/auth.ts`, add `/invoices/dl/` to `PUBLIC_PATHS`:

```ts
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/quotes/dl/", "/invoices/dl/", "/appstore/"];
```

In `src/app.ts`, import the router (after the `quotesRoutes` import):

```ts
import { quotesRoutes } from "./routes/quotes";
import { invoicesRoutes } from "./routes/invoices";
```

Add the rate-tier mount (after the `/quotes` + `/quotes/*` rateLimit block, reusing the `quotes`
tier — PDF build + email, 60/hr; the wildcard also IP-limits the public `dl`):

```ts
// Invoice issue/send/pdf — PDF build + email; reuse the "quotes" tier (60/hr).
// Mount on BOTH the exact path AND the wildcard so the limiter runs for the POSTs;
// the wildcard also IP-limits the public GET /invoices/dl/* download.
app.use("/invoices", rateLimit("quotes"));
app.use("/invoices/*", rateLimit("quotes"));
```

Mount the router (after the `app.route("/quotes", quotesRoutes);` line):

```ts
// Protected: POST /invoices/:id/issue|send|pdf (+ public GET /invoices/dl/:token via PUBLIC_PATHS).
app.route("/invoices", invoicesRoutes);
```

### Step 8.4 — Run it (green)

```
npm test -- test/invoices-issue.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  10 passed (10)`.

### Step 8.5 — Commit

```
git add src/routes/invoices.ts src/middleware/auth.ts src/app.ts test/invoices-issue.test.ts
git commit -m "$(cat <<'EOF'
feat(invoices): POST /invoices/:id/issue + public GET /invoices/dl/:token (mount + PUBLIC_PATHS)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9 — POST /invoices/:id/send + POST /invoices/:id/pdf + sendInvoiceEmail seam

**Files**
- MODIFY `src/lib/email.ts` (add `sendInvoiceEmail` seam)
- MODIFY `src/routes/invoices.ts` (append `POST /:id/send` and `POST /:id/pdf`)
- TEST: CREATE `test/invoices-send-pdf.test.ts`

**Interfaces**
- Email seam (mirrors `sendQuoteEmail`):
  - `export interface InvoiceEmail { to: string; replyTo: string; invoiceNumber: string;
    clientName: string | null; totalCents: number; pdf: Uint8Array; }`
  - `export async function sendInvoiceEmail(env: Env, msg: InvoiceEmail): Promise<void>` —
    mimetext/browser MIME, base64 PDF attachment, `cloudflare:email` EmailMessage + `env.EMAIL.send`.
    Spy-able in tests via `vi.spyOn(emailModule, "sendInvoiceEmail")`.
- Route `POST /invoices/:id/send` (binding cross-plan contract; iOS calls this):
  - Request: bearer auth, body `{}`.
  - 400 `VALIDATION_FAILED` if no line items OR no client email (precondition fires BEFORE any
    mutation — mirrors the quote send: no PDF rebuild, no outbox row).
  - 404 `NOT_FOUND` if unknown / other-user / profile missing.
  - 200 JSON: `{ "status": <invoice.status>, "totalCents": <n>, "pdfUrl": "...", "expiresAt": <n>, "emailed": <bool> }`.
  - Side effects: rebuilds the PDF → R2 (ensures a current PDF), persists `pdf_r2_key`, writes an
    `email_outbox` row (`kind='invoice_send'`, `related_id=invoiceId`, `export_format='pdf'`),
    attempts `sendInvoiceEmail` inside try/catch (outbox → `sent`/`failed`, route still 200s).
    Send does NOT mint a number or flip status — issuing is separate; send works on draft or
    issued invoices (sends whatever the current state renders). `replyTo` = the trader's `users.email`.
- Route `POST /invoices/:id/pdf` (binding cross-plan contract; iOS calls this):
  - Request: bearer auth, body `{}`. 400/404 as above (no email-precondition).
  - 200 JSON: `{ "status": <invoice.status>, "totalCents": <n>, "pdfUrl": "...", "expiresAt": <n> }`.
  - Side effects: (re)builds the PDF → R2, persists `pdf_r2_key` + recomputed totals; NO status
    change, NO email.

### Step 9.1 — Write the failing test

CREATE `test/invoices-send-pdf.test.ts`:

```ts
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

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
  await env.DB.exec("DELETE FROM payments");
  await env.DB.exec("DELETE FROM invoice_line_items");
  await env.DB.exec("DELETE FROM invoices");
  await env.DB.exec("DELETE FROM invoice_counters");
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
    `INSERT INTO users (id, email, email_verified, plan, created_at, updated_at)
     VALUES (?, ?, 1, 'free', ?, ?)`,
  ).bind(userId, `${userId}@example.com`, now, now).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', 1, ?, ?)`,
  ).bind(deviceId, userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, deviceId, accessToken, email: `${userId}@example.com` };
}

async function seedInvoice(userId: string, opts: { clientEmail?: string | null; status?: string } = {}) {
  const profileId = uuidv7();
  const invoiceId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','12 345 678 901',1,'#1','#2','#3',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoices (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,status,due_date,created_at,updated_at)
     VALUES (?,?,?,'INV-0001','Jane',?,1,0,?, '2026-07-03',?,?)`,
  ).bind(invoiceId, userId, profileId,
    opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail,
    opts.status ?? "issued", now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Inspection',1,25000,0,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO invoice_line_items (id,user_id,invoice_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Report',2,40000,1,?,?)`,
  ).bind(uuidv7(), userId, invoiceId, now, now).run();
  return { profileId, invoiceId };
}

function send(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/send`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

function pdf(invoiceId: string, accessToken: string) {
  return SELF.fetch(`${BASE}/invoices/${invoiceId}/pdf`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: "{}",
  });
}

describe("POST /invoices/:id/send", () => {
  it("emails the client (spied), writes an invoice_send outbox row, returns emailed:true", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(true);
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/invoices/dl/");

    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1] as emailModule.InvoiceEmail;
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe(email);
    expect(arg.invoiceNumber).toBe("INV-0001");
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    const outbox = await env.DB.prepare(
      `SELECT kind, status, to_email, related_id, export_format FROM email_outbox WHERE related_id=?`,
    ).bind(invoiceId).first<any>();
    expect(outbox.kind).toBe("invoice_send");
    expect(outbox.status).toBe("sent");
    expect(outbox.to_email).toBe("jane@example.com");
    expect(outbox.export_format).toBe("pdf");

    // pdf_r2_key persisted.
    const row = await env.DB.prepare(`SELECT pdf_r2_key FROM invoices WHERE id=?`).bind(invoiceId).first<any>();
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);
  });

  it("when the send THROWS, outbox -> failed but the route 200s with emailed:false", async () => {
    vi.spyOn(emailModule, "sendInvoiceEmail").mockRejectedValue(new Error("smtp down"));
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId);

    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(200);
    expect(((await res.json()) as any).emailed).toBe(false);

    const outbox = await env.DB.prepare(`SELECT status, error FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ status: string; error: string | null }>();
    expect(outbox?.status).toBe("failed");
    expect(outbox?.error).toContain("smtp down");
  });

  it("400 VALIDATION_FAILED + NO mutation when the invoice has no client email", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { clientEmail: null });
    const res = await send(invoiceId, accessToken);
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");

    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);
  });

  it("400 VALIDATION_FAILED when the invoice has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,client_email,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,'jane@example.com',1,'issued',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    expect((await send(invoiceId, accessToken)).status).toBe(400);
  });

  it("404 NOT_FOUND for an unknown invoice", async () => {
    const { accessToken } = await seedAuthed();
    expect((await send(uuidv7(), accessToken)).status).toBe(404);
  });
});

describe("POST /invoices/:id/pdf", () => {
  it("(re)builds the PDF, persists pdf_r2_key + totals, no status change, no email", async () => {
    const spy = vi.spyOn(emailModule, "sendInvoiceEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { invoiceId } = await seedInvoice(userId, { status: "draft" });

    const res = await pdf(invoiceId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.status).toBe("draft");
    expect(body.totalCents).toBe(115500);
    expect(body.pdfUrl).toContain("/invoices/dl/");

    expect(spy).not.toHaveBeenCalled();
    const outbox = await env.DB.prepare(`SELECT COUNT(*) AS n FROM email_outbox WHERE related_id=?`)
      .bind(invoiceId).first<{ n: number }>();
    expect(outbox?.n).toBe(0);

    const row = await env.DB.prepare(`SELECT status, pdf_r2_key, total_cents FROM invoices WHERE id=?`)
      .bind(invoiceId).first<any>();
    expect(row.status).toBe("draft"); // unchanged
    expect(row.pdf_r2_key).toBe(`${userId}/invoices/${invoiceId}.pdf`);
    expect(row.total_cents).toBe(115500);

    const dl = await SELF.fetch(body.pdfUrl);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
  });

  it("400 VALIDATION_FAILED when the invoice has no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const invoiceId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#1','#2','#3',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO invoices (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,1,'draft',?,?)`,
    ).bind(invoiceId, userId, profileId, now, now).run();
    expect((await pdf(invoiceId, accessToken)).status).toBe(400);
  });

  it("404 NOT_FOUND for another user's invoice", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { invoiceId } = await seedInvoice(other.userId);
    expect((await pdf(invoiceId, accessToken)).status).toBe(404);
  });
});

describe("/invoices through the real app", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch(`${BASE}/invoices/some-id/issue`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(401);
  });

  it("GET /invoices/dl/* is public (a forged token is 403, not 401)", async () => {
    expect((await SELF.fetch(`${BASE}/invoices/dl/forged`)).status).toBe(403);
  });
});
```

### Step 9.2 — Run it (red)

```
npm test -- test/invoices-send-pdf.test.ts
```

Expected: failures — `sendInvoiceEmail` is not exported from `email.ts` (the `vi.spyOn` throws),
and `POST /invoices/:id/send` + `POST /invoices/:id/pdf` are not registered (404 on the happy
paths).

### Step 9.3 — Implement

In `src/lib/email.ts`, append the invoice seam after `sendQuoteEmail` (before the `base64Bytes`
helper, which it reuses):

```ts
/** The invoice-send email (tax-invoice PDF attachment). */
export interface InvoiceEmail {
  to: string;
  /** The trader's own email — set as Reply-To so the client replies to them. */
  replyTo: string;
  invoiceNumber: string;
  clientName: string | null;
  totalCents: number;
  pdf: Uint8Array;
}

/** PDF attachment ceiling — Cloudflare Email Send caps the message. */
const MAX_INVOICE_PDF_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Send the invoice email with the tax-invoice PDF attached (spec §4.5). Mirrors
 * sendQuoteEmail: mimetext/browser MIME (self-contained, workerd-safe), base64 PDF
 * attachment, cloudflare:email EmailMessage(from,to,raw) + env.EMAIL.send. `from` is
 * the magic-link sender (the only allowed_sender_addresses entry); Reply-To is the
 * trader so the client replies to them. Stubbed in route tests via
 * vi.spyOn(emailModule, "sendInvoiceEmail").
 */
export async function sendInvoiceEmail(env: Env, msg: InvoiceEmail): Promise<void> {
  if (msg.pdf.byteLength > MAX_INVOICE_PDF_BYTES) {
    throw new Error(`invoice PDF exceeds ${MAX_INVOICE_PDF_BYTES} bytes`);
  }

  const { createMimeMessage, Mailbox } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const total = `$${(msg.totalCents / 100).toFixed(2)}`;
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", new Mailbox(msg.replyTo, { type: "Reply-To" } as any));
  mime.setSubject(`Tax invoice ${msg.invoiceNumber} — ${total}`);
  mime.addMessage({
    contentType: "text/plain",
    data:
      `${greeting}\n\n` +
      `Please find attached tax invoice ${msg.invoiceNumber} for ${total}.\n\n` +
      `Reply to this email if you have any questions.\n`,
  });
  mime.addAttachment({
    filename: `invoice-${msg.invoiceNumber}.pdf`,
    contentType: "application/pdf",
    encoding: "base64",
    data: base64Bytes(msg.pdf),
  });

  const message = new EmailMessage(MAGIC_LINK_SENDER, msg.to, mime.asRaw());
  await env.EMAIL.send(message);
}
```

In `src/routes/invoices.ts`, add the import for the email module + the uuid helper at the top
(after the existing imports):

```ts
import * as emailModule from "../lib/email";
import { uuidv7 } from "../lib/ids";
```

Then append the two handlers AFTER the `POST /:id/issue` handler and BEFORE the `GET /dl/:token`
handler (the `dl` path is distinct, so order does not matter; grouping the POSTs keeps it
readable). Add a small shared builder that rebuilds + persists the PDF, returning the totals/key,
then the two routes:

```ts
/** (Re)build the invoice PDF -> R2 + persist pdf_r2_key + recomputed totals.
 *  Returns the recomputed total + the R2 key + the (unchanged) invoice status.
 *  NO number mint, NO status change — both /send and /pdf reuse this. */
async function rebuildInvoicePdf(
  c: Parameters<Parameters<typeof invoicesRoutes.post>[1]>[0],
  invoiceId: string,
  userId: string,
): Promise<{ key: string; totalCents: number; status: string; pdf: Uint8Array; clientName: string | null; clientEmail: string | null; number: string | null }> {
  const { invoice, lineItems, sender } = await loadInvoiceForPdf(c, invoiceId, userId);
  const gstEnabled = invoice.gst_enabled === 1;
  const gstInclusive = invoice.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
  );
  const now = nowMs();
  const paidCents = await invoiceAmountPaidCents(c.env.DB, invoiceId, userId);
  const pdf = await buildInvoicePdf(
    {
      number: invoice.number,
      clientName: invoice.client_name,
      clientEmail: invoice.client_email,
      gstEnabled,
      gstInclusive,
      subtotalCents: totals.subtotalCents,
      gstCents: totals.gstCents,
      totalCents: totals.totalCents,
      issueDate: invoice.issue_date ?? utcDate(now),
      dueDate: invoice.due_date,
      amountPaidCents: paidCents,
    },
    lineItems.map((li): InvoiceLineItemRow => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    sender,
  );
  const key = `${userId}/invoices/${invoiceId}.pdf`;
  await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });
  await c.env.DB.prepare(
    `UPDATE invoices
        SET pdf_r2_key = ?, subtotal_cents = ?, gst_cents = ?, total_cents = ?, updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(key, totals.subtotalCents, totals.gstCents, totals.totalCents, now, invoiceId, userId).run();
  return {
    key,
    totalCents: totals.totalCents,
    status: invoice.status,
    pdf,
    clientName: invoice.client_name,
    clientEmail: invoice.client_email,
    number: invoice.number,
  };
}

invoicesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");

  // Email PRECONDITION — validate BEFORE any mutation (mirrors the quote send): the
  // invoice must have a client email. loadInvoiceForPdf also 400s on no line items
  // and 404s on unknown/other-user, all before R2/outbox writes.
  const { invoice } = await loadInvoiceForPdf(c, invoiceId, userId);
  if (!invoice.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Invoice has no client email to send to");
  }

  // Ensure a current PDF -> R2 + persist key/totals (no status change, no number mint).
  const built = await rebuildInvoicePdf(c, invoiceId, userId);

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, built.key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const now = nowMs();
  const expiresAt = now + DOWNLOAD_TTL_SECONDS * 1000;

  // email_outbox row + gated send (mirrors the quote send exactly).
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'invoice_send', ?, 'queued', 'pdf', ?, ?, ?)`,
  ).bind(outboxId, userId, built.clientEmail ?? "", `Invoice ${built.number ?? ""}`, built.key, invoiceId, now).run();

  let emailed = false;
  const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();
  try {
    await emailModule.sendInvoiceEmail(c.env, {
      to: built.clientEmail!,
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
      invoiceNumber: built.number ?? "",
      clientName: built.clientName,
      totalCents: built.totalCents,
      pdf: built.pdf,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    emailed = true;
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    emailed = false;
  }

  return c.json({ status: built.status, totalCents: built.totalCents, pdfUrl, expiresAt, emailed });
});

invoicesRoutes.post("/:id/pdf", async (c) => {
  const userId = c.var.userId;
  const invoiceId = c.req.param("id");
  const built = await rebuildInvoicePdf(c, invoiceId, userId);

  const origin = new URL(c.req.url).origin;
  const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, built.key);
  const pdfUrl = `${origin}/invoices/dl/${token}`;
  const expiresAt = nowMs() + DOWNLOAD_TTL_SECONDS * 1000;

  return c.json({ status: built.status, totalCents: built.totalCents, pdfUrl, expiresAt });
});
```

### Step 9.4 — Run it (green)

```
npm test -- test/invoices-send-pdf.test.ts
```

Expected: `Test Files  1 passed (1)` / `Tests  10 passed (10)`. Then run the whole backend
suite to confirm no regression across the feature + existing tests:

```
npm test
```

Expected: all test files pass (the new files green; existing suites unchanged — note
`test/schemas.test.ts` now asserts `18`). Also run the typecheck:

```
npm run typecheck
```

Expected: no output (exit 0).

### Step 9.5 — Commit

```
git add src/lib/email.ts src/routes/invoices.ts test/invoices-send-pdf.test.ts
git commit -m "$(cat <<'EOF'
feat(invoices): POST /invoices/:id/send + /pdf + sendInvoiceEmail seam (invoice_send outbox)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Done — verification summary

After Task 9, the full backend slice is in place:

- Migration `0009` (3 tables + counters + 2 quotes columns + `email_outbox` rebuild).
- Sync wiring for `invoice` / `invoiceLineItem` / `payment` (schemas + table maps + profile guard).
- `invoiceCounter.ts`, `invoiceTotals.ts`, `pdfInvoice.ts`, `sendInvoiceEmail`.
- Routes: `POST /quotes/:id/pdf`, `POST /invoices/:id/issue`, `POST /invoices/:id/send`,
  `POST /invoices/:id/pdf`, public `GET /invoices/dl/:token` (in `PUBLIC_PATHS`), mounted with
  the `quotes` rate tier.

Final gate (run from the repo root):

```
npm test && npm run typecheck
```

Expected: every test file passes and `tsc --noEmit` exits 0.

---

## Spec ambiguities resolved

1. **Invoice-number format/scope.** §5 says "mirrors `quoteCounter.ts` — a per-profile monotonic
   invoice sequence" but never pins a prefix. Quote numbers are `SN-####` per-USER. Resolved:
   invoice numbers are **`INV-####`** (distinct prefix so quotes and invoices never visually
   collide) and **per-PROFILE** (the literal reading of §5 "per-profile"; the unique index is
   `UNIQUE(profile_id, number)`). The counter table is keyed on `profile_id`.

2. **`InvoiceLineItem` description field name.** §4.1 lists the field as `itemDescription` ("a
   clone of `QuoteLineItem`") while the quote line item's column is `description`. Resolved: the
   **sync field is `itemDescription`** (exact §4.1 name; binding contract with the iOS plan), the
   **D1 column is `description`** (clone of `quote_line_items`), and `syncTables.ts` maps
   `itemDescription → description`. The PDF builder takes `description` internally.

3. **Does `POST /invoices/:id/send` require the invoice to be issued first?** §4.5/§6 describe
   send as "ensure PDF, email client" and do not gate it on `status`. Resolved: send works on any
   non-deleted invoice (draft or issued) with line items + a client email; it does **not** mint a
   number or flip status (issuing is the separate, explicit step). This mirrors the quote send's
   "validate-before-mutate" precondition ordering and avoids a hidden state machine the spec
   never described. The response echoes the invoice's current `status` unchanged.

4. **What does `/invoices/:id/send`/`/pdf` return for totals/status?** §6 only specifies
   `/issue` returns `{ pdfUrl, number }`. Resolved by mirroring the quote-send response shape:
   `/issue` returns `{ number, status, issueDate, issuedAt, subtotalCents, gstCents, totalCents,
   pdfUrl, expiresAt }`; `/send` returns `{ status, totalCents, pdfUrl, expiresAt, emailed }`;
   `/pdf` returns `{ status, totalCents, pdfUrl, expiresAt }`. These are documented in each
   task's Interfaces block as the binding contract for the iOS plan.

5. **Re-issue idempotency.** §4.2 says issue "mints the invoice number"; it does not state what a
   second issue does. Resolved: a re-issue is idempotent — it keeps the existing `number`,
   `issue_date`, and `issued_at`, only refreshing the PDF + recomputed totals (parallels the
   quote send's "a re-send keeps the existing number"). The per-profile counter advances exactly
   once per invoice.

6. **`email_outbox` CHECK change.** §4.5 says migration 0009 "rebuilds the `kind` CHECK". SQLite
   cannot ALTER a CHECK constraint, so 0009 recreates `email_outbox` (copy rows → drop → rename →
   recreate the two indexes) to add `'invoice_send'` — the only way to widen the CHECK forward-only.
