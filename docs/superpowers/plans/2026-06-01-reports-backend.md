# Reports & Insights — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Ship the Cloudflare Worker `/export` backend for F2 Reports — a Bearer-auth `POST /export` that generates an AU bookkeeping CSV and a one-page summary PDF, stores them in the `RECEIPTS` R2 bucket behind a 7-day signed public download route, and (for the `accountant` format) emails the pack via the existing `env.EMAIL` binding while logging an `email_outbox` row.

**Architecture:** A single new Hono sub-app `export.ts` mounted at root (no `/v1`) in `src/app.ts`, gated by the global Bearer `authMiddleware` plus a new `export` rate-limit tier (60/user/hr). It reuses the existing R2 `RECEIPTS` bucket, the `tax_settings`/`transactions`/`receipt_images`/`email_outbox`/`profiles`/`users` D1 tables, the HS256 JWT primitive (`jose`, keyed on `JWT_SIGNING_KEY`) for the public download token, and the email seam pattern (`vi.spyOn(emailModule, ...)`). The only schema change is one nullable column `tax_settings.accountant_email`.

**Tech Stack:** TypeScript, Hono 4, Cloudflare Workers (D1 + R2 + KV + Email Send), `jose` (HS256), `zod` + `@hono/zod-validator`, new pure-JS deps `pdf-lib` + `mimetext`, Vitest (`@cloudflare/vitest-pool-workers` for unit/integration; `unstable_dev` for e2e).

---

## File structure

| File | Create / Modify | Responsibility |
|---|---|---|
| `package.json` | Modify | Add `pdf-lib` + `mimetext` to `dependencies`. |
| `migrations/0001_init.sql` | Modify | Add `accountant_email TEXT` to the `tax_settings` CREATE TABLE (line ~451). |
| `src/lib/syncTables.ts` | Modify | Add `accountantEmail -> accountant_email` to the `taxSettings.columns` map (line ~217). |
| `src/lib/exportToken.ts` | Create | Sign/verify the public download token `{ r2Key, exp }` (HS256 via `JWT_SIGNING_KEY`, 7-day exp). |
| `src/lib/csvExport.ts` | Create | Build the AU bookkeeping CSV from transactions + receipt-image keys (dollars from cents, signed `receipt_url`, deterministic order). |
| `src/lib/pdfExport.ts` | Create | Build the one-page summary PDF via `pdf-lib` → `Uint8Array`. |
| `src/lib/email.ts` | Modify | Add `sendExportEmail(env, {...})` building a MIME message via `mimetext` + `cloudflare:email` `EmailMessage`, attaching CSV+PDF, then `env.EMAIL.send(...)`. |
| `src/schemas/export.ts` | Create | Zod schema for the `POST /export` body. |
| `src/routes/export.ts` | Create | `POST /export` (validate, ownership, generate, store, email) + `GET /export/dl/:token` (public, streams R2). |
| `src/middleware/rateLimit.ts` | Modify | Add the `export` tier (60/user/hr) + extend `RateLimitKind`. |
| `src/middleware/auth.ts` | Modify | Add `/export/dl/` to `PUBLIC_PATHS`. |
| `src/app.ts` | Modify | Mount `rateLimit("export")` on `/export` + `/export/*` and `app.route("/export", exportRoutes)`. |
| `test/exportToken.test.ts` | Create | Unit: token round-trip, expired, forged. |
| `test/csvExport.test.ts` | Create | Unit: CSV header doc, columns, dollar conversion, `receipt_url`, ordering. |
| `test/pdfExport.test.ts` | Create | Unit: `%PDF` bytes + contains period/totals. |
| `test/export-route.test.ts` | Create | Integration: pdf/csv → `{url,expiresAt}`; `/export/dl` valid/expired/forged; accountant `email_outbox` queued→sent + `sendExportEmail` spy; validation (ownership, `from≤to`, `toEmail` required). |
| `test/export-app.test.ts` | Create | Integration: `/export` 401 without bearer; `export` tier 429 at the 61st call. |
| `e2e/snapceipt-export.e2e.test.ts` | Create | E2E (real HTTP): `POST /export` csv → `GET /export/dl/:token` round-trip; accountant path with the email spied via `E2E_TEST_MODE`. |

---

### Task 1: Add the `pdf-lib` + `mimetext` dependencies

Both are pure-JS, dependency-light, and run in `workerd` with `nodejs_compat` (already enabled in `wrangler.jsonc`). `pdf-lib` uses no Node `fs`/`stream` APIs for in-memory generation; `mimetext` builds a MIME string with no Node-only APIs. We pin them in `dependencies` so `wrangler dev`/`deploy` bundle them.

**Files:**
- Modify: `/Users/yangqi/Documents/github/Snapceipt/package.json` (lines 17–22, `dependencies`)

Steps:

- [ ] **Step 1: Install both deps as runtime dependencies.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm install pdf-lib@^1.17.1 mimetext@^3.0.24
```

- [ ] **Step 2: Confirm they landed in `dependencies` (not `devDependencies`) and resolve.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && node -e "const p=require('./package.json'); if(!p.dependencies['pdf-lib']||!p.dependencies['mimetext']) throw new Error('deps missing'); console.log('pdf-lib',p.dependencies['pdf-lib'],'mimetext',p.dependencies['mimetext']);"
```
Expected output: prints `pdf-lib ^1.17.1 mimetext ^3.0.24` (or the installed semver ranges) with no error.

- [ ] **Step 3: Confirm the bundle still typechecks (the deps ship their own types).**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run typecheck
```
Expected output: no errors (exit 0).

- [ ] **Step 4: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add package.json package-lock.json && git commit -m "build: add pdf-lib + mimetext for /export (pure-JS, Workers-safe)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `tax_settings.accountant_email` (migration + sync map)

Per spec §4.1 this is the only schema touch. The migration is edited in place (`0001_init.sql`) — the repo convention is that tests rebuild from migrations (`applyD1Migrations`), so adding a column to the CREATE TABLE is sufficient. We also wire it into the sync column map so the iOS plan's `accountantEmail` field syncs.

**Files:**
- Modify: `/Users/yangqi/Documents/github/Snapceipt/migrations/0001_init.sql` (`tax_settings` block, lines 451–467)
- Modify: `/Users/yangqi/Documents/github/Snapceipt/src/lib/syncTables.ts` (`taxSettings.columns`, lines 214–224)
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/schema.test.ts` (add one `it` to the existing `0001_init schema` describe)

Steps:

- [ ] **Step 1: Write the FAILING schema test.** Append this `it` block inside the existing `describe("0001_init schema", () => { ... })` in `test/schema.test.ts`, immediately after the `defaults tax_settings.wfh_rate_cents_per_hour to 70` test (it ends at line 186):
```typescript
  it("adds the nullable accountant_email column to tax_settings", async () => {
    const cols = await columnsOf("tax_settings");
    expect(cols.has("accountant_email"), "tax_settings missing accountant_email").toBe(true);

    // It is nullable: a tax_settings row inserted without it succeeds.
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO users(id,created_at,updated_at) VALUES('uacct',1,1)`),
      env.DB.prepare(`INSERT INTO profiles(id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
                      VALUES('pacct','uacct','Business','business','#0E7C72','#DCF0ED','#0A5950',1,1)`),
      env.DB.prepare(`INSERT INTO tax_settings(id,user_id,profile_id,created_at,updated_at,rev)
                      VALUES('ts1','uacct','pacct',1,1,1)`),
    ]);
    const row = await env.DB.prepare(`SELECT accountant_email FROM tax_settings WHERE id='ts1'`)
      .first<{ accountant_email: string | null }>();
    expect(row?.accountant_email).toBeNull();

    // And it round-trips a value.
    await env.DB.prepare(`UPDATE tax_settings SET accountant_email=? WHERE id='ts1'`)
      .bind("cpa@example.com").run();
    const updated = await env.DB.prepare(`SELECT accountant_email FROM tax_settings WHERE id='ts1'`)
      .first<{ accountant_email: string | null }>();
    expect(updated?.accountant_email).toBe("cpa@example.com");
  });
```

- [ ] **Step 2: Run it — expect FAIL.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/schema.test.ts
```
Expected: the new test fails (`tax_settings missing accountant_email` / SQLite `no column named accountant_email`). The other schema tests still pass.

- [ ] **Step 3: Add the column to the migration.** In `migrations/0001_init.sql`, change the `tax_settings` block (currently lines 458–459):
```sql
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 70,
  mileage_rate_cents_per_km   INTEGER NOT NULL DEFAULT 88,
```
to add the new column right after `mileage_rate_cents_per_km`:
```sql
  wfh_rate_cents_per_hour     INTEGER NOT NULL DEFAULT 70,
  mileage_rate_cents_per_km   INTEGER NOT NULL DEFAULT 88,
  accountant_email            TEXT,
```

- [ ] **Step 4: Add the sync mapping.** In `src/lib/syncTables.ts`, change the `taxSettings.columns` map (lines 217–223):
```typescript
    columns: {
      gstRateBps: "gst_rate_bps",
      financialYearStartMonth: "financial_year_start_month",
      mealsDeductiblePct: "meals_deductible_pct",
      wfhRateCentsPerHour: "wfh_rate_cents_per_hour",
      mileageRateCentsPerKm: "mileage_rate_cents_per_km",
    },
```
to:
```typescript
    columns: {
      gstRateBps: "gst_rate_bps",
      financialYearStartMonth: "financial_year_start_month",
      mealsDeductiblePct: "meals_deductible_pct",
      wfhRateCentsPerHour: "wfh_rate_cents_per_hour",
      mileageRateCentsPerKm: "mileage_rate_cents_per_km",
      accountantEmail: "accountant_email",
    },
```

- [ ] **Step 5: Run it — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/schema.test.ts
```
Expected: all `0001_init schema` tests pass including `adds the nullable accountant_email column to tax_settings`.

- [ ] **Step 6: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add migrations/0001_init.sql src/lib/syncTables.ts test/schema.test.ts && git commit -m "feat(db): add tax_settings.accountant_email column + sync map

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The download token (`src/lib/exportToken.ts`)

A signed `{ r2Key, exp }` token used by the PUBLIC `GET /export/dl/:token` route and embedded in CSV `receipt_url` links. We reuse the `jose` HS256 primitive and `JWT_SIGNING_KEY` (same key the access token uses). A JWT is the simplest signed envelope: `r2Key` is a custom claim and `exp` is the standard claim, so `jwtVerify` enforces expiry for free. Distinct issuer/audience (`snapceipt-export`) prevents an access token from being replayed as a download token and vice versa.

**Files:**
- Create: `/Users/yangqi/Documents/github/Snapceipt/src/lib/exportToken.ts`
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/exportToken.test.ts`

Steps:

- [ ] **Step 1: Write the FAILING test.** Create `test/exportToken.test.ts`:
```typescript
import { describe, expect, it } from "vitest";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../src/lib/exportToken";

const KEY = "test-signing-key-0123456789-abcdefghijklmnop";

describe("export download token", () => {
  it("round-trips the r2Key", async () => {
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv");
    const out = await verifyDownloadToken(KEY, token);
    expect(out.r2Key).toBe("u/abc/exports/x.csv");
  });

  it("uses a 7-day TTL", () => {
    expect(DOWNLOAD_TTL_SECONDS).toBe(7 * 24 * 60 * 60);
  });

  it("rejects a forged token (wrong key) -> throws", async () => {
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv");
    await expect(verifyDownloadToken("a-different-signing-key-0000000000000000", token)).rejects.toThrow();
  });

  it("rejects an expired token -> throws", async () => {
    // Sign with a negative TTL so it is already expired.
    const token = await signDownloadToken(KEY, "u/abc/exports/x.csv", -10);
    await expect(verifyDownloadToken(KEY, token)).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run it — expect FAIL.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/exportToken.test.ts
```
Expected: fails to resolve `../src/lib/exportToken` (module not found).

- [ ] **Step 3: Write the implementation.** Create `src/lib/exportToken.ts`:
```typescript
import { SignJWT, jwtVerify } from "jose";

/**
 * Signed download token for the PUBLIC GET /export/dl/:token route. It carries a
 * single custom claim `rk` (the R2 object key) plus the standard `exp`, signed
 * HS256 with the same JWT_SIGNING_KEY as the access token but under a DISTINCT
 * issuer/audience so an access token can never be replayed as a download token
 * (and vice versa). jose enforces signature + expiry on verify.
 */

export const DOWNLOAD_TTL_SECONDS = 7 * 24 * 60 * 60; // 7 days
const ISSUER = "snapceipt-export";
const AUDIENCE = "snapceipt-export-dl";

function keyBytes(signingKey: string): Uint8Array {
  return new TextEncoder().encode(signingKey);
}

/** Sign a download token for an R2 key. `ttlSeconds` defaults to 7 days; a
 *  negative value lets tests mint an already-expired token. */
export async function signDownloadToken(
  signingKey: string,
  r2Key: string,
  ttlSeconds: number = DOWNLOAD_TTL_SECONDS,
): Promise<string> {
  return new SignJWT({ rk: r2Key })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(ISSUER)
    .setAudience(AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(keyBytes(signingKey));
}

/** Verify a download token. Throws (jose JWTExpired / signature / claim error)
 *  on any failure — the route maps a throw to 403. */
export async function verifyDownloadToken(
  signingKey: string,
  token: string,
): Promise<{ r2Key: string }> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: ISSUER,
    audience: AUDIENCE,
    algorithms: ["HS256"],
  });
  const rk = (payload as { rk?: unknown }).rk;
  if (typeof rk !== "string" || rk.length === 0) {
    throw new Error("download token missing rk claim");
  }
  return { r2Key: rk };
}
```

- [ ] **Step 4: Run it — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/exportToken.test.ts
```
Expected: all 4 tests pass.

- [ ] **Step 5: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add src/lib/exportToken.ts test/exportToken.test.ts && git commit -m "feat(export): signed 7-day download token (HS256 via JWT_SIGNING_KEY)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: CSV export (`src/lib/csvExport.ts`)

Pure function: given a profile name, period label, the transaction rows (snake_case D1 shape), a map of transactionId → receipt R2 key, and a way to sign download links, produce the AU bookkeeping CSV string. Header doc line names profile + period; columns are exactly `date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url`. Amounts are dollars from cents (`amount_cents/100` to 2 dp). `receipt_url` is a signed `/export/dl/:token` URL for the receipt image key (empty when none). Order is deterministic: `txn_date DESC, id ASC` (the caller passes rows already in that order; the function preserves input order).

**Files:**
- Create: `/Users/yangqi/Documents/github/Snapceipt/src/lib/csvExport.ts`
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/csvExport.test.ts`

Steps:

- [ ] **Step 1: Write the FAILING test.** Create `test/csvExport.test.ts`:
```typescript
import { describe, expect, it } from "vitest";
import { buildExportCsv, type CsvTxnRow } from "../src/lib/csvExport";

const rows: CsvTxnRow[] = [
  {
    id: "t2", txn_date: "2026-05-30", merchant: "The Grounds", cat_key: "meals",
    amount_cents: -3300, gst_cents: 300, deductible_pct: 50,
    payment_method: "card", note: "client lunch, with comma",
  },
  {
    id: "t1", txn_date: "2026-05-12", merchant: "Officeworks", cat_key: "office",
    amount_cents: -8800, gst_cents: 800, deductible_pct: 100,
    payment_method: null, note: null,
  },
];

// Receipt key only for t2; t1 has no image.
const receiptKeys = new Map<string, string>([["t2", "u/u1/r/abc.jpg"]]);

describe("buildExportCsv", () => {
  it("emits the documented header, the exact column row, dollars from cents, and a signed receipt_url", async () => {
    const csv = await buildExportCsv({
      profileName: "Acme Pty Ltd",
      periodLabel: "May 2026",
      rows,
      receiptKeyByTxnId: receiptKeys,
      baseUrl: "https://api.test",
      signDownload: async (key) => `tok(${key})`,
    });
    const lines = csv.split("\n");

    // Line 0: the doc/header comment naming profile + period.
    expect(lines[0]).toContain("Acme Pty Ltd");
    expect(lines[0]).toContain("May 2026");

    // Line 1: the exact column header.
    expect(lines[1]).toBe(
      "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url",
    );

    // Line 2: t2 first (input order preserved), dollars from cents (-33.00),
    // gst 3.00, comma-bearing note quoted, signed receipt_url present.
    expect(lines[2]).toContain("2026-05-30");
    expect(lines[2]).toContain("The Grounds");
    expect(lines[2]).toContain("meals");
    expect(lines[2]).toContain("-33.00");
    expect(lines[2]).toContain("3.00");
    expect(lines[2]).toContain("50");
    expect(lines[2]).toContain('"client lunch, with comma"');
    expect(lines[2]).toContain("https://api.test/export/dl/tok(u/u1/r/abc.jpg)");

    // Line 3: t1 -88.00, no receipt -> empty receipt_url (trailing comma).
    expect(lines[3]).toContain("2026-05-12");
    expect(lines[3]).toContain("Officeworks");
    expect(lines[3]).toContain("-88.00");
    expect(lines[3].endsWith(",")).toBe(true); // empty receipt_url is the last field
  });

  it("quotes fields containing commas, quotes, or newlines (RFC 4180)", async () => {
    const csv = await buildExportCsv({
      profileName: "P", periodLabel: "May 2026",
      rows: [{
        id: "x", txn_date: "2026-05-01", merchant: 'Bob "the" Builder', cat_key: "office",
        amount_cents: -100, gst_cents: null, deductible_pct: null,
        payment_method: null, note: null,
      }],
      receiptKeyByTxnId: new Map(),
      baseUrl: "https://api.test",
      signDownload: async () => "tok",
    });
    // A double-quote inside a field is doubled and the field is wrapped in quotes.
    expect(csv).toContain('"Bob ""the"" Builder"');
  });
});
```

- [ ] **Step 2: Run it — expect FAIL.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/csvExport.test.ts
```
Expected: fails to resolve `../src/lib/csvExport`.

- [ ] **Step 3: Write the implementation.** Create `src/lib/csvExport.ts`:
```typescript
/**
 * AU bookkeeping CSV for /export. Pure: the route queries D1 + resolves receipt
 * keys + signs links, then hands rows here. Columns (spec §4.3):
 *   date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url
 * Amounts are dollars (cents/100, 2dp). receipt_url is a 7-day signed
 * /export/dl/:token link to the receipt image key (NOT the authed /images route);
 * empty when the txn has no image. Row order is the caller's input order
 * (route passes txn_date DESC, id ASC) — deterministic.
 */

/** The transaction columns this builder reads (snake_case D1 shape). */
export interface CsvTxnRow {
  id: string;
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
  payment_method: string | null;
  note: string | null;
}

export interface BuildCsvInput {
  profileName: string;
  periodLabel: string;
  rows: CsvTxnRow[];
  /** transactionId -> receipt image R2 key (first/primary image). */
  receiptKeyByTxnId: Map<string, string>;
  /** e.g. "https://api.snapceipt.app" — the public origin for the dl link. */
  baseUrl: string;
  /** Signs a 7-day download token for an R2 key (route passes the JWT signer). */
  signDownload: (r2Key: string) => Promise<string>;
}

const COLUMNS =
  "date,merchant,category,amount_incl_gst,gst,deductible_pct,payment_method,note,receipt_url";

/** RFC 4180 field escaping: wrap in quotes + double internal quotes when the
 *  field contains a comma, quote, CR or LF. */
function csvField(value: string): string {
  if (/[",\r\n]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}

/** Cents -> fixed 2-dp dollar string, sign preserved (-3300 -> "-33.00"). */
function dollars(cents: number): string {
  return (cents / 100).toFixed(2);
}

export async function buildExportCsv(input: BuildCsvInput): Promise<string> {
  const lines: string[] = [];
  // Line 0: a doc comment (prefixed with '#') naming the profile + period.
  lines.push(`# Snapceipt export — ${csvField(input.profileName)} — ${csvField(input.periodLabel)}`);
  // Line 1: the column header.
  lines.push(COLUMNS);

  for (const r of input.rows) {
    let receiptUrl = "";
    const key = input.receiptKeyByTxnId.get(r.id);
    if (key) {
      const token = await input.signDownload(key);
      receiptUrl = `${input.baseUrl}/export/dl/${token}`;
    }
    const fields = [
      r.txn_date,
      csvField(r.merchant),
      r.cat_key,
      dollars(r.amount_cents),
      r.gst_cents == null ? "" : dollars(r.gst_cents),
      r.deductible_pct == null ? "" : String(r.deductible_pct),
      r.payment_method == null ? "" : csvField(r.payment_method),
      r.note == null ? "" : csvField(r.note),
      receiptUrl, // already a URL; tokens are URL-safe so no escaping needed
    ];
    lines.push(fields.join(","));
  }

  return lines.join("\n");
}
```

- [ ] **Step 4: Run it — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/csvExport.test.ts
```
Expected: both tests pass.

- [ ] **Step 5: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add src/lib/csvExport.ts test/csvExport.test.ts && git commit -m "feat(export): AU bookkeeping CSV builder

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: PDF summary (`src/lib/pdfExport.ts`)

Pure function over the same data plus precomputed totals, producing the one-page summary PDF as a `Uint8Array` (spec §4.4): profile + period header, deductible total, GST total, top-5 categories, and a transaction list (date / merchant / amount / GST / deductible%). `pdf-lib` is async (`PDFDocument.create()`), uses the standard Helvetica font (no font file), and paginates by adding a new page when the cursor runs past the bottom margin. No embedded images.

**Files:**
- Create: `/Users/yangqi/Documents/github/Snapceipt/src/lib/pdfExport.ts`
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/pdfExport.test.ts`

Steps:

- [ ] **Step 1: Write the FAILING test.** Create `test/pdfExport.test.ts`:
```typescript
import { describe, expect, it } from "vitest";
import { PDFDocument } from "pdf-lib";
import { buildExportPdf, type PdfTxnRow } from "../src/lib/pdfExport";

const rows: PdfTxnRow[] = Array.from({ length: 80 }, (_, i) => ({
  txn_date: "2026-05-30",
  merchant: `Merchant ${i}`,
  cat_key: i % 2 === 0 ? "meals" : "office",
  amount_cents: -(100 + i),
  gst_cents: 10,
  deductible_pct: 50,
}));

describe("buildExportPdf", () => {
  it("returns a %PDF Uint8Array that opens, contains the period header, and paginates a long list", async () => {
    const bytes = await buildExportPdf({
      profileName: "Acme Pty Ltd",
      periodLabel: "FY2025-26",
      deductibleTotalCents: 12345,
      gstTotalCents: 6789,
      topCategories: [
        { catKey: "meals", spendCents: 5000 },
        { catKey: "office", spendCents: 3000 },
      ],
      rows,
    });

    // %PDF magic bytes (0x25 0x50 0x44 0x46).
    expect(bytes[0]).toBe(0x25);
    expect(bytes[1]).toBe(0x50);
    expect(bytes[2]).toBe(0x44);
    expect(bytes[3]).toBe(0x46);

    // It is a real, openable PDF and paginated (80 rows overflow one page).
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBeGreaterThan(1);
  });

  it("renders a $0 summary for empty data on a single page", async () => {
    const bytes = await buildExportPdf({
      profileName: "Acme",
      periodLabel: "May 2026",
      deductibleTotalCents: 0,
      gstTotalCents: 0,
      topCategories: [],
      rows: [],
    });
    expect(bytes[0]).toBe(0x25);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPageCount()).toBe(1);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/pdfExport.test.ts
```
Expected: fails to resolve `../src/lib/pdfExport`.

- [ ] **Step 3: Write the implementation.** Create `src/lib/pdfExport.ts`:
```typescript
import { PDFDocument, StandardFonts, rgb, type PDFPage, type PDFFont } from "pdf-lib";

/**
 * One-page (paginated if the txn list overflows) summary PDF for /export
 * (spec §4.4). Pure: the route precomputes the totals + top categories. Uses
 * pdf-lib's standard Helvetica (no font file) and no embedded images — pure-JS,
 * Workers-safe. Returns the encoded bytes (%PDF...).
 */

export interface PdfTxnRow {
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
}

export interface BuildPdfInput {
  profileName: string;
  periodLabel: string;
  deductibleTotalCents: number;
  gstTotalCents: number;
  topCategories: { catKey: string; spendCents: number }[];
  rows: PdfTxnRow[];
}

const PAGE_W = 595.28; // A4 portrait points
const PAGE_H = 841.89;
const MARGIN = 48;
const LINE = 16;
const BOTTOM = MARGIN + LINE;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export async function buildExportPdf(input: BuildPdfInput): Promise<Uint8Array> {
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

  // Header.
  draw(`Snapceipt — ${input.profileName}`, bold, 18);
  draw(`Period: ${input.periodLabel}`, font, 12);
  y -= LINE / 2;

  // Totals.
  draw(`Deductible total: ${dollars(input.deductibleTotalCents)}`, bold, 13);
  draw(`GST on purchases: ${dollars(input.gstTotalCents)}`, bold, 13);
  y -= LINE / 2;

  // Top-5 categories.
  draw("Top categories", bold, 13);
  if (input.topCategories.length === 0) {
    draw("  (no expenses in this period)", font, 11);
  } else {
    for (const c of input.topCategories.slice(0, 5)) {
      draw(`  ${c.catKey}: ${dollars(c.spendCents)}`, font, 11);
    }
  }
  y -= LINE / 2;

  // Transaction list.
  draw("Transactions", bold, 13);
  draw("date        merchant        amount    gst     deductible%", font, 10);
  for (const r of input.rows) {
    const ded = r.deductible_pct == null ? "-" : `${r.deductible_pct}%`;
    const gst = r.gst_cents == null ? "-" : dollars(r.gst_cents);
    const merchant = r.merchant.length > 22 ? `${r.merchant.slice(0, 21)}…` : r.merchant;
    draw(`${r.txn_date}  ${merchant.padEnd(22)} ${dollars(r.amount_cents).padStart(9)}  ${gst.padStart(7)}  ${ded}`, font, 10);
  }

  return doc.save();
}
```

- [ ] **Step 4: Run it — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/pdfExport.test.ts
```
Expected: both tests pass.

- [ ] **Step 5: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add src/lib/pdfExport.ts test/pdfExport.test.ts && git commit -m "feat(export): one-page summary PDF via pdf-lib

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `sendExportEmail` (`src/lib/email.ts`)

Add to the existing email seam module. Unlike `sendMagicLinkEmail` (which uses the `SendEmail` builder overload), the accountant pack needs CSV + PDF attachments, so we build a MIME message with `mimetext`'s `createMimeMessage()` and send it via the `cloudflare:email` `EmailMessage(from, to, raw)` constructor + `env.EMAIL.send(message)`. The `from` is the same allowed sender as magic-link (`noreply@snapceipt.app`, the only `allowed_sender_addresses` entry in `wrangler.jsonc`); `replyTo` is the user's email so the accountant can reply to the user. Tests stub this exactly like `sendMagicLinkEmail` (`vi.spyOn(emailModule, "sendExportEmail")`), so the live binding is never exercised in the test runtime.

**Files:**
- Modify: `/Users/yangqi/Documents/github/Snapceipt/src/lib/email.ts` (append after `sendMagicLinkEmail`, line 34)

Steps:

- [ ] **Step 1: Write the implementation** (no separate unit test — it is verified through the route test in Task 7 via the spy; a direct unit test cannot exercise the live `EMAIL` binding in the workers-pool runtime, matching the existing `sendMagicLinkEmail` precedent). Append to `src/lib/email.ts`, after the closing `}` of `sendMagicLinkEmail` (line 34):
```typescript

/** The accountant export email (CSV + PDF attachments). */
export interface ExportEmail {
  to: string;
  /** The user's own email — set as Reply-To so the accountant replies to them. */
  replyTo: string;
  profileName: string;
  periodLabel: string;
  csv: string;
  pdf: Uint8Array;
}

/** Total attachment ceiling (CSV + PDF) — Cloudflare Email Send caps the message. */
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Send the accountant tax-pack email with the CSV + PDF attached. Builds a MIME
 * message via mimetext (pure-JS) and sends it through the cloudflare:email
 * EmailMessage(from,to,raw) constructor + env.EMAIL.send. `from` is the
 * magic-link sender (the only allowed_sender_addresses entry). Stubbed in tests
 * via vi.spyOn(emailModule, "sendExportEmail"), exactly like sendMagicLinkEmail.
 */
export async function sendExportEmail(env: Env, msg: ExportEmail): Promise<void> {
  const csvBytes = new TextEncoder().encode(msg.csv);
  const total = csvBytes.byteLength + msg.pdf.byteLength;
  if (total > MAX_ATTACHMENT_BYTES) {
    throw new Error(`export attachments exceed ${MAX_ATTACHMENT_BYTES} bytes`);
  }

  // Lazy dynamic imports so the test runtime never needs to resolve the
  // cloudflare:email module at module-load (it is only resolvable inside workerd).
  // Use mimetext's BROWSER entrypoint: it is self-contained (its own Base64 + "\n"
  // EOL) with NO Node `os`/`mime-types` imports, so it bundles cleanly in workerd —
  // the default "mimetext" (node) entrypoint does `import { EOL } from "os"` +
  // `import * as o from "mime-types"`, which is unnecessary baggage under workerd.
  const { createMimeMessage } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", msg.replyTo);
  mime.setSubject(`Snapceipt export — ${msg.profileName} — ${msg.periodLabel}`);
  mime.addMessage({
    contentType: "text/plain",
    data:
      `Attached is the Snapceipt export for ${msg.profileName} (${msg.periodLabel}).\n\n` +
      `Files: a bookkeeping CSV and a one-page summary PDF.\n`,
  });
  // mimetext defaults attachments to Content-Transfer-Encoding: base64, but we
  // set `encoding` explicitly so the pre-encoded base64 `data` is never re-encoded.
  // base64Bytes() chunks the input so a large PDF can't blow the call stack via a
  // String.fromCharCode(...bigArray) spread.
  mime.addAttachment({
    filename: "snapceipt-export.csv",
    contentType: "text/csv",
    encoding: "base64",
    data: base64Bytes(csvBytes),
  });
  mime.addAttachment({
    filename: "snapceipt-summary.pdf",
    contentType: "application/pdf",
    encoding: "base64",
    data: base64Bytes(msg.pdf),
  });

  const message = new EmailMessage(MAGIC_LINK_SENDER, msg.to, mime.asRaw());
  await env.EMAIL.send(message);
}

/** Base64-encode bytes in chunks (avoids the call-stack limit of spreading a
 *  large Uint8Array into String.fromCharCode). */
function base64Bytes(bytes: Uint8Array): string {
  let binary = "";
  const CHUNK = 0x8000; // 32 KiB per fromCharCode call
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}
```

- [ ] **Step 2: Typecheck — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run typecheck
```
Expected: no errors. The `mimetext/browser` `AttachmentOptions` shape is
`{ filename, contentType, encoding?, data }` (verified against mimetext v3's
`dist/browser.d.ts`); the dynamic `import("mimetext/browser")` keeps it out of the
workers-pool module graph. If `mimetext/browser`'s types are not resolved by the
bundler's `node16`/`bundler` moduleResolution, fall back to `import("mimetext")`
(same named `createMimeMessage` export; only the EOL/Base64 internals differ).

- [ ] **Step 3: Run the full unit suite to confirm nothing regressed (the new function is unused until Task 7 but must compile into the bundle).**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test
```
Expected: still GREEN at the prior baseline plus the tests added in Tasks 2–5 (211 + new). No failures.

- [ ] **Step 4: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add src/lib/email.ts && git commit -m "feat(export): sendExportEmail (MIME CSV+PDF via mimetext + cloudflare:email)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: The `/export` route + schema + wiring (auth, rate-limit tier, public path, mount)

This is the integration task: the Zod body schema, the `export` rate-limit tier, the `/export/dl/` public path, the route handlers, and the app mounts. `POST /export` validates the body, asserts the profile belongs to `c.var.userId` and `from ≤ to`, queries the period's transactions (`txn_date DESC, id ASC`) + their receipt images, generates CSV and/or PDF, stores to `RECEIPTS` at `<userId>/exports/<exportId>.{csv,pdf}`, and either returns `{ url, expiresAt }` (pdf/csv) or emails + logs `email_outbox` and returns `{ status, outboxId }` (accountant). `GET /export/dl/:token` is public, verifies the token, and streams the R2 object.

**Files:**
- Create: `/Users/yangqi/Documents/github/Snapceipt/src/schemas/export.ts`
- Modify: `/Users/yangqi/Documents/github/Snapceipt/src/middleware/rateLimit.ts` (tiers map line 36–47; `RateLimitKind` line 50; the `tier` ternary line 144–149)
- Modify: `/Users/yangqi/Documents/github/Snapceipt/src/middleware/auth.ts` (`PUBLIC_PATHS` line 11)
- Create: `/Users/yangqi/Documents/github/Snapceipt/src/routes/export.ts`
- Modify: `/Users/yangqi/Documents/github/Snapceipt/src/app.ts` (imports + mounts)
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/export-route.test.ts`
- Test: `/Users/yangqi/Documents/github/Snapceipt/test/export-app.test.ts`

Steps:

- [ ] **Step 1: Write the FAILING route-behavior test.** Create `test/export-route.test.ts`:
```typescript
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import * as emailModule from "../src/lib/email";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { verifyDownloadToken } from "../src/lib/exportToken";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
afterEach(() => vi.restoreAllMocks());

beforeEach(async () => {
  await env.DB.exec("DELETE FROM email_outbox");
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM tax_settings");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

const BASE = "https://api.test";

/** Seed a user + device + session, return the access token + ids. */
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

/** Seed a business profile + 2 txns (one with a receipt image) for a user. */
async function seedProfileData(userId: string) {
  const profileId = uuidv7();
  const t1 = uuidv7();
  const t2 = uuidv7();
  const imgId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,merchant,cat_key,amount_cents,gst_cents,deductible_pct,payment_method,note,txn_date,created_at,updated_at)
     VALUES (?,?,?,'The Grounds','meals',-3300,300,50,'card','client lunch','2026-05-30',?,?)`,
  ).bind(t1, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO transactions (id,user_id,profile_id,merchant,cat_key,amount_cents,gst_cents,deductible_pct,txn_date,created_at,updated_at)
     VALUES (?,?,?,'Officeworks','office',-8800,800,100,'2026-05-12',?,?)`,
  ).bind(t2, userId, profileId, now, now).run();
  await env.DB.prepare(
    `INSERT INTO receipt_images (id,user_id,profile_id,transaction_id,r2_key,created_at,updated_at)
     VALUES (?,?,?,?,?,?,?)`,
  ).bind(imgId, userId, profileId, t1, `u/${userId}/r/${imgId}.jpg`, now, now).run();
  return { profileId, t1, t2, imgKey: `u/${userId}/r/${imgId}.jpg` };
}

describe("POST /export", () => {
  it("csv -> 200 { url, expiresAt } and the url is a public /export/dl/:token", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { url: string; expiresAt: number };
    expect(body.url).toContain("/export/dl/");
    expect(typeof body.expiresAt).toBe("number");
  });

  it("pdf -> 200 { url, expiresAt }; the downloaded object is a real %PDF", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "pdf", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(200);
    const { url } = (await res.json()) as { url: string };
    const dl = await SELF.fetch(url);
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("application/pdf");
    const bytes = new Uint8Array(await dl.arrayBuffer());
    expect(bytes[0]).toBe(0x25); // %
  });

  it("rejects a profile owned by another user with 403 FORBIDDEN", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { profileId } = await seedProfileData(other.userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(403);
    expect(((await res.json()) as any).error.code).toBe("FORBIDDEN");
  });

  it("rejects from > to with 400 VALIDATION_FAILED", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-31", to: "2026-05-01" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("rejects accountant format without toEmail with 400", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "accountant", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(400);
    expect(((await res.json()) as any).error.code).toBe("VALIDATION_FAILED");
  });

  it("accountant -> emails the pack, logs email_outbox queued->sent, returns { status, outboxId }", async () => {
    const sendSpy = vi.spyOn(emailModule, "sendExportEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const res = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "accountant", from: "2026-05-01", to: "2026-05-31", toEmail: "cpa@example.com" }),
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; outboxId: string };
    expect(body.status).toBe("sent");
    expect(typeof body.outboxId).toBe("string");

    // sendExportEmail called with BOTH attachments + the user's reply-to.
    expect(sendSpy).toHaveBeenCalledTimes(1);
    const arg = sendSpy.mock.calls[0]![1] as emailModule.ExportEmail;
    expect(arg.to).toBe("cpa@example.com");
    expect(arg.replyTo).toBe(email);
    expect(typeof arg.csv).toBe("string");
    expect(arg.csv.length).toBeGreaterThan(0);
    expect(arg.pdf.byteLength).toBeGreaterThan(0);

    // email_outbox row transitioned queued -> sent.
    const row = await env.DB.prepare(`SELECT status, kind, to_email, sent_at FROM email_outbox WHERE id = ?`)
      .bind(body.outboxId).first<{ status: string; kind: string; to_email: string; sent_at: number | null }>();
    expect(row?.status).toBe("sent");
    expect(row?.kind).toBe("export_accountant");
    expect(row?.to_email).toBe("cpa@example.com");
    expect(row?.sent_at).not.toBeNull();
  });
});

describe("GET /export/dl/:token", () => {
  it("streams the CSV for a valid token", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const post = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    const { url } = (await post.json()) as { url: string };
    const dl = await SELF.fetch(url); // no auth header — public route
    expect(dl.status).toBe(200);
    expect(dl.headers.get("content-type")).toContain("text/csv");
    const text = await dl.text();
    expect(text).toContain("date,merchant,category,amount_incl_gst");
  });

  it("returns 403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/export/dl/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("returns 403 for an expired token", async () => {
    // Mint an already-expired token for some plausible key (signed with the test key).
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const token = await signDownloadToken(env.JWT_SIGNING_KEY, "u/x/exports/y.csv", -10);
    const res = await SELF.fetch(`${BASE}/export/dl/${token}`);
    expect(res.status).toBe(403);
  });

  // Sanity: confirm the token issued by the route verifies under the test key.
  it("issues a token verifiable with the same signing key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { profileId } = await seedProfileData(userId);
    const post = await SELF.fetch(`${BASE}/export`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    const { url } = (await post.json()) as { url: string };
    const token = url.slice(url.lastIndexOf("/") + 1);
    const out = await verifyDownloadToken(env.JWT_SIGNING_KEY, token);
    expect(out.r2Key).toContain(`${userId}/exports/`);
    expect(out.r2Key.endsWith(".csv")).toBe(true);
  });
});
```

- [ ] **Step 2: Run it — expect FAIL.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/export-route.test.ts
```
Expected: fails — `/export` is not mounted yet (requests 404/501 or the route module is missing).

- [ ] **Step 3: Write the body schema.** Create `src/schemas/export.ts`:
```typescript
import { z } from "zod";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");

/**
 * POST /export body (spec §4.2). `toEmail` is required iff format === "accountant"
 * (enforced by superRefine so the failure is a clean VALIDATION_FAILED). The
 * from<=to check is done in the route (it also resolves the profile), not here.
 */
export const exportRequestSchema = z
  .object({
    profileId: z.string().min(1),
    format: z.enum(["pdf", "csv", "accountant"]),
    from: isoDate,
    to: isoDate,
    toEmail: z.string().email().optional(),
  })
  .superRefine((val, ctx) => {
    if (val.format === "accountant" && !val.toEmail) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["toEmail"],
        message: "toEmail is required when format is 'accountant'",
      });
    }
  });

export type ExportRequest = z.infer<typeof exportRequestSchema>;
```

- [ ] **Step 4: Add the `export` rate-limit tier.** In `src/middleware/rateLimit.ts`:

  (a) Add the tier to `RATE_LIMIT_TIERS` (after the `extract` entry at line 44):
```typescript
  /** receipt extraction — calls an external API; keep it tight. */
  extract: { name: "extract", limit: 30, windowMs: HOUR_MS, dimension: "user" },
  /** export generation — file build + email; 60/user/hr. */
  export: { name: "export", limit: 60, windowMs: HOUR_MS, dimension: "user" },
```

  (b) Extend `RateLimitKind` (line 50):
```typescript
export type RateLimitKind = "auth" | "sync" | "extract" | "export" | "default";
```

  (c) Extend the `tier` selection ternary (lines 144–149) to handle `export`:
```typescript
    const tier =
      kind === "sync"
        ? RATE_LIMIT_TIERS.sync
        : kind === "extract"
          ? RATE_LIMIT_TIERS.extract
          : kind === "export"
            ? RATE_LIMIT_TIERS.export
            : RATE_LIMIT_TIERS.default;
```

- [ ] **Step 5: Add the public download path.** In `src/middleware/auth.ts`, change `PUBLIC_PATHS` (line 11) to:
```typescript
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/"];
```
(The trailing `/` makes it a prefix match, so only `/export/dl/*` is public; `POST /export` itself stays Bearer-gated.)

- [ ] **Step 6: Write the route.** Create `src/routes/export.ts`:
```typescript
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { uuidv7 } from "../lib/ids";
import { nowMs } from "../lib/time";
import { validate } from "./auth";
import { exportRequestSchema } from "../schemas/export";
import { buildExportCsv, type CsvTxnRow } from "../lib/csvExport";
import { buildExportPdf, type PdfTxnRow } from "../lib/pdfExport";
import { sendExportEmail } from "../lib/email";
import { signDownloadToken, verifyDownloadToken, DOWNLOAD_TTL_SECONDS } from "../lib/exportToken";

/**
 * POST /export        — Bearer (global auth) + rate tier "export" (app.ts).
 * GET  /export/dl/:token — PUBLIC (in PUBLIC_PATHS); streams the signed R2 object.
 */
export const exportRoutes = new Hono<AppEnv>();

/** A transaction row as queried from D1 for the period (snake_case). */
interface TxnRow {
  id: string;
  txn_date: string;
  merchant: string;
  cat_key: string;
  amount_cents: number;
  gst_cents: number | null;
  deductible_pct: number | null;
  payment_method: string | null;
  note: string | null;
}

/** Compute the deductible + GST totals + top-5 categories for the PDF. */
function summarize(rows: TxnRow[]) {
  let deductibleTotalCents = 0;
  let gstTotalCents = 0;
  const byCat = new Map<string, number>();
  for (const r of rows) {
    if (r.amount_cents < 0) {
      const spend = -r.amount_cents;
      if (r.deductible_pct != null) {
        deductibleTotalCents += Math.round((spend * r.deductible_pct) / 100);
      }
      if (r.gst_cents != null) gstTotalCents += r.gst_cents;
      byCat.set(r.cat_key, (byCat.get(r.cat_key) ?? 0) + spend);
    }
  }
  const topCategories = [...byCat.entries()]
    .map(([catKey, spendCents]) => ({ catKey, spendCents }))
    .sort((a, b) => b.spendCents - a.spendCents)
    .slice(0, 5);
  return { deductibleTotalCents, gstTotalCents, topCategories };
}

exportRoutes.post("/", validate("json", exportRequestSchema), async (c) => {
  const userId = c.var.userId;
  const body = c.req.valid("json");

  // from <= to (lexical compare is valid for YYYY-MM-DD).
  if (body.from > body.to) {
    throw new ApiError("VALIDATION_FAILED", "`from` must be <= `to`");
  }

  // Profile ownership (scoped to the authed user).
  const profile = await c.env.DB.prepare(
    `SELECT id, name FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(body.profileId, userId).first<{ id: string; name: string }>();
  if (!profile) throw new ApiError("FORBIDDEN", "Profile not found for this user");

  // Period transactions (deterministic: txn_date DESC, id ASC).
  const { results: txns } = await c.env.DB.prepare(
    `SELECT id, txn_date, merchant, cat_key, amount_cents, gst_cents, deductible_pct, payment_method, note
       FROM transactions
      WHERE user_id = ? AND profile_id = ? AND txn_date >= ? AND txn_date <= ? AND deleted_at IS NULL
      ORDER BY txn_date DESC, id ASC`,
  ).bind(userId, body.profileId, body.from, body.to).all<TxnRow>();

  // Receipt image keys for those transactions (first image per txn).
  const receiptKeyByTxnId = new Map<string, string>();
  const { results: imgs } = await c.env.DB.prepare(
    `SELECT transaction_id, r2_key FROM receipt_images
      WHERE user_id = ? AND profile_id = ? AND transaction_id IS NOT NULL AND deleted_at IS NULL
      ORDER BY created_at ASC`,
  ).bind(userId, body.profileId).all<{ transaction_id: string; r2_key: string }>();
  for (const img of imgs) {
    if (!receiptKeyByTxnId.has(img.transaction_id)) {
      receiptKeyByTxnId.set(img.transaction_id, img.r2_key);
    }
  }

  const periodLabel = `${body.from} to ${body.to}`;
  const exportId = uuidv7();
  const origin = new URL(c.req.url).origin;
  const signDownload = (r2Key: string) => signDownloadToken(c.env.JWT_SIGNING_KEY, r2Key);

  // Build the CSV (needed for csv + accountant).
  const buildCsv = () =>
    buildExportCsv({
      profileName: profile.name,
      periodLabel,
      rows: txns as CsvTxnRow[],
      receiptKeyByTxnId,
      baseUrl: origin,
      signDownload,
    });

  // Build the PDF (needed for pdf + accountant).
  const buildPdf = () => {
    const s = summarize(txns);
    return buildExportPdf({
      profileName: profile.name,
      periodLabel,
      deductibleTotalCents: s.deductibleTotalCents,
      gstTotalCents: s.gstTotalCents,
      topCategories: s.topCategories,
      rows: txns as PdfTxnRow[],
    });
  };

  if (body.format === "csv") {
    const csv = await buildCsv();
    const key = `${userId}/exports/${exportId}.csv`;
    await c.env.RECEIPTS.put(key, csv, { httpMetadata: { contentType: "text/csv" } });
    const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
    return c.json({ url: `${origin}/export/dl/${token}`, expiresAt: nowMs() + DOWNLOAD_TTL_SECONDS * 1000 });
  }

  if (body.format === "pdf") {
    const pdf = await buildPdf();
    const key = `${userId}/exports/${exportId}.pdf`;
    await c.env.RECEIPTS.put(key, pdf, { httpMetadata: { contentType: "application/pdf" } });
    const token = await signDownloadToken(c.env.JWT_SIGNING_KEY, key);
    return c.json({ url: `${origin}/export/dl/${token}`, expiresAt: nowMs() + DOWNLOAD_TTL_SECONDS * 1000 });
  }

  // accountant: generate both, store the PDF, log the outbox row, send the email.
  const csv = await buildCsv();
  const pdf = await buildPdf();
  const pdfKey = `${userId}/exports/${exportId}.pdf`;
  await c.env.RECEIPTS.put(pdfKey, pdf, { httpMetadata: { contentType: "application/pdf" } });

  const toEmail = body.toEmail!; // schema guarantees presence for accountant
  const outboxId = uuidv7();
  const now = nowMs();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, created_at)
     VALUES (?, ?, ?, 'export_accountant', ?, 'queued', 'pdf', ?, ?)`,
  ).bind(outboxId, userId, toEmail, `Snapceipt export — ${profile.name}`, pdfKey, now).run();

  // The user's email is the reply-to.
  const user = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();

  try {
    await sendExportEmail(c.env, {
      to: toEmail,
      replyTo: user?.email ?? "noreply@snapceipt.app",
      profileName: profile.name,
      periodLabel,
      csv,
      pdf,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    return c.json({ status: "sent", outboxId });
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    throw new ApiError("INTERNAL", "Failed to send export email");
  }
});

// PUBLIC: GET /export/dl/:token — verify the signed token + stream the R2 object.
exportRoutes.get("/dl/:token", async (c) => {
  const token = c.req.param("token");
  let r2Key: string;
  try {
    ({ r2Key } = await verifyDownloadToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired download link");
  }
  const obj = await c.env.RECEIPTS.get(r2Key);
  if (!obj) throw new ApiError("NOT_FOUND", "Export not found");

  // Buffer fully (mirrors images.ts) so the R2 read completes before the
  // response returns — a dangling stream blocks vitest-pool-workers teardown.
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

- [ ] **Step 7: Mount in `src/app.ts`.** Add the import after the `extractRoutes` import (line 13):
```typescript
import { exportRoutes } from "./routes/export";
```
Add the rate-limit mounts after the `/images/*` limiter (line 59), mirroring the extract dual-mount comment:
```typescript
// Export generation — file build + email; 60/user/hr. Mount on BOTH the exact
// path (POST /export) AND the wildcard (GET /export/dl/*) so the limiter runs
// for the actual POST too. The public download stays gated by PUBLIC_PATHS, not
// the limiter (a fresh anonymous client opening a 7-day link is fine).
app.use("/export", rateLimit("export"));
app.use("/export/*", rateLimit("export"));
```
Add the route mount after `app.route("/extract", extractRoutes);` (line 73):
```typescript
// Protected: POST /export (+ public GET /export/dl/:token via PUBLIC_PATHS).
app.route("/export", exportRoutes);
```

- [ ] **Step 8: Run the route test — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/export-route.test.ts
```
Expected: all `POST /export` + `GET /export/dl/:token` tests pass.

- [ ] **Step 9: Write the FAILING app-mount test (auth gate + rate tier).** Create `test/export-app.test.ts`:
```typescript
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";

async function seedSession() {
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
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'P','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(uuidv7(), userId, now, now).run();
  const { accessToken } = await issueSession(env.DB, { userId, deviceId, signingKey: env.JWT_SIGNING_KEY });
  return { userId, accessToken };
}

beforeEach(async () => {
  await env.DB.exec("DELETE FROM receipt_images");
  await env.DB.exec("DELETE FROM transactions");
  await env.DB.exec("DELETE FROM profiles");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM devices");
  await env.DB.exec("DELETE FROM users");
});

describe("/export (through the real app)", () => {
  it("requires auth (401 without a bearer token)", async () => {
    const res = await SELF.fetch("https://x/export", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ profileId: "p", format: "csv", from: "2026-05-01", to: "2026-05-31" }),
    });
    expect(res.status).toBe(401);
  });

  it("GET /export/dl/* is public (no auth) — a forged token is 403, not 401", async () => {
    const res = await SELF.fetch("https://x/export/dl/forged");
    expect(res.status).toBe(403);
  });

  it("rate-limits the export tier at 60/user/hr (the 61st request is 429)", async () => {
    const { accessToken } = await seedSession();
    const headers = { authorization: `Bearer ${accessToken}`, "content-type": "application/json" };
    // Use an unowned profileId so each request short-circuits at 403 (still
    // counts against the limiter, which runs BEFORE the handler).
    const body = JSON.stringify({ profileId: "nope", format: "csv", from: "2026-05-01", to: "2026-05-31" });
    let last = 200;
    for (let i = 0; i < 61; i++) {
      const res = await SELF.fetch("https://x/export", { method: "POST", headers, body });
      last = res.status;
    }
    expect(last).toBe(429);
  });
});
```

- [ ] **Step 10: Run the app test — expect PASS.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test -- test/export-app.test.ts
```
Expected: all 3 tests pass (401 unauth, 403 public-forged, 429 at the 61st).

- [ ] **Step 11: Run the FULL unit suite — expect GREEN (baseline + new).**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test
```
Expected: every prior test still passes (was 211) plus all new tests from Tasks 2–7. No failures.

- [ ] **Step 12: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add src/schemas/export.ts src/middleware/rateLimit.ts src/middleware/auth.ts src/routes/export.ts src/app.ts test/export-route.test.ts test/export-app.test.ts && git commit -m "feat(export): POST /export + public GET /export/dl/:token (auth, export rate tier)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: E2E round-trip (real HTTP via `unstable_dev`)

Black-box prove the route over a real socket: authenticate via the magic-link `devToken` seam (`E2E_TEST_MODE`), push a profile + a transaction, `POST /export` csv, then `GET /export/dl/:token` (no auth) and assert the CSV comes back. Because the live `EMAIL` binding cannot send in the local dev runtime, the accountant assertion only checks that the request reaches validation (a `400` for missing `toEmail`) — the full accountant send is covered by the spied integration test in Task 7. This file lives in `e2e/` (the Node-env project) and reuses the exact `applyMigrations` + `unstable_dev` + `api()` harness from `e2e/snapceipt.e2e.test.ts`.

**Files:**
- Create: `/Users/yangqi/Documents/github/Snapceipt/e2e/snapceipt-export.e2e.test.ts`

Steps:

- [ ] **Step 1: Write the e2e test.** Create `e2e/snapceipt-export.e2e.test.ts` (mirrors the boot harness in `e2e/snapceipt.e2e.test.ts` lines 34–124):
```typescript
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
  persistDir = mkdtempSync(path.join(tmpdir(), "snapceipt-e2e-export-"));
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

describe("e2e (real HTTP): /export csv -> /export/dl round-trip", () => {
  it("authenticates, pushes a txn, exports csv, and downloads it back", async () => {
    const email = `e2e-export+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.77";

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
    const txnId = crypto.randomUUID();
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
              profileType: "business", accent1: "#000", accent2: "#111", accent3: "#222",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
          {
            mutationId: crypto.randomUUID(), entityType: "transaction", entityId: txnId,
            op: "upsert", updatedAt: t,
            payload: {
              id: txnId, userId, profileId, type: "transaction", merchant: "The Grounds",
              catKey: "meals", amountCents: -3300, gstCents: 300, deductiblePct: 50,
              currency: "AUD", txnDate: "2026-05-30", mode: "business",
              createdAt: t, updatedAt: t, deletedAt: null, rev: 0, lastEditedDeviceId: deviceId,
            },
          },
        ],
      },
    });
    expect(pushRes.status).toBe(200);

    // Export CSV.
    const exportRes = await api("/export", {
      method: "POST", headers: authHeaders,
      body: { profileId, format: "csv", from: "2026-05-01", to: "2026-05-31" },
    });
    expect(exportRes.status).toBe(200);
    expect(typeof exportRes.json.url).toBe("string");
    expect(typeof exportRes.json.expiresAt).toBe("number");

    // Download it back (public, no auth) — slice off the absolute origin.
    const dlPath = exportRes.json.url.slice(baseUrl.length);
    const dl = await api(dlPath);
    expect(dl.status).toBe(200);
    expect(dl.text).toContain("date,merchant,category,amount_incl_gst");
    expect(dl.text).toContain("The Grounds");
    expect(dl.text).toContain("-33.00");
  });

  it("rejects accountant format without toEmail (validation reachable over HTTP)", async () => {
    const email = `e2e-export-acct+${Date.now()}@example.com`;
    const deviceId = crypto.randomUUID();
    const ip = "203.0.113.78";
    const reqRes = await api("/auth/magic-link/request", {
      method: "POST", headers: { "cf-connecting-ip": ip }, body: { email },
    });
    const verifyRes = await api("/auth/magic-link/verify", {
      method: "POST", headers: { "cf-connecting-ip": ip, "x-device-id": deviceId }, body: { token: reqRes.json.devToken },
    });
    const authHeaders = { authorization: `Bearer ${verifyRes.json.accessToken}` };
    const res = await api("/export", {
      method: "POST", headers: authHeaders,
      body: { profileId: crypto.randomUUID(), format: "accountant", from: "2026-05-01", to: "2026-05-31" },
    });
    expect(res.status).toBe(400);
    expect(res.json.error.code).toBe("VALIDATION_FAILED");
  });

  it("returns 403 for a forged download token", async () => {
    const res = await api("/export/dl/not.a.real.token");
    expect(res.status).toBe(403);
  });
});
```

- [ ] **Step 2: Run the e2e suite — expect PASS (baseline + new).**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run test:e2e
```
Expected: the prior 9 e2e tests pass plus the 3 new export e2e tests. No failures.

- [ ] **Step 3: Commit.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git add e2e/snapceipt-export.e2e.test.ts && git commit -m "test(export): e2e /export csv -> /export/dl round-trip + validation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Full green sweep + typecheck

Final verification that the whole backend is GREEN on both suites and typechecks. No new code — just the gates.

**Files:** none (verification only).

Steps:

- [ ] **Step 1: Typecheck.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run typecheck
```
Expected: exit 0, no errors.

- [ ] **Step 2: Full unit suite.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm test
```
Expected: GREEN — the prior 211 plus the new tests (exportToken 4, csvExport 2, pdfExport 2, schema +1, export-route ~10, export-app 3). No failures.

- [ ] **Step 3: Full e2e suite.**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && npm run test:e2e
```
Expected: GREEN — the prior 9 plus the 3 new export e2e tests. No failures.

- [ ] **Step 4: Confirm the working tree is clean (everything committed).**
```bash
cd /Users/yangqi/Documents/github/Snapceipt && git status --porcelain
```
Expected: empty output.
