# Configurable GST + Business Profile + HTML Quotes — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GST rate configurable (basis points, snapshotted per document), add business-profile details + logo, and replace the quote PDF with a hosted, signed HTML quote page that the "send" flow emails as a link.

**Architecture:** One additive D1 migration (`0010`) carries new `profiles`/`quotes`/`invoices` columns; the sync schema + table maps wire them through the generic `/sync` path. `quoteTotals.ts` gains a `gstRateBp` parameter. A new self-contained HTML template + a public `GET /q/:token` (signed 90-day token via the existing `exportToken` HMAC machinery) renders quotes on the fly with an R2 logo inlined as a data-URI. `POST /quotes/:id/link` mints the token; `POST /quotes/:id/send` emails the link; `POST /profile/logo` stores the logo to R2. The `pdfQuote.ts` builder + `/quotes/:id/pdf` + `/quotes/dl/:token` are removed.

**Tech Stack:** Cloudflare Workers, Hono, D1 (SQLite), R2, `jose` (HS256 tokens), `zod` (sync schemas), `mimetext/browser` + `cloudflare:email` (email seam), vitest via `@cloudflare/vitest-pool-workers`.

## Global Constraints

- **Money = INTEGER cents**; ids = UUIDv7 TEXT; timestamps = INTEGER epoch ms; dates = TEXT `YYYY-MM-DD`. (SPINE conventions.)
- **GST rate is basis points** (`gstRateBp`): `1000`=10%, `1500`=15%, `1250`=12.5%. **Null/absent rate ⇒ treat as `1000`** everywhere (totals + the "GST (X%)" label).
- **GST formulas (integer cents):** exclusive `gst = round(subtotal × bp / 10000)`, `total = subtotal + gst`; inclusive `gross = Σ lines`, `gst = round(gross × bp / (10000 + bp))`, `subtotal = gross − gst`, `total = gross`. At `bp=1000` these reduce to the current `×0.10` / `×0.10/1.10` behaviour.
- **`gstRateBp` is snapshotted per document** (`quotes.gst_rate_bp`, `invoices.gst_rate_bp`); a sent document's GST never changes if the profile rate later changes. Backend reads the **document's** rate (fallback `1000`).
- **BAS stays ÷11** — `basEngine.ts` is unchanged (out of scope).
- **New wire keys (camelCase → snake_case):** `gstRateBp`→`gst_rate_bp`, `businessEmail`→`business_email`, `phone`→`phone`, `website`→`website`, `address`→`address`, `bankDetails`→`bank_details`, `logoR2Key`→`logo_r2_key`. `logoR2Key` is server-owned (pull-only on iOS) but is mapped normally in syncTables/schema like any column — the pull-only behaviour is the iOS side's concern.
- **Token TTL = 90 days** for the quote-link token. Distinct issuer/audience from the access token and the (removed) download token so tokens can't be replayed across surfaces.
- **Public routes** are listed in `PUBLIC_PATHS` (`src/middleware/auth.ts`); an entry ending in `/` matches by prefix.
- **Route base URL for minted links:** `https://api.snapceipt.cc` (spec §4).
- **Email seam discipline:** validate-before-mutate (a missing client email is a 400 *before* any mutation — no number burned, status stays draft, no outbox row); call `sendQuoteEmail` unconditionally inside try/catch; a send failure leaves the outbox `failed`, `emailed:false`, and the route still 200s.
- **Test command:** `npm test` (runs `vitest run`). Focused: `npm test -- <file>` (e.g. `npm test -- test/quoteTotals.test.ts`). The suite runs serially against one warmed workerd runtime.
- **Commit messages** end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

**Migration**
- Create `migrations/0010_quote_tax_business.sql` — additive `ALTER TABLE ADD COLUMN` for `profiles` (7 cols), `quotes` (1 col), `invoices` (1 col).

**Sync wiring**
- Modify `src/schemas/entities.ts` — add the new optional fields to `profileEntity`, `quoteEntity` (new specialized schema), `invoiceEntity`.
- Modify `src/lib/syncTables.ts` — add the new columns to the `profile`, `quote`, `invoice` column maps.

**Totals**
- Modify `src/lib/quoteTotals.ts` — add a `gstRateBp` parameter; replace the hardcoded `GST_RATE = 0.1`.

**Tokens + HTML**
- Modify `src/lib/exportToken.ts` — add `signQuoteLinkToken` / `verifyQuoteLinkToken` (90-day TTL, `qid`+`uid` claims, distinct issuer/audience).
- Create `src/lib/quoteHtml.ts` — pure `renderQuoteHtml(data)` self-contained HTML template (inline CSS, print-friendly).

**Routes**
- Modify `src/routes/quotes.ts` — remove `POST /:id/pdf` + `GET /dl/:token`; add `GET /q/:token`-backing logic via a shared loader; rework `POST /:id/send` to email the link + return `{ url, emailed, number }`; add `POST /:id/link`.
- Create `src/routes/quoteLink.ts` — the public `GET /q/:token` route group (renders HTML).
- Create `src/routes/profile.ts` — `POST /profile/logo` (R2 store + set `logo_r2_key`).
- Modify `src/lib/email.ts` — rework `sendQuoteEmail` to send a **link** (no PDF attachment).
- Modify `src/app.ts` — mount `/q` (public) + `/profile` (auth-gated) route groups + their rate limiters; add `/q/` to public-path docs.
- Modify `src/middleware/auth.ts` — add `/q/` to `PUBLIC_PATHS`, remove `/quotes/dl/`.
- Delete `src/lib/pdfQuote.ts`.

**Tests**
- Modify `test/quoteTotals.test.ts` — add `gstRateBp` golden tests.
- Modify `test/schemas.test.ts` — assert the new profile fields parse (count guard unchanged: `SYNCABLE_TYPES.length === 18`).
- Modify `test/sync-push.test.ts` — add column-map guards for the new profile/quote/invoice columns; add a round-trip persist test.
- Modify `test/quotes-send.test.ts` — rework to the link contract; drop the `GET /quotes/dl/:token` describe block.
- Modify `test/quotes-app.test.ts` — update the public-route assertion (`/q/*` not `/quotes/dl/*`).
- Delete `test/quotes-pdf.test.ts`, `test/pdfQuote.test.ts`.
- Create `test/quoteLink.test.ts` — `GET /q/:token` render + token verify tests.
- Create `test/profile-logo.test.ts` — logo upload route test.
- Create `test/quoteHtml.test.ts` — pure-render content assertions.

---

## Task 1: Migration 0010 — additive columns

**Files:**
- Create: `migrations/0010_quote_tax_business.sql`
- Test: `test/sync-push.test.ts` (existing; a later task adds assertions — this task only adds the migration, verified by the existing migration-apply path)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: D1 columns `profiles.gst_rate_bp` (INTEGER DEFAULT 1000), `profiles.business_email/phone/website/address/bank_details/logo_r2_key` (TEXT), `quotes.gst_rate_bp` (INTEGER, nullable), `invoices.gst_rate_bp` (INTEGER, nullable). The vitest config calls `readD1Migrations(migrations/)` so a new file is auto-collected; the test setup `applyD1Migrations` runs it.

- [ ] **Step 1: Write the migration file**

```sql
-- 0010_quote_tax_business.sql — configurable GST rate + business-profile details
-- + logo R2 key (spec §3, §5, §7). Forward-only. Pure additive ALTER TABLE ADD
-- COLUMN (non-rewriting in SQLite/D1).
--   • profiles: gst_rate_bp (default 1000 = 10%), business_email, phone, website,
--     address, bank_details, logo_r2_key (logo_r2_key is server-owned).
--   • quotes / invoices: gst_rate_bp (nullable; null ⇒ treated as 1000 = 10% by the
--     totals engine + the "GST (X%)" label, so pre-feature documents keep 10%).
-- Money = INTEGER cents. Timestamps = INTEGER epoch ms. Dates = TEXT 'YYYY-MM-DD'.
PRAGMA foreign_keys = OFF;

-- profiles — GST rate (basis points) + business details + logo key.
ALTER TABLE profiles ADD COLUMN gst_rate_bp   INTEGER DEFAULT 1000;
ALTER TABLE profiles ADD COLUMN business_email TEXT;
ALTER TABLE profiles ADD COLUMN phone          TEXT;
ALTER TABLE profiles ADD COLUMN website        TEXT;
ALTER TABLE profiles ADD COLUMN address        TEXT;
ALTER TABLE profiles ADD COLUMN bank_details   TEXT;
ALTER TABLE profiles ADD COLUMN logo_r2_key    TEXT;

-- quotes / invoices — snapshotted GST rate (nullable; null ⇒ 1000).
ALTER TABLE quotes   ADD COLUMN gst_rate_bp INTEGER;
ALTER TABLE invoices ADD COLUMN gst_rate_bp INTEGER;
```

- [ ] **Step 2: Run the full suite to verify the migration applies cleanly**

The migration is auto-collected by `readD1Migrations` and applied in every suite's `beforeAll(applyD1Migrations(...))`. A malformed `ALTER` breaks **all** suites at setup, so a green run proves it applies.

Run: `npm test -- test/sync-push.test.ts`
Expected: PASS (all existing assertions still pass; the new columns simply exist now).

- [ ] **Step 3: Commit**

```bash
git add migrations/0010_quote_tax_business.sql
git commit -m "feat(db): migration 0010 — configurable GST rate + business profile + logo columns

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Sync wiring — schema + table maps for the new columns

**Files:**
- Modify: `src/schemas/entities.ts` (add `quoteEntity`; extend `profileEntity` + `invoiceEntity`; register `quote` in `SPECIALIZED`)
- Modify: `src/lib/syncTables.ts` (extend the `profile`, `quote`, `invoice` column maps)
- Test: `test/schemas.test.ts`, `test/sync-push.test.ts`

**Interfaces:**
- Consumes: Task 1's D1 columns.
- Produces:
  - `quoteEntity` (new export from `src/schemas/entities.ts`) — zod schema, registered in `SPECIALIZED.quote`, so `entitySchemaFor("quote") === quoteEntity`.
  - Extended column maps: `tableForEntityType("profile").columns` includes `gstRateBp:"gst_rate_bp"`, `businessEmail:"business_email"`, `phone:"phone"`, `website:"website"`, `address:"address"`, `bankDetails:"bank_details"`, `logoR2Key:"logo_r2_key"`; `tableForEntityType("quote").columns.gstRateBp === "gst_rate_bp"`; `tableForEntityType("invoice").columns.gstRateBp === "gst_rate_bp"`.
  - `SYNCABLE_TYPES.length` is **unchanged at 18** (no new entity types) — do not touch `SYNCABLE_TYPES`.

- [ ] **Step 1: Write the failing schema test** (append inside `test/schemas.test.ts`, after the existing `describe("profileEntity / budgetEntity ...")` block)

```typescript
import { quoteEntity } from "../src/schemas/entities"; // add to the existing import block at top

describe("profile/quote/invoice GST + business fields (migration 0010)", () => {
  it("accepts a profile with gstRateBp + business details + logoR2Key", () => {
    const r = profileEntity.safeParse(
      env({
        type: "profile",
        profileId: undefined,
        name: "Acme Pty Ltd",
        profileType: "business",
        gstRateBp: 1500,
        businessEmail: "hi@acme.example",
        phone: "0400 000 000",
        website: "https://acme.example",
        address: "1 Main St\nSydney NSW 2000",
        bankDetails: "BSB 062-000\nAcc 1234 5678",
        logoR2Key: "u/x/profiles/p/logo",
      }),
    );
    expect(r.success).toBe(true);
  });

  it("rejects a non-integer gstRateBp on a profile", () => {
    expect(profileEntity.safeParse(env({ type: "profile", name: "X", profileType: "business", gstRateBp: 12.5 })).success).toBe(false);
  });

  it("accepts a quote carrying a snapshotted gstRateBp", () => {
    const r = quoteEntity.safeParse(env({ type: "quote", gstRateBp: 1000 }));
    expect(r.success).toBe(true);
  });

  it("accepts an invoice carrying a snapshotted gstRateBp", () => {
    const r = invoiceEntity.safeParse(env({ type: "invoice", gstRateBp: 1500 }));
    expect(r.success).toBe(true);
  });
});
```

Add `invoiceEntity` to the top-of-file import from `../src/schemas/entities` if it is not already imported there.

- [ ] **Step 2: Run it to confirm it fails**

Run: `npm test -- test/schemas.test.ts`
Expected: FAIL — `quoteEntity` is not exported (import error) and/or `gstRateBp` is stripped so the non-integer-rejection assertion fails (passthrough lets `12.5` through ⇒ `success` is `true`, but expected `false`).

- [ ] **Step 3: Extend `profileEntity` in `src/schemas/entities.ts`**

Replace the existing `profileEntity` block:

```typescript
/** profile — the user's switchable persona. (profileType avoids clashing with envelope.type) */
export const profileEntity = baseEnvelope.extend({
  type: z.literal("profile"),
  name: z.string().min(1),
  profileType: z.enum(["personal", "business"]),
  initials: z.string().nullable().optional(),
  accent1: z.string().optional(),
  accent2: z.string().optional(),
  accent3: z.string().optional(),
  abn: z.string().nullable().optional(),
  gstRegistered: z.boolean().optional(),
  sortOrder: z.number().int().optional(),
  isDefault: z.boolean().optional(),
  // Configurable GST rate (basis points) + business details + logo (migration 0010).
  // logoR2Key is server-owned (pull-only on iOS) but is mapped/validated like any column.
  gstRateBp: z.number().int().nonnegative().nullable().optional(),
  businessEmail: z.string().nullable().optional(),
  phone: z.string().nullable().optional(),
  website: z.string().nullable().optional(),
  address: z.string().nullable().optional(),
  bankDetails: z.string().nullable().optional(),
  logoR2Key: z.string().nullable().optional(),
});
```

- [ ] **Step 4: Add the `quoteEntity` schema in `src/schemas/entities.ts`**

Insert immediately before the `invoiceEntity` block (the `quote` type previously fell back to `baseEnvelope.passthrough()`; it now needs the snapshotted rate validated):

```typescript
/** quote — issued estimate (spec §4). Money in cents, dates date-only. gstRateBp is the
 *  snapshotted GST rate (basis points; null ⇒ treated as 1000 = 10%). */
export const quoteEntity = baseEnvelope.extend({
  type: z.literal("quote"),
  number: z.string().nullable().optional(),
  clientName: z.string().nullable().optional(),
  clientEmail: z.string().nullable().optional(),
  gstEnabled: z.boolean().optional(),
  gstInclusive: z.boolean().optional(),
  subtotalCents: cents.optional(),
  gstCents: cents.optional(),
  totalCents: cents.optional(),
  currency: z.string().length(3).optional(),
  status: z.enum(["draft", "sent", "accepted", "declined", "expired"]).optional(),
  validUntil: isoDate.nullable().optional(),
  sentAt: epochMs.nullable().optional(),
  pdfR2Key: z.string().nullable().optional(),
  invoiceId: uuid.nullable().optional(),
  gstRateBp: z.number().int().nonnegative().nullable().optional(),
});
```

- [ ] **Step 5: Add `gstRateBp` to `invoiceEntity` in `src/schemas/entities.ts`**

In the existing `invoiceEntity.extend({...})` body, add the field after `pdfR2Key`:

```typescript
  pdfR2Key: z.string().nullable().optional(),
  gstRateBp: z.number().int().nonnegative().nullable().optional(),
```

- [ ] **Step 6: Register `quote` in the `SPECIALIZED` map in `src/schemas/entities.ts`**

Add the `quote` entry to the `SPECIALIZED` object:

```typescript
const SPECIALIZED: Partial<Record<SyncableType, z.ZodTypeAny>> = {
  transaction: transactionEntity,
  lineItem: lineItemEntity,
  profile: profileEntity,
  budget: budgetEntity,
  loyaltyCard: loyaltyCardEntity,
  vehicle: vehicleEntity,
  vehicleYear: vehicleYearEntity,
  quote: quoteEntity,
  invoice: invoiceEntity,
  invoiceLineItem: invoiceLineItemEntity,
  payment: paymentEntity,
};
```

- [ ] **Step 7: Run the schema test to confirm it passes**

Run: `npm test -- test/schemas.test.ts`
Expected: PASS.

- [ ] **Step 8: Write the failing table-map guard** (append inside the `describe("syncable table map", ...)` block in `test/sync-push.test.ts`)

```typescript
  it("maps the new profile GST + business columns (migration 0010)", () => {
    const p = tableForEntityType("profile")!;
    expect(p.columns.gstRateBp).toBe("gst_rate_bp");
    expect(p.columns.businessEmail).toBe("business_email");
    expect(p.columns.phone).toBe("phone");
    expect(p.columns.website).toBe("website");
    expect(p.columns.address).toBe("address");
    expect(p.columns.bankDetails).toBe("bank_details");
    expect(p.columns.logoR2Key).toBe("logo_r2_key");
  });

  it("maps the new quote + invoice gstRateBp columns (migration 0010)", () => {
    expect(tableForEntityType("quote")!.columns.gstRateBp).toBe("gst_rate_bp");
    expect(tableForEntityType("invoice")!.columns.gstRateBp).toBe("gst_rate_bp");
  });
```

- [ ] **Step 9: Run it to confirm it fails**

Run: `npm test -- test/sync-push.test.ts`
Expected: FAIL — `p.columns.gstRateBp` is `undefined` (`.toBe("gst_rate_bp")` fails).

- [ ] **Step 10: Extend the `profile` column map in `src/lib/syncTables.ts`**

In `SYNCABLE_TABLES.profile.columns`, after `isDefault: "is_default",` add:

```typescript
      isDefault: "is_default",
      // Migration 0010: configurable GST rate + business details + logo key.
      gstRateBp: "gst_rate_bp",
      businessEmail: "business_email",
      phone: "phone",
      website: "website",
      address: "address",
      bankDetails: "bank_details",
      logoR2Key: "logo_r2_key",
```

- [ ] **Step 11: Extend the `quote` column map in `src/lib/syncTables.ts`**

In `SYNCABLE_TABLES.quote.columns`, after `invoiceId: "invoice_id",` add:

```typescript
      invoiceId: "invoice_id",
      gstRateBp: "gst_rate_bp",
```

- [ ] **Step 12: Extend the `invoice` column map in `src/lib/syncTables.ts`**

In `SYNCABLE_TABLES.invoice.columns`, after `pdfR2Key: "pdf_r2_key",` add:

```typescript
      pdfR2Key: "pdf_r2_key",
      gstRateBp: "gst_rate_bp",
```

- [ ] **Step 13: Write a round-trip persist test** (append inside the `describe(...)` push block in `test/sync-push.test.ts` that seeds a profile — mirror an existing profile-upsert test; this one upserts the new columns and reads them back)

```typescript
  it("persists the new profile GST + business columns through a push upsert", async () => {
    const profileId = uuidv7();
    const mutation = {
      mutationId: uuidv7(),
      entityType: "profile",
      op: "upsert",
      payload: {
        id: profileId,
        userId: USER_ID,
        type: "profile",
        name: "Acme Pty Ltd",
        profileType: "business",
        accent1: "#0E7C72",
        accent2: "#DCF0ED",
        accent3: "#0A5950",
        gstRateBp: 1500,
        businessEmail: "hi@acme.example",
        phone: "0400 000 000",
        website: "https://acme.example",
        address: "1 Main St",
        bankDetails: "BSB 062-000 Acc 1234 5678",
        logoR2Key: "u/x/profiles/p/logo",
        createdAt: nowMs(),
        updatedAt: nowMs(),
        rev: 0,
      },
    };
    const res = await SELF.fetch(`${BASE}/sync/push`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: JSON.stringify({ deviceId: DEVICE_ID, mutations: [mutation] }),
    });
    expect(res.status).toBe(200);

    const row = await env.DB.prepare(
      `SELECT gst_rate_bp, business_email, phone, website, address, bank_details, logo_r2_key
         FROM profiles WHERE id = ?`,
    ).bind(profileId).first<any>();
    expect(row.gst_rate_bp).toBe(1500);
    expect(row.business_email).toBe("hi@acme.example");
    expect(row.bank_details).toBe("BSB 062-000 Acc 1234 5678");
    expect(row.logo_r2_key).toBe("u/x/profiles/p/logo");
  });
```

> Note: match this test's local names (`USER_ID`, `DEVICE_ID`, `accessToken`, `PROFILE_ID`, `BASE`) to whatever the surrounding `describe` block in `sync-push.test.ts` already defines for its seeded user/device. If the block names them differently, use those — do not introduce new fixtures.

- [ ] **Step 14: Run the sync-push suite to confirm all pass**

Run: `npm test -- test/sync-push.test.ts`
Expected: PASS (the two map guards + the round-trip test + all existing tests).

- [ ] **Step 15: Commit**

```bash
git add src/schemas/entities.ts src/lib/syncTables.ts test/schemas.test.ts test/sync-push.test.ts
git commit -m "feat(sync): wire gstRateBp + business-profile + logo columns into schema and table maps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: quoteTotals — gstRateBp parameter

**Files:**
- Modify: `src/lib/quoteTotals.ts`
- Test: `test/quoteTotals.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces: updated signature
  `recomputeTotals(lineItems: QuoteLineItemAmounts[], gstEnabled: boolean, gstInclusive?: boolean, gstRateBp?: number | null): QuoteTotals`.
  `gstRateBp` is the 4th param; `null`/`undefined` ⇒ `1000`. Existing 3-arg callers keep 10% behaviour. `QuoteTotals` / `QuoteLineItemAmounts` interfaces are unchanged.

- [ ] **Step 1: Write the failing tests** (append inside the existing `describe("recomputeTotals", ...)` block in `test/quoteTotals.test.ts`)

```typescript
  describe("configurable gstRateBp", () => {
    it("defaults a null/absent rate to 10% (1000 bp)", () => {
      const t = recomputeTotals(lines([1, 10000]), true, false, null);
      expect(t.gstCents).toBe(1000);
      expect(t.totalCents).toBe(11000);
    });

    it("applies 15% exclusive (NZ) when gstRateBp=1500", () => {
      const t = recomputeTotals(lines([1, 10000]), true, false, 1500);
      expect(t.subtotalCents).toBe(10000);
      expect(t.gstCents).toBe(1500); // round(10000 * 1500 / 10000)
      expect(t.totalCents).toBe(11500);
    });

    it("applies 15% inclusive when gstRateBp=1500", () => {
      // gross = 11500; gst = round(11500 * 1500 / (10000+1500)) = round(11500*1500/11500) = 1500.
      const t = recomputeTotals(lines([1, 11500]), true, true, 1500);
      expect(t.totalCents).toBe(11500);
      expect(t.gstCents).toBe(1500);
      expect(t.subtotalCents).toBe(10000);
      expect(t.subtotalCents + t.gstCents).toBe(t.totalCents);
    });

    it("applies a custom 12.5% (1250 bp) exclusive", () => {
      const t = recomputeTotals(lines([1, 10000]), true, false, 1250);
      expect(t.gstCents).toBe(1250); // round(10000 * 1250 / 10000)
      expect(t.totalCents).toBe(11250);
    });

    it("applies a custom 12.5% (1250 bp) inclusive", () => {
      // gross = 22500; gst = round(22500 * 1250 / 11250) = round(2500.0) = 2500.
      const t = recomputeTotals(lines([1, 22500]), true, true, 1250);
      expect(t.totalCents).toBe(22500);
      expect(t.gstCents).toBe(2500);
      expect(t.subtotalCents).toBe(20000);
    });
  });
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `npm test -- test/quoteTotals.test.ts`
Expected: FAIL — the 15%/12.5% cases compute 10% (e.g. `gstCents` is `1000`, not `1500`).

- [ ] **Step 3: Rewrite `src/lib/quoteTotals.ts`**

Replace the whole file:

```typescript
/**
 * Pure quote-totals recompute (spec §3). The send/link/HTML routes call this to
 * recompute totals authoritatively from the persisted line items. iOS computes the
 * identical formula on-device (`Snapceipt/Features/Quotes/QuoteTotals.swift`); this
 * is the server's source of truth — keep the two in lock-step.
 *
 * `gross = Σ(quantity × unitPriceCents)`. GST rate is basis points (bp): 1000 = 10%,
 * 1500 = 15%, 1250 = 12.5%. A null/absent rate is treated as 1000 (10%). With GST
 * enabled, two modes:
 *   • exclusive (gstInclusive === false): entered prices are ex-GST, GST added on top —
 *     subtotal = gross, gst = round(gross × bp / 10000), total = gross + gst.
 *   • inclusive (gstInclusive === true): entered prices already contain GST —
 *     total = gross, gst = round(gross × bp / (10000 + bp)), subtotal = gross − gst.
 * The invariant subtotalCents + gstCents === totalCents holds in every mode;
 * subtotalCents is always the ex-GST base and gstCents the tax component. At bp=1000
 * these reduce to the historical ×0.10 / ×0.10/1.10 behaviour.
 */

/** Default GST rate in basis points (10% AU GST) when a rate is null/absent. */
export const DEFAULT_GST_RATE_BP = 1000;

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
  gstInclusive = false,
  gstRateBp: number | null = DEFAULT_GST_RATE_BP,
): QuoteTotals {
  const bp = gstRateBp ?? DEFAULT_GST_RATE_BP;
  let gross = 0;
  for (const li of lineItems) {
    gross += li.quantity * li.unitPriceCents;
  }
  if (!gstEnabled) {
    return { subtotalCents: gross, gstCents: 0, totalCents: gross };
  }
  if (gstInclusive) {
    // GST embedded in `gross`: gross × bp / (10000 + bp).
    const gstCents = Math.round((gross * bp) / (10000 + bp));
    return { subtotalCents: gross - gstCents, gstCents, totalCents: gross };
  }
  const gstCents = Math.round((gross * bp) / 10000);
  return { subtotalCents: gross, gstCents, totalCents: gross + gstCents };
}
```

- [ ] **Step 4: Run the quoteTotals test to confirm it passes**

Run: `npm test -- test/quoteTotals.test.ts`
Expected: PASS (existing 10% tests + the new rate tests).

- [ ] **Step 5: Confirm no caller regressed**

`src/routes/quotes.ts` and `src/routes/invoices.ts` call `recomputeTotals(...)` with 3 args (defaults to 10%) — unchanged behaviour. Run the wider quote/invoice suites:

Run: `npm test -- test/quotes-send.test.ts test/invoices-send-pdf.test.ts test/invoiceTotals.test.ts`
Expected: PASS (these still pass at the default 10% — none pass a 4th arg yet).

- [ ] **Step 6: Commit**

```bash
git add src/lib/quoteTotals.ts test/quoteTotals.test.ts
git commit -m "feat(totals): add gstRateBp parameter to recomputeTotals (10%/15%/custom, bp math)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Quote-link token (90-day) in exportToken.ts

**Files:**
- Modify: `src/lib/exportToken.ts`
- Test: `test/exportToken.test.ts`

**Interfaces:**
- Consumes: `env.JWT_SIGNING_KEY` (HS256 key string).
- Produces:
  - `QUOTE_LINK_TTL_SECONDS = 90 * 24 * 60 * 60`.
  - `signQuoteLinkToken(signingKey: string, quoteId: string, userId: string, ttlSeconds?: number): Promise<string>` — claims `qid`, `uid`; distinct issuer/audience; HS256.
  - `verifyQuoteLinkToken(signingKey: string, token: string): Promise<{ quoteId: string; userId: string }>` — throws on signature/expiry/missing-claim.

- [ ] **Step 1: Write the failing test** (append to `test/exportToken.test.ts`)

```typescript
import { signQuoteLinkToken, verifyQuoteLinkToken, QUOTE_LINK_TTL_SECONDS } from "../src/lib/exportToken";

const KEY = "test-signing-key-0123456789-abcdefghijklmnop";

describe("quote-link token", () => {
  it("round-trips quoteId + userId", async () => {
    const token = await signQuoteLinkToken(KEY, "quote-1", "user-1");
    const out = await verifyQuoteLinkToken(KEY, token);
    expect(out).toEqual({ quoteId: "quote-1", userId: "user-1" });
  });

  it("uses a 90-day TTL", () => {
    expect(QUOTE_LINK_TTL_SECONDS).toBe(90 * 24 * 60 * 60);
  });

  it("rejects an expired token", async () => {
    const token = await signQuoteLinkToken(KEY, "quote-1", "user-1", -10);
    await expect(verifyQuoteLinkToken(KEY, token)).rejects.toThrow();
  });

  it("rejects a forged token", async () => {
    await expect(verifyQuoteLinkToken(KEY, "not.a.token")).rejects.toThrow();
  });

  it("rejects a download token replayed as a quote-link token (distinct audience)", async () => {
    const { signDownloadToken } = await import("../src/lib/exportToken");
    const dl = await signDownloadToken(KEY, "u/x/quotes/y.pdf");
    await expect(verifyQuoteLinkToken(KEY, dl)).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `npm test -- test/exportToken.test.ts`
Expected: FAIL — `signQuoteLinkToken` is not exported (import error).

- [ ] **Step 3: Add the quote-link token functions to `src/lib/exportToken.ts`**

Append at the end of the file (keep the existing `signDownloadToken`/`verifyDownloadToken` — they still serve `/invoices/dl`):

```typescript
/**
 * Signed token for the PUBLIC GET /q/:token HTML-quote page. Carries `qid` (quote id)
 * + `uid` (owning user id) so the route can load + tenant-scope the quote without an
 * access token. Long-lived (90 days) — a client may open the link days later. Signed
 * HS256 with the same JWT_SIGNING_KEY but a DISTINCT issuer/audience from both the
 * access token and the download token, so no token can be replayed across surfaces.
 */
export const QUOTE_LINK_TTL_SECONDS = 90 * 24 * 60 * 60; // 90 days
const QUOTE_LINK_ISSUER = "snapceipt-quote";
const QUOTE_LINK_AUDIENCE = "snapceipt-quote-link";

/** Sign a quote-link token. `ttlSeconds` defaults to 90 days; a negative value lets
 *  tests mint an already-expired token. */
export async function signQuoteLinkToken(
  signingKey: string,
  quoteId: string,
  userId: string,
  ttlSeconds: number = QUOTE_LINK_TTL_SECONDS,
): Promise<string> {
  return new SignJWT({ qid: quoteId, uid: userId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(QUOTE_LINK_ISSUER)
    .setAudience(QUOTE_LINK_AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(`${ttlSeconds}s`)
    .sign(keyBytes(signingKey));
}

/** Verify a quote-link token. Throws (jose JWTExpired / signature / claim error) on
 *  any failure — the route maps a throw to 403. */
export async function verifyQuoteLinkToken(
  signingKey: string,
  token: string,
): Promise<{ quoteId: string; userId: string }> {
  const { payload } = await jwtVerify(token, keyBytes(signingKey), {
    issuer: QUOTE_LINK_ISSUER,
    audience: QUOTE_LINK_AUDIENCE,
    algorithms: ["HS256"],
  });
  const qid = (payload as { qid?: unknown }).qid;
  const uid = (payload as { uid?: unknown }).uid;
  if (typeof qid !== "string" || qid.length === 0 || typeof uid !== "string" || uid.length === 0) {
    throw new Error("quote-link token missing qid/uid claim");
  }
  return { quoteId: qid, userId: uid };
}
```

- [ ] **Step 4: Run the token test to confirm it passes**

Run: `npm test -- test/exportToken.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/exportToken.ts test/exportToken.test.ts
git commit -m "feat(token): add 90-day signed quote-link token (qid/uid, distinct audience)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Pure HTML quote template

**Files:**
- Create: `src/lib/quoteHtml.ts`
- Test: `test/quoteHtml.test.ts`

**Interfaces:**
- Consumes: nothing (pure function).
- Produces:
  - `interface QuoteHtmlData { number: string | null; issuedDate: string; validUntil: string | null; clientName: string | null; clientEmail: string | null; gstEnabled: boolean; gstInclusive: boolean; gstRateBp: number | null; subtotalCents: number; gstCents: number; totalCents: number; business: QuoteHtmlBusiness; lineItems: QuoteHtmlLineItem[]; logoDataUri: string | null; appUrl: string; }`
  - `interface QuoteHtmlBusiness { name: string; abn: string | null; businessEmail: string | null; phone: string | null; website: string | null; address: string | null; bankDetails: string | null; }`
  - `interface QuoteHtmlLineItem { description: string; quantity: number; unitPriceCents: number; }`
  - `renderQuoteHtml(data: QuoteHtmlData): string` — returns a full `<!doctype html>…</html>` string (inline CSS). `gstRateBp` null ⇒ label "GST (10%)".

- [ ] **Step 1: Write the failing test** (`test/quoteHtml.test.ts`)

```typescript
import { describe, expect, it } from "vitest";
import { renderQuoteHtml, type QuoteHtmlData } from "../src/lib/quoteHtml";

function data(overrides: Partial<QuoteHtmlData> = {}): QuoteHtmlData {
  return {
    number: "SN-0001",
    issuedDate: "2026-06-20",
    validUntil: "2026-07-04",
    clientName: "Jane Roe",
    clientEmail: "jane@example.com",
    gstEnabled: true,
    gstInclusive: false,
    gstRateBp: 1500,
    subtotalCents: 10000,
    gstCents: 1500,
    totalCents: 11500,
    business: {
      name: "Acme Pty Ltd",
      abn: "12 345 678 901",
      businessEmail: "hi@acme.example",
      phone: "0400 000 000",
      website: "https://acme.example",
      address: "1 Main St\nSydney NSW 2000",
      bankDetails: "BSB 062-000\nAcc 1234 5678",
    },
    lineItems: [{ description: "Site inspection", quantity: 1, unitPriceCents: 10000 }],
    logoDataUri: "data:image/png;base64,AAAA",
    appUrl: "https://snapceipt.cc",
    ...overrides,
  };
}

describe("renderQuoteHtml", () => {
  it("renders a full HTML document with the business header fields", () => {
    const html = renderQuoteHtml(data());
    expect(html.startsWith("<!doctype html>")).toBe(true);
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("12 345 678 901");
    expect(html).toContain("hi@acme.example");
    expect(html).toContain("0400 000 000");
    expect(html).toContain("acme.example");
  });

  it("labels the GST line with the document rate (15%)", () => {
    expect(renderQuoteHtml(data())).toContain("GST (15%)");
  });

  it("labels GST as 10% when the rate is null", () => {
    expect(renderQuoteHtml(data({ gstRateBp: null, gstCents: 1000, totalCents: 11000 }))).toContain("GST (10%)");
  });

  it("shows the quote number, bill-to, and money formatted as dollars", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("SN-0001");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("$115.00"); // total 11500c
  });

  it("inlines the logo data-URI in an <img>", () => {
    expect(renderQuoteHtml(data())).toContain("data:image/png;base64,AAAA");
  });

  it("renders the payment-details block when bankDetails is set", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("Payment details");
    expect(html).toContain("BSB 062-000");
  });

  it("omits the payment-details block when bankDetails is null", () => {
    const b = data().business;
    const html = renderQuoteHtml(data({ business: { ...b, bankDetails: null } }));
    expect(html).not.toContain("Payment details");
  });

  it("includes the Made-with-Snapceipt badge linking to the app", () => {
    const html = renderQuoteHtml(data());
    expect(html).toContain("Made with Snapceipt");
    expect(html).toContain("https://snapceipt.cc");
  });

  it("escapes HTML in user fields (no script injection)", () => {
    const html = renderQuoteHtml(data({ clientName: "<script>alert(1)</script>" }));
    expect(html).not.toContain("<script>alert(1)</script>");
    expect(html).toContain("&lt;script&gt;");
  });

  it("hides the GST line entirely when gstEnabled is false", () => {
    const html = renderQuoteHtml(data({ gstEnabled: false, gstCents: 0, totalCents: 10000 }));
    expect(html).not.toContain("GST (");
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `npm test -- test/quoteHtml.test.ts`
Expected: FAIL — module `../src/lib/quoteHtml` not found.

- [ ] **Step 3: Create `src/lib/quoteHtml.ts`**

```typescript
/**
 * Pure server-rendered HTML quote page (spec §4). Self-contained: inline CSS,
 * mobile-responsive + print-friendly, no external assets (the logo is inlined as a
 * data-URI by the caller). Rendered on the fly by GET /q/:token so it always reflects
 * the live quote. Totals are recomputed by the route and passed in. iOS loads the same
 * URL in a hidden WKWebView and renders it to PDF on demand.
 */

export interface QuoteHtmlBusiness {
  name: string;
  abn: string | null;
  businessEmail: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  bankDetails: string | null;
}

export interface QuoteHtmlLineItem {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

export interface QuoteHtmlData {
  number: string | null;
  /** YYYY-MM-DD issued date. */
  issuedDate: string;
  validUntil: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  gstInclusive: boolean;
  /** Basis points; null ⇒ label "GST (10%)". */
  gstRateBp: number | null;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  business: QuoteHtmlBusiness;
  lineItems: QuoteHtmlLineItem[];
  /** data:image/...;base64,... or null when no logo. */
  logoDataUri: string | null;
  /** App link for the footer badge. */
  appUrl: string;
}

const DEFAULT_GST_RATE_BP = 1000;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/** Format a basis-point rate as a percent string ("15", "12.5", "10"). */
function ratePct(bp: number | null): string {
  const v = (bp ?? DEFAULT_GST_RATE_BP) / 100;
  return Number.isInteger(v) ? String(v) : String(v);
}

/** HTML-escape a string (text + attribute safe). null/undefined ⇒ "". */
function esc(s: string | null | undefined): string {
  if (s == null) return "";
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Escape then turn newlines into <br> for multiline fields (address, bank details). */
function escMultiline(s: string | null | undefined): string {
  return esc(s).replace(/\n/g, "<br>");
}

export function renderQuoteHtml(data: QuoteHtmlData): string {
  const b = data.business;
  const inclusive = data.gstEnabled && data.gstInclusive;

  const logo = data.logoDataUri
    ? `<img class="logo" src="${esc(data.logoDataUri)}" alt="${esc(b.name)} logo">`
    : "";

  const contactLines: string[] = [];
  if (b.abn) contactLines.push(`ABN ${esc(b.abn)}`);
  if (b.businessEmail) contactLines.push(esc(b.businessEmail));
  if (b.phone) contactLines.push(esc(b.phone));
  if (b.website) contactLines.push(esc(b.website));
  const contactHtml = contactLines.length ? `<div class="muted">${contactLines.join(" &middot; ")}</div>` : "";
  const addressHtml = b.address ? `<div class="muted">${escMultiline(b.address)}</div>` : "";

  const rows = data.lineItems
    .map((li) => {
      const amount = li.quantity * li.unitPriceCents;
      return `<tr>
        <td>${esc(li.description)}</td>
        <td class="num">${li.quantity}</td>
        <td class="num">${dollars(li.unitPriceCents)}</td>
        <td class="num">${dollars(amount)}</td>
      </tr>`;
    })
    .join("");

  const gstLine = data.gstEnabled
    ? `<tr><td>GST (${esc(ratePct(data.gstRateBp))}%)${inclusive ? " incl." : ""}</td><td class="num">${dollars(data.gstCents)}</td></tr>`
    : "";

  const validNote = data.validUntil
    ? `<p class="muted small">Valid until ${esc(data.validUntil)}. Accepted quotes convert to a tax invoice.</p>`
    : `<p class="muted small">Accepted quotes convert to a tax invoice.</p>`;

  const paymentBlock = b.bankDetails
    ? `<section class="card">
        <h2>Payment details</h2>
        <div class="muted">${escMultiline(b.bankDetails)}</div>
      </section>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quote ${esc(data.number ?? "")} — ${esc(b.name)}</title>
<style>
  :root { --ink:#111827; --muted:#6b7280; --line:#e5e7eb; --brand:#0E7C72; }
  * { box-sizing: border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
         color:var(--ink); background:#f3f4f6; line-height:1.5; }
  .page { max-width:760px; margin:24px auto; background:#fff; padding:40px;
          border-radius:12px; box-shadow:0 1px 4px rgba(0,0,0,.06); }
  .head { display:flex; justify-content:space-between; align-items:flex-start; gap:24px; flex-wrap:wrap; }
  .logo { max-height:64px; max-width:200px; object-fit:contain; }
  h1 { font-size:22px; margin:0 0 2px; }
  h2 { font-size:14px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:0 0 8px; }
  .muted { color:var(--muted); font-size:14px; }
  .small { font-size:12px; }
  .meta { text-align:right; }
  .meta .big { font-size:20px; font-weight:600; }
  .card { margin-top:28px; padding-top:20px; border-top:1px solid var(--line); }
  table { width:100%; border-collapse:collapse; margin-top:8px; font-size:14px; }
  th, td { padding:8px 6px; text-align:left; border-bottom:1px solid var(--line); }
  th { color:var(--muted); font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.03em; }
  .num { text-align:right; white-space:nowrap; }
  .totals { width:100%; max-width:280px; margin-left:auto; margin-top:12px; font-size:14px; }
  .totals td { border:none; padding:4px 6px; }
  .totals tr.total td { border-top:2px solid var(--ink); font-weight:700; font-size:16px; padding-top:8px; }
  .badge { margin-top:32px; text-align:center; }
  .badge a { color:var(--brand); text-decoration:none; font-size:12px; }
  @media print { body { background:#fff; } .page { box-shadow:none; margin:0; max-width:none; border-radius:0; } }
</style>
</head>
<body>
  <div class="page">
    <header class="head">
      <div>
        ${logo}
        <h1>${esc(b.name)}</h1>
        ${contactHtml}
        ${addressHtml}
      </div>
      <div class="meta">
        <div class="big">Quote ${esc(data.number ?? "")}</div>
        <div class="muted">Issued ${esc(data.issuedDate)}</div>
      </div>
    </header>

    <section class="card">
      <h2>Bill to</h2>
      <div>${esc(data.clientName ?? "")}</div>
      ${data.clientEmail ? `<div class="muted">${esc(data.clientEmail)}</div>` : ""}
    </section>

    <section class="card">
      <h2>Items</h2>
      <table>
        <thead><tr><th>Description</th><th class="num">Qty</th><th class="num">Unit</th><th class="num">Amount</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <table class="totals">
        <tr><td>${inclusive ? "Subtotal (ex GST)" : "Subtotal"}</td><td class="num">${dollars(data.subtotalCents)}</td></tr>
        ${gstLine}
        <tr class="total"><td>Total</td><td class="num">${dollars(data.totalCents)}</td></tr>
      </table>
      ${inclusive ? `<p class="muted small">Prices include GST.</p>` : ""}
      ${validNote}
    </section>

    ${paymentBlock}

    <div class="badge"><a href="${esc(data.appUrl)}">Made with Snapceipt</a></div>
  </div>
</body>
</html>`;
}
```

- [ ] **Step 4: Run the HTML test to confirm it passes**

Run: `npm test -- test/quoteHtml.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/quoteHtml.ts test/quoteHtml.test.ts
git commit -m "feat(quote): self-contained HTML quote template (inline CSS, print-friendly, escaped)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: POST /profile/logo — store the logo to R2

**Files:**
- Create: `src/routes/profile.ts`
- Modify: `src/app.ts` (mount `/profile` + rate limiter)
- Test: `test/profile-logo.test.ts`

**Interfaces:**
- Consumes: `c.var.userId` (auth middleware), `c.env.RECEIPTS` (R2), `c.env.DB`.
- Produces: `profileRoutes` (Hono group). Route:
  - **`POST /profile/logo`** — auth-gated. Request: raw image bytes (`Content-Type: image/png` or `image/jpeg`), `?profileId=<uuid>` query param. Response `200`: `{ "logoR2Key": "<userId>/profiles/<profileId>/logo", "ok": true }`. Errors: `400 VALIDATION_FAILED` (bad/missing content-type, empty/oversize body, missing `profileId`), `404 NOT_FOUND` (profile not owned by user). Side effects: `RECEIPTS.put(key, bytes, { httpMetadata })` + `UPDATE profiles SET logo_r2_key = ?, updated_at = ? WHERE id = ? AND user_id = ?`.

- [ ] **Step 1: Write the failing test** (`test/profile-logo.test.ts`)

```typescript
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
  return { userId, accessToken };
}

async function seedProfile(userId: string) {
  const profileId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
     VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
  ).bind(profileId, userId, now, now).run();
  return profileId;
}

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]); // PNG magic

describe("POST /profile/logo", () => {
  it("stores the logo to R2 and sets logo_r2_key", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = await seedProfile(userId);

    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.ok).toBe(true);
    expect(body.logoR2Key).toBe(`${userId}/profiles/${profileId}/logo`);

    const row = await env.DB.prepare(`SELECT logo_r2_key FROM profiles WHERE id=?`).bind(profileId).first<any>();
    expect(row.logo_r2_key).toBe(`${userId}/profiles/${profileId}/logo`);

    const obj = await env.RECEIPTS.get(`${userId}/profiles/${profileId}/logo`);
    expect(obj).not.toBeNull();
  });

  it("400 on a non-image content-type", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = await seedProfile(userId);
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "text/plain" },
      body: "x",
    });
    expect(res.status).toBe(400);
  });

  it("400 when profileId is missing", async () => {
    const { accessToken } = await seedAuthed();
    const res = await SELF.fetch(`${BASE}/profile/logo`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(400);
  });

  it("404 for a profile owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const profileId = await seedProfile(other.userId);
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=${profileId}`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(404);
  });

  it("401 without a bearer token", async () => {
    const res = await SELF.fetch(`${BASE}/profile/logo?profileId=x`, {
      method: "POST",
      headers: { "content-type": "image/png" },
      body: PNG,
    });
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `npm test -- test/profile-logo.test.ts`
Expected: FAIL — `POST /profile/logo` is not mounted (likely 404/401 mismatches; the success case 200 fails).

- [ ] **Step 3: Create `src/routes/profile.ts`**

```typescript
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";

/**
 * Business-profile asset routes.
 *   POST /profile/logo?profileId=<uuid> — raw image bytes (image/png|jpeg); writes to
 *   R2 at <userId>/profiles/<profileId>/logo and sets profiles.logo_r2_key. The HTML
 *   quote (GET /q/:token) later inlines this object as a data-URI. Auth-gated by the
 *   global middleware (c.var.userId is set).
 */
export const profileRoutes = new Hono<AppEnv>();

const MAX_LOGO_BYTES = 4_194_304; // 4 MiB
const ALLOWED = ["image/png", "image/jpeg"];

profileRoutes.post("/logo", async (c) => {
  const userId = c.var.userId;

  const profileId = c.req.query("profileId");
  if (!profileId) throw new ApiError("VALIDATION_FAILED", "Missing profileId");

  const contentType = (c.req.header("content-type") ?? "").split(";")[0]!.trim();
  if (!ALLOWED.includes(contentType)) {
    throw new ApiError("VALIDATION_FAILED", "Expected Content-Type: image/png or image/jpeg");
  }

  const buf = await c.req.arrayBuffer();
  if (buf.byteLength === 0) throw new ApiError("VALIDATION_FAILED", "Empty image body");
  if (buf.byteLength > MAX_LOGO_BYTES) {
    throw new ApiError("VALIDATION_FAILED", `Logo exceeds ${MAX_LOGO_BYTES} bytes`);
  }

  // Tenancy: the profile must belong to the authed user.
  const owned = await c.env.DB.prepare(
    `SELECT 1 FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(profileId, userId).first<{ 1: number }>();
  if (!owned) throw new ApiError("NOT_FOUND", "Profile not found for this user");

  const key = `${userId}/profiles/${profileId}/logo`;
  await c.env.RECEIPTS.put(key, buf, { httpMetadata: { contentType } });

  await c.env.DB.prepare(
    `UPDATE profiles SET logo_r2_key = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
  ).bind(key, nowMs(), profileId, userId).run();

  return c.json({ logoR2Key: key, ok: true });
});
```

- [ ] **Step 4: Mount the route + rate limiter in `src/app.ts`**

Add the import alongside the others near the top:

```typescript
import { profileRoutes } from "./routes/profile";
```

Add the rate limiter (after the `/profiles/*` inbox limiter line `app.use("/profiles/*", rateLimit("inbox"));`):

```typescript
// Business-profile asset upload (logo) — default tier. Auth-gated (NOT in PUBLIC_PATHS).
// Mount on BOTH the exact path AND the wildcard so the POST is limited.
app.use("/profile", rateLimit("default"));
app.use("/profile/*", rateLimit("default"));
```

Add the route mount (near the other `app.route(...)` calls, e.g. after the `inboxRoutes` mount):

```typescript
// Protected: business-profile assets (POST /profile/logo -> R2 + logo_r2_key).
app.route("/profile", profileRoutes);
```

> Note: `/profile` is distinct from the existing `/profiles` (inbox alias) prefix and is **not** in `PUBLIC_PATHS`, so the global auth middleware guards it.

- [ ] **Step 5: Run the logo test to confirm it passes**

Run: `npm test -- test/profile-logo.test.ts`
Expected: PASS (all five cases).

- [ ] **Step 6: Commit**

```bash
git add src/routes/profile.ts src/app.ts test/profile-logo.test.ts
git commit -m "feat(profile): POST /profile/logo — store business logo to R2 + set logo_r2_key

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Shared quote loader + GET /q/:token (public HTML page) + POST /quotes/:id/link

**Files:**
- Modify: `src/routes/quotes.ts` (add `loadQuoteForRender` helper + `POST /:id/link`)
- Create: `src/routes/quoteLink.ts` (public `GET /q/:token`)
- Modify: `src/middleware/auth.ts` (add `/q/` to `PUBLIC_PATHS`)
- Modify: `src/app.ts` (mount `/q` public + rate limiter)
- Test: `test/quoteLink.test.ts`

**Interfaces:**
- Consumes: `verifyQuoteLinkToken` + `signQuoteLinkToken` + `QUOTE_LINK_TTL_SECONDS` (Task 4), `renderQuoteHtml` + types (Task 5), `recomputeTotals` (Task 3), `c.env.DB` / `c.env.RECEIPTS`.
- Produces:
  - Exported helper from `src/routes/quotes.ts`:
    `loadQuoteForRender(env: Env, quoteId: string, userId: string): Promise<QuoteHtmlData | null>` — loads quote + line items + profile, recomputes totals at the quote's `gst_rate_bp` (fallback 1000), inlines the R2 logo as a data-URI, returns `QuoteHtmlData` or `null` if the quote/profile is missing or has no line items. (`appUrl` = `"https://snapceipt.cc"`.)
  - **`POST /quotes/:id/link`** — auth-gated. Request body: ignored (`{}`). Response `200`: `{ "url": "https://api.snapceipt.cc/q/<token>", "number": "SN-####" }`. Mints the quote number if absent (via `assignQuoteNumber`), then returns both `url` and `number`. Sharing a link "issues" the quote so the HTML page can show "Quote #N". Errors: `404 NOT_FOUND` (quote not owned / missing), `400 VALIDATION_FAILED` (no line items).
  - **`GET /q/:token`** (public, in `quoteLinkRoutes`) — Response `200 text/html` (the rendered page) for a valid token whose quote loads; `403` for a bad/expired token; `404` for a valid token whose quote no longer exists or has no line items.

- [ ] **Step 1: Write the failing test** (`test/quoteLink.test.ts`)

```typescript
import { env, SELF, applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import { uuidv7 } from "../src/lib/ids";
import { nowMs } from "../src/lib/time";
import { issueSession } from "../src/lib/sessions";
import { signQuoteLinkToken } from "../src/lib/exportToken";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    TEST_MIGRATIONS: Parameters<typeof applyD1Migrations>[1];
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.DB.exec("DELETE FROM quote_line_items");
  await env.DB.exec("DELETE FROM quotes");
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
  return { userId, accessToken };
}

/** Seed a business profile (15% GST + bank details) + a quote (gst_rate_bp snapshot) + 1 line item. */
async function seedQuote(userId: string, opts: { gstRateBp?: number | null; bankDetails?: string | null } = {}) {
  const profileId = uuidv7();
  const quoteId = uuidv7();
  const now = nowMs();
  await env.DB.prepare(
    `INSERT INTO profiles (id,user_id,name,type,abn,gst_registered,accent_1,accent_2,accent_3,business_email,phone,website,address,bank_details,created_at,updated_at)
     VALUES (?,?,'Acme Pty Ltd','business','12 345 678 901',1,'#0E7C72','#DCF0ED','#0A5950','hi@acme.example','0400 000 000','https://acme.example','1 Main St',?,?,?)`,
  ).bind(profileId, userId, opts.bankDetails === undefined ? "BSB 062-000 Acc 1234 5678" : opts.bankDetails, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,number,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'SN-0001','Jane Roe','jane@example.com',1,0,?, 'draft','2026-07-04',?,?)`,
  ).bind(quoteId, userId, profileId, opts.gstRateBp === undefined ? 1500 : opts.gstRateBp, now, now).run();
  await env.DB.prepare(
    `INSERT INTO quote_line_items (id,user_id,quote_id,description,quantity,unit_price_cents,sort_order,created_at,updated_at)
     VALUES (?,?,?,'Site inspection',1,10000,0,?,?)`,
  ).bind(uuidv7(), userId, quoteId, now, now).run();
  return { profileId, quoteId };
}

describe("POST /quotes/:id/link", () => {
  it("mints a token, mints a quote number if absent, and returns {url, number}", async () => {
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(typeof body.url).toBe("string");
    expect(body.url).toContain("https://api.snapceipt.cc/q/");
    expect(typeof body.number).toBe("string");
    expect(body.number).toMatch(/^SN-\d{4}$/);
  });

  it("404 for a quote owned by another user", async () => {
    const { accessToken } = await seedAuthed();
    const other = await seedAuthed();
    const { quoteId } = await seedQuote(other.userId);
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(404);
  });

  it("400 for a quote with no line items", async () => {
    const { userId, accessToken } = await seedAuthed();
    const profileId = uuidv7();
    const quoteId = uuidv7();
    const now = nowMs();
    await env.DB.prepare(
      `INSERT INTO profiles (id,user_id,name,type,accent_1,accent_2,accent_3,created_at,updated_at)
       VALUES (?,?,'Acme','business','#0E7C72','#DCF0ED','#0A5950',?,?)`,
    ).bind(profileId, userId, now, now).run();
    await env.DB.prepare(
      `INSERT INTO quotes (id,user_id,profile_id,gst_enabled,status,created_at,updated_at)
       VALUES (?,?,?,1,'draft',?,?)`,
    ).bind(quoteId, userId, profileId, now, now).run();
    const res = await SELF.fetch(`${BASE}/quotes/${quoteId}/link`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
      body: "{}",
    });
    expect(res.status).toBe(400);
  });
});

describe("GET /q/:token (public HTML quote)", () => {
  it("renders the quote HTML at the document's GST rate (15%) for a valid token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);

    const res = await SELF.fetch(`${BASE}/q/${token}`); // no auth header (public)
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/html");
    const html = await res.text();
    expect(html).toContain("Acme Pty Ltd");
    expect(html).toContain("12 345 678 901"); // ABN
    expect(html).toContain("GST (15%)");
    expect(html).toContain("Jane Roe");
    expect(html).toContain("Payment details");
    expect(html).toContain("Made with Snapceipt");
    // 15% on 10000c subtotal = 1500c GST, 11500c total.
    expect(html).toContain("$115.00");
  });

  it("labels GST 10% when the quote's gst_rate_bp is null (pre-feature quote)", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { gstRateBp: null });
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("GST (10%)");
    expect(html).toContain("$110.00"); // 10% on 10000 = 11000c total
  });

  it("omits the payment block when the profile has no bank details", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId, { bankDetails: null });
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    const html = await (await SELF.fetch(`${BASE}/q/${token}`)).text();
    expect(html).not.toContain("Payment details");
  });

  it("403 for a forged token", async () => {
    const res = await SELF.fetch(`${BASE}/q/not.a.valid.token`);
    expect(res.status).toBe(403);
  });

  it("403 for an expired token", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId, -10);
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(403);
  });

  it("404 for a valid token whose quote was deleted", async () => {
    const { userId } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);
    const token = await signQuoteLinkToken(env.JWT_SIGNING_KEY, quoteId, userId);
    await env.DB.exec("DELETE FROM quotes");
    const res = await SELF.fetch(`${BASE}/q/${token}`);
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `npm test -- test/quoteLink.test.ts`
Expected: FAIL — `/quotes/:id/link` and `/q/:token` are not mounted.

- [ ] **Step 3: Add the shared loader + `POST /:id/link` to `src/routes/quotes.ts`**

First update the imports at the top of `src/routes/quotes.ts` (remove the pdfQuote import; add the new ones):

```typescript
import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";
import { uuidv7 } from "../lib/ids";
import { recomputeTotals, type QuoteLineItemAmounts } from "../lib/quoteTotals";
import { assignQuoteNumber } from "../lib/quoteCounter";
import * as emailModule from "../lib/email";
import { signQuoteLinkToken } from "../lib/exportToken";
import { renderQuoteHtml, type QuoteHtmlData } from "../lib/quoteHtml";
```

> `Env` must be importable from `../env` — it is already exported there.

Add the loader + a small helper near the top of the file (after the `utcDate` helper). Replace the `QuoteRow` / `LineItemRow` interfaces with these wider ones that include the new columns + profile fields:

```typescript
const APP_URL = "https://snapceipt.cc";
const API_ORIGIN = "https://api.snapceipt.cc";

interface QuoteRenderRow {
  id: string;
  profile_id: string;
  number: string | null;
  client_name: string | null;
  client_email: string | null;
  gst_enabled: number;
  gst_inclusive: number;
  gst_rate_bp: number | null;
  valid_until: string | null;
  created_at: number;
}

interface ProfileRow {
  name: string;
  abn: string | null;
  business_email: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  bank_details: string | null;
  logo_r2_key: string | null;
}

interface LineItemRow {
  description: string;
  quantity: number;
  unit_price_cents: number;
}

/** R2 object → data-URI (base64), or null when no key / object missing. */
async function logoDataUri(env: Env, key: string | null): Promise<string | null> {
  if (!key) return null;
  const obj = await env.RECEIPTS.get(key);
  if (!obj) return null;
  const bytes = new Uint8Array(await obj.arrayBuffer());
  const contentType = obj.httpMetadata?.contentType ?? "image/png";
  let binary = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return `data:${contentType};base64,${btoa(binary)}`;
}

/**
 * Load a quote + its line items + owning profile and assemble the QuoteHtmlData the
 * HTML template needs. Recomputes totals authoritatively at the quote's snapshotted
 * gst_rate_bp (null ⇒ 1000 = 10%). Returns null when the quote/profile is missing or
 * the quote has no line items (the caller maps null to 404).
 */
export async function loadQuoteForRender(
  env: Env,
  quoteId: string,
  userId: string,
): Promise<QuoteHtmlData | null> {
  const quote = await env.DB.prepare(
    `SELECT id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive,
            gst_rate_bp, valid_until, created_at
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<QuoteRenderRow>();
  if (!quote) return null;

  const { results: lineItems } = await env.DB.prepare(
    `SELECT description, quantity, unit_price_cents
       FROM quote_line_items
      WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL
      ORDER BY sort_order ASC, id ASC`,
  ).bind(quoteId, userId).all<LineItemRow>();
  if (lineItems.length === 0) return null;

  const profile = await env.DB.prepare(
    `SELECT name, abn, business_email, phone, website, address, bank_details, logo_r2_key
       FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quote.profile_id, userId).first<ProfileRow>();
  if (!profile) return null;

  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
    quote.gst_rate_bp,
  );

  return {
    number: quote.number,
    issuedDate: utcDate(quote.created_at),
    validUntil: quote.valid_until,
    clientName: quote.client_name,
    clientEmail: quote.client_email,
    gstEnabled,
    gstInclusive,
    gstRateBp: quote.gst_rate_bp,
    subtotalCents: totals.subtotalCents,
    gstCents: totals.gstCents,
    totalCents: totals.totalCents,
    business: {
      name: profile.name,
      abn: profile.abn,
      businessEmail: profile.business_email,
      phone: profile.phone,
      website: profile.website,
      address: profile.address,
      bankDetails: profile.bank_details,
    },
    lineItems: lineItems.map((li): QuoteHtmlData["lineItems"][number] => ({
      description: li.description,
      quantity: li.quantity,
      unitPriceCents: li.unit_price_cents,
    })),
    logoDataUri: await logoDataUri(env, profile.logo_r2_key),
    appUrl: APP_URL,
  };
}
```

> Keep the existing `utcDate(ms)` helper (it is reused above). Remove the old narrow `QuoteRow` interface if it is now unused after Task 8 reworks `send`.

Add the `POST /:id/link` route (place it among the quote routes):

```typescript
// POST /quotes/:id/link — mint a 90-day signed link to the public HTML quote page.
// Validates the quote loads (owned + has line items) before minting; mints the quote
// number if absent (sharing a link "issues" the quote — the HTML page must show #N).
quotesRoutes.post("/:id/link", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  const quote = await c.env.DB.prepare(
    `SELECT number FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{ number: string | null }>();
  if (!quote) throw new ApiError("NOT_FOUND", "Quote not found for this user");

  const items = await c.env.DB.prepare(
    `SELECT COUNT(*) AS n FROM quote_line_items WHERE quote_id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{ n: number }>();
  if (!items || items.n === 0) {
    throw new ApiError("VALIDATION_FAILED", "Cannot link a quote with no line items");
  }

  // Mint the quote number on first link (so the HTML page can show "Quote #N").
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));
  if (!quote.number) {
    await c.env.DB.prepare(
      `UPDATE quotes SET number = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
    ).bind(number, nowMs(), quoteId, userId).run();
  }

  const token = await signQuoteLinkToken(c.env.JWT_SIGNING_KEY, quoteId, userId);
  return c.json({ url: `${API_ORIGIN}/q/${token}`, number });
});
```

- [ ] **Step 4: Create the public route group `src/routes/quoteLink.ts`**

```typescript
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyQuoteLinkToken } from "../lib/exportToken";
import { renderQuoteHtml } from "../lib/quoteHtml";
import { loadQuoteForRender } from "./quotes";

/**
 * PUBLIC GET /q/:token — the hosted HTML quote page (spec §4). Verifies the signed
 * 90-day quote-link token (qid + uid), loads + tenant-scopes the quote, recomputes
 * totals at the quote's snapshotted gst_rate_bp, and renders the self-contained HTML
 * (logo inlined as a data-URI). A bad/expired token is 403; a valid token whose quote
 * no longer exists (or has no line items) is 404. In PUBLIC_PATHS — no bearer required.
 */
export const quoteLinkRoutes = new Hono<AppEnv>();

quoteLinkRoutes.get("/:token", async (c) => {
  const token = c.req.param("token");
  let quoteId: string;
  let userId: string;
  try {
    ({ quoteId, userId } = await verifyQuoteLinkToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired quote link");
  }

  const data = await loadQuoteForRender(c.env, quoteId, userId);
  if (!data) throw new ApiError("NOT_FOUND", "Quote not found");

  return new Response(renderQuoteHtml(data), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
});
```

- [ ] **Step 5: Add `/q/` to `PUBLIC_PATHS` and remove `/quotes/dl/` in `src/middleware/auth.ts`**

Replace the `PUBLIC_PATHS` line:

```typescript
export const PUBLIC_PATHS = ["/health", "/auth/", "/banks", "/export/dl/", "/q/", "/invoices/dl/", "/appstore/"];
```

> `/quotes/dl/` is removed (that route is deleted in Task 8). `/q/` is added so the global auth middleware lets the public quote page through.

- [ ] **Step 6: Mount `/q` (public) + its rate limiter in `src/app.ts`**

Add the import:

```typescript
import { quoteLinkRoutes } from "./routes/quoteLink";
```

Add the rate limiter (after the `/quotes` limiter block). The `/q/*` GET is unauthenticated, so the `default` tier falls back to IP-keyed limiting:

```typescript
// Public HTML quote page — GET /q/:token. Unauthenticated; the default tier's
// per-user limiter falls back to IP-keyed limiting on this public endpoint.
app.use("/q/*", rateLimit("default"));
```

Add the route mount (near the other public routes, e.g. just before `app.route("/appstore", appstoreRoutes);`):

```typescript
// Public: GET /q/:token — hosted HTML quote page (via PUBLIC_PATHS).
app.route("/q", quoteLinkRoutes);
```

- [ ] **Step 7: Run the quoteLink test to confirm it passes**

Run: `npm test -- test/quoteLink.test.ts`
Expected: PASS (link mint + 404/400; HTML render at 15%/10%; payment block toggle; 403 forged/expired; 404 deleted).

- [ ] **Step 8: Commit**

```bash
git add src/routes/quotes.ts src/routes/quoteLink.ts src/middleware/auth.ts src/app.ts test/quoteLink.test.ts
git commit -m "feat(quote): GET /q/:token HTML page + POST /quotes/:id/link (90-day token, logo data-URI)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Rework sendQuoteEmail + POST /quotes/:id/send (email the link) + remove pdfQuote / pdf / dl routes

**Files:**
- Modify: `src/lib/email.ts` (rework `sendQuoteEmail` → link, not PDF)
- Modify: `src/routes/quotes.ts` (rework `POST /:id/send`; delete `POST /:id/pdf` + `GET /dl/:token`)
- Delete: `src/lib/pdfQuote.ts`
- Modify: `src/app.ts` (update the `/quotes/dl` comments — optional, no behaviour change)
- Modify: `test/quotes-send.test.ts` (rework to the link contract; drop the `GET /quotes/dl` block)
- Modify: `test/quotes-app.test.ts` (update the public-route assertion)
- Delete: `test/quotes-pdf.test.ts`, `test/pdfQuote.test.ts`

**Interfaces:**
- Consumes: `loadQuoteForRender` (Task 7, for nothing here — send uses its own totals path), `signQuoteLinkToken` (Task 4), `assignQuoteNumber` (existing), `recomputeTotals` (Task 3).
- Produces:
  - `sendQuoteEmail(env: Env, msg: QuoteEmail): Promise<void>` where the new
    `interface QuoteEmail { to: string; replyTo: string; quoteNumber: string; clientName: string | null; totalCents: number; url: string; }` — **no `pdf` field**; the body links to `url`.
  - **`POST /quotes/:id/send`** — auth-gated. Request body `{}`. Response `200`: `{ "url": "https://api.snapceipt.cc/q/<token>", "emailed": true|false, "number": "SN-####" }`. Errors: `404 NOT_FOUND` (quote not owned/missing), `400 VALIDATION_FAILED` (no line items; no client email — *before* any mutation). Side effects: mint number on first send, recompute + persist totals, set `status='sent'` + `sent_at`, insert `email_outbox` row (kind `quote_send`, export_format `pdf` retained as the existing CHECK value — see note), attempt send via the seam. Status/totals stay server-side; iOS reads them via sync, not the send response.
  - `POST /quotes/:id/pdf` and `GET /quotes/dl/:token` no longer exist.

> **Outbox `export_format` note:** the `email_outbox` CHECK allows only `('pdf','csv')` or NULL. A quote-link send carries no file, so insert the row with `export_format = NULL` (valid) instead of `'pdf'`. The existing test asserting `export_format === 'pdf'` is updated below.

- [ ] **Step 1: Rework `sendQuoteEmail` in `src/lib/email.ts`**

Replace the `QuoteEmail` interface, the `MAX_QUOTE_PDF_BYTES` const, and the `sendQuoteEmail` function with:

```typescript
/** The quote-send email (a link to the hosted HTML quote, no attachment). */
export interface QuoteEmail {
  to: string;
  /** The trader's own email — set as Reply-To so the client replies to them. */
  replyTo: string;
  quoteNumber: string;
  clientName: string | null;
  totalCents: number;
  /** The hosted HTML quote URL (https://api.snapceipt.cc/q/<token>). */
  url: string;
}

/**
 * Send the quote email with a LINK to the hosted HTML quote (spec §4/§5 — no PDF
 * attachment). Mirrors sendMagicLinkEmail's plain-text SendEmail builder path (no
 * mimetext/cloudflare:email needed for a link-only message). `from` is the magic-link
 * sender; Reply-To is the trader so the client replies to them. Stubbed in route tests
 * via vi.spyOn(emailModule, "sendQuoteEmail").
 */
export async function sendQuoteEmail(env: Env, msg: QuoteEmail): Promise<void> {
  const total = `$${(msg.totalCents / 100).toFixed(2)}`;
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    replyTo: msg.replyTo,
    subject: `Quote ${msg.quoteNumber} — ${total}`,
    text:
      `${greeting}\n\n` +
      `View your quote ${msg.quoteNumber} for ${total} here:\n\n${msg.url}\n\n` +
      `Reply to this email if you have any questions.\n`,
  });
}
```

> The SendEmail builder overload accepts `replyTo`. If the runtime's `SendEmail` type does not expose `replyTo` on the builder overload, set it via the message instead; mirror exactly how `sendMagicLinkEmail` shapes its builder call (those are the proven fields). If `replyTo` is unsupported on the builder, drop it from the builder call — the Reply-To is a nicety, not a contract assertion in the reworked test.

- [ ] **Step 2: Rework `POST /quotes/:id/send` in `src/routes/quotes.ts`**

Replace the entire existing `quotesRoutes.post("/:id/send", ...)` handler with:

```typescript
quotesRoutes.post("/:id/send", async (c) => {
  const userId = c.var.userId;
  const quoteId = c.req.param("id");

  // 1. Load the quote (scoped to the authed user).
  const quote = await c.env.DB.prepare(
    `SELECT id, profile_id, number, client_name, client_email, gst_enabled, gst_inclusive, gst_rate_bp
       FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(quoteId, userId).first<{
    id: string; profile_id: string; number: string | null;
    client_name: string | null; client_email: string | null;
    gst_enabled: number; gst_inclusive: number; gst_rate_bp: number | null;
  }>();
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

  // 2b. Email PRECONDITION — validate BEFORE any mutation (spec §8): a missing client
  // email is a hard 400 that must NOT burn a number / flip status / log an outbox row.
  if (!quote.client_email) {
    throw new ApiError("VALIDATION_FAILED", "Quote has no client email to send to");
  }

  // 3. Recompute totals authoritatively at the quote's snapshotted rate (null ⇒ 1000).
  const gstEnabled = quote.gst_enabled === 1;
  const gstInclusive = quote.gst_inclusive === 1;
  const totals = recomputeTotals(
    lineItems.map((li): QuoteLineItemAmounts => ({ quantity: li.quantity, unitPriceCents: li.unit_price_cents })),
    gstEnabled,
    gstInclusive,
    quote.gst_rate_bp,
  );

  // 4. Mint SN-#### only on the first send; a re-send keeps the existing number.
  const number = quote.number ?? (await assignQuoteNumber(c.env.DB, userId));

  // 5. Persist totals + number + status=sent + sent_at.
  const now = nowMs();
  await c.env.DB.prepare(
    `UPDATE quotes
        SET number = ?, status = 'sent', sent_at = ?,
            subtotal_cents = ?, gst_cents = ?, total_cents = ?,
            updated_at = ?
      WHERE id = ? AND user_id = ?`,
  ).bind(number, now, totals.subtotalCents, totals.gstCents, totals.totalCents, now, quoteId, userId).run();

  // 6. Mint the 90-day public quote link.
  const token = await signQuoteLinkToken(c.env.JWT_SIGNING_KEY, quoteId, userId);
  const url = `${API_ORIGIN}/q/${token}`;

  // 7. email_outbox row + gated send. export_format is NULL (a link, no file).
  const outboxId = uuidv7();
  await c.env.DB.prepare(
    `INSERT INTO email_outbox (id, user_id, to_email, kind, subject, status, export_format, export_r2_key, related_id, created_at)
     VALUES (?, ?, ?, 'quote_send', ?, 'queued', NULL, NULL, ?, ?)`,
  ).bind(outboxId, userId, quote.client_email, `Quote ${number}`, quoteId, now).run();

  // Attempt the send via the seam (which wraps env.EMAIL.send) inside try/catch; a
  // failure leaves the outbox failed, emailed:false, route still 200s.
  let emailed = false;
  const trader = await c.env.DB.prepare(`SELECT email FROM users WHERE id = ?`)
    .bind(userId).first<{ email: string | null }>();
  try {
    await emailModule.sendQuoteEmail(c.env, {
      to: quote.client_email,
      replyTo: trader?.email ?? "noreply@snapceipt.cc",
      quoteNumber: number,
      clientName: quote.client_name,
      totalCents: totals.totalCents,
      url,
    });
    await c.env.DB.prepare(`UPDATE email_outbox SET status='sent', sent_at=? WHERE id=?`)
      .bind(nowMs(), outboxId).run();
    emailed = true;
  } catch (err) {
    await c.env.DB.prepare(`UPDATE email_outbox SET status='failed', error=? WHERE id=?`)
      .bind(String(err instanceof Error ? err.message : err), outboxId).run();
    emailed = false;
  }

  // 8. Response — the link + whether the email went out + the minted/existing number.
  return c.json({ url, emailed, number });
});
```

- [ ] **Step 3: Delete `POST /:id/pdf` and `GET /dl/:token` from `src/routes/quotes.ts`**

Remove the entire `quotesRoutes.post("/:id/pdf", ...)` handler and the entire `quotesRoutes.get("/dl/:token", ...)` handler. Remove any now-unused imports (`buildQuotePdf`, `QuoteLineItemRow`, `QuoteSender`, `signDownloadToken`, `verifyDownloadToken`, `DOWNLOAD_TTL_SECONDS`) — these were already replaced by the Task 7 import block, so confirm none remain. The file's top-of-file doc comment should be updated to:

```typescript
/**
 * POST /quotes/:id/link  — Bearer; mint a 90-day signed link to the public HTML quote.
 * POST /quotes/:id/send  — Bearer; mint number + email the client the link.
 * GET  /q/:token         — PUBLIC (separate group, quoteLink.ts); renders the HTML page.
 *
 * Quote/line-item/client CRUD stays on /sync. loadQuoteForRender is shared with /q.
 */
```

- [ ] **Step 4: Delete `src/lib/pdfQuote.ts`**

```bash
git rm src/lib/pdfQuote.ts test/pdfQuote.test.ts test/quotes-pdf.test.ts
```

- [ ] **Step 5: Update `test/quotes-app.test.ts`** (the `/quotes/dl/*` public route is gone; `/q/*` is the public surface now)

Replace the second test:

```typescript
  it("GET /q/* is public (no auth) — a forged token is 403, not 401", async () => {
    const res = await SELF.fetch("https://x/q/forged");
    expect(res.status).toBe(403);
  });
```

- [ ] **Step 6: Rework `test/quotes-send.test.ts`**

(a) In `seedQuote`, add `gst_rate_bp` to the inserted quote so the snapshot path is exercised. Change the quote INSERT to include the column (default 10% so the existing totals assertions hold):

```typescript
  await env.DB.prepare(
    `INSERT INTO quotes (id,user_id,profile_id,client_name,client_email,gst_enabled,gst_inclusive,gst_rate_bp,status,valid_until,created_at,updated_at)
     VALUES (?,?,?,'Jane Roe',?,1,?,1000,'draft','2026-06-15',?,?)`,
  ).bind(quoteId, userId, profileId,
    opts.clientEmail === undefined ? "jane@example.com" : opts.clientEmail,
    opts.gstInclusive ? 1 : 0, now, now).run();
```

(b) Rework the main success test to the link contract. Replace its body assertions:

```typescript
  it("recomputes totals, mints SN-0001 on first send, sets status=sent + sentAt, emails the LINK (spied)", async () => {
    const spy = vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken, email } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;

    // The response is the link contract: { url, emailed, number }.
    expect(typeof body.url).toBe("string");
    expect(body.url).toContain("https://api.snapceipt.cc/q/");
    expect(body.emailed).toBe(true);
    expect(body.number).toBe("SN-0001");

    // Persisted on the quote: number minted, status sent, totals recomputed (10% default).
    const row = await env.DB.prepare(
      `SELECT number, status, sent_at, subtotal_cents, gst_cents, total_cents FROM quotes WHERE id=?`,
    ).bind(quoteId).first<any>();
    expect(row.number).toBe("SN-0001");
    expect(row.status).toBe("sent");
    expect(row.sent_at).not.toBeNull();
    expect(row.subtotal_cents).toBe(105000);
    expect(row.gst_cents).toBe(10500);
    expect(row.total_cents).toBe(115500);

    // sendQuoteEmail got the URL + the trader's reply-to (no pdf field anymore).
    expect(spy).toHaveBeenCalledTimes(1);
    const arg = spy.mock.calls[0]![1] as emailModule.QuoteEmail;
    expect(arg.to).toBe("jane@example.com");
    expect(arg.replyTo).toBe(email);
    expect(arg.quoteNumber).toBe("SN-0001");
    expect(arg.url).toContain("/q/");
    expect((arg as any).pdf).toBeUndefined();

    // Outbox queued -> sent; export_format is NULL for a link send.
    const outbox = await env.DB.prepare(
      `SELECT kind, status, to_email, related_id, export_format FROM email_outbox WHERE related_id=?`,
    ).bind(quoteId).first<any>();
    expect(outbox.kind).toBe("quote_send");
    expect(outbox.status).toBe("sent");
    expect(outbox.to_email).toBe("jane@example.com");
    expect(outbox.export_format).toBeNull();
  });
```

(c) In the GST-inclusive test, drop any `pdfUrl` assertion and keep only the persisted-totals assertions (they are unchanged). In the idempotent / SN-0002 / email-throws tests, replace any `body.pdfUrl`/`body.number`/`body.status` assertions that no longer exist with `body.url` / DB-row reads. The number/status are now read from the DB row, not the response. Concretely, for the email-throws test:

```typescript
  it("when the email send THROWS, outbox -> failed but the route still 200s with emailed:false", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockRejectedValue(new Error("smtp down"));
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    const res = await send(quoteId, accessToken);
    expect(res.status).toBe(200);
    const body = (await res.json()) as any;
    expect(body.emailed).toBe(false);
    expect(typeof body.url).toBe("string");
    expect(body.number).toBe("SN-0001");

    const row = await env.DB.prepare(`SELECT number, status FROM quotes WHERE id=?`)
      .bind(quoteId).first<{ number: string | null; status: string }>();
    expect(row?.number).toBe("SN-0001"); // number still minted, status still sent
    expect(row?.status).toBe("sent");

    const outbox = await env.DB.prepare(`SELECT status, error FROM email_outbox WHERE related_id=?`)
      .bind(quoteId).first<{ status: string; error: string | null }>();
    expect(outbox?.status).toBe("failed");
    expect(outbox?.error).toContain("smtp down");
  });
```

For the idempotent + SN-0002 tests, read the number from the DB row (the response no longer carries `number`):

```typescript
  it("is IDEMPOTENT: a re-send keeps the existing number (no new mint)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const { quoteId } = await seedQuote(userId);

    await send(quoteId, accessToken);
    await send(quoteId, accessToken);

    const row = await env.DB.prepare(`SELECT number FROM quotes WHERE id=?`).bind(quoteId).first<{ number: string }>();
    expect(row.number).toBe("SN-0001"); // unchanged

    const ctr = await env.DB.prepare(`SELECT next_seq FROM quote_counters WHERE user_id=?`)
      .bind(userId).first<{ next_seq: number }>();
    expect(ctr?.next_seq).toBe(1);
  });

  it("downstream sends for the same user get the next number (SN-0002)", async () => {
    vi.spyOn(emailModule, "sendQuoteEmail").mockResolvedValue(undefined);
    const { userId, accessToken } = await seedAuthed();
    const a = await seedQuote(userId);
    const b = await seedQuote(userId);

    await send(a.quoteId, accessToken);
    await send(b.quoteId, accessToken);

    const ra = await env.DB.prepare(`SELECT number FROM quotes WHERE id=?`).bind(a.quoteId).first<{ number: string }>();
    const rb = await env.DB.prepare(`SELECT number FROM quotes WHERE id=?`).bind(b.quoteId).first<{ number: string }>();
    expect(ra.number).toBe("SN-0001");
    expect(rb.number).toBe("SN-0002");
  });
```

(d) Delete the entire `describe("GET /quotes/dl/:token", ...)` block at the bottom of the file (that route no longer exists; coverage moves to `test/quoteLink.test.ts`). Remove the now-unused `verifyDownloadToken` import at the top.

- [ ] **Step 7: Run the reworked suites to confirm they pass**

Run: `npm test -- test/quotes-send.test.ts test/quotes-app.test.ts test/email.test.ts test/email-quote.test.ts`
Expected: PASS.

> If `test/email-quote.test.ts` asserts the old PDF-attachment shape of `sendQuoteEmail`, update its expectations to the new link shape (assert the rendered text contains the `url` and no attachment is added). If it only spies the seam, it needs no change.

- [ ] **Step 8: Run the FULL suite to catch any stragglers**

Run: `npm test`
Expected: PASS — no references to `pdfQuote`, `buildQuotePdf`, `/quotes/dl`, or `/quotes/:id/pdf` remain. If a stale reference surfaces (e.g. another test imports `buildQuotePdf`), remove/rework it inline.

- [ ] **Step 9: Update the now-stale `/quotes/dl` comments in `src/app.ts` (optional, no behaviour change)**

In the `/quotes` rate-limit comment block, replace the sentence about the public `GET /quotes/dl/*` download with: "The `/q/*` public HTML page is rate-limited separately above." Update the `app.route("/quotes", quotesRoutes)` comment to drop the "(+ public GET /quotes/dl/:token …)" clause.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(quote): send emails the HTML link (not a PDF); remove pdfQuote + /pdf + /dl

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- §3 configurable GST (bp formulas, null⇒1000, snapshot read) → Task 3 (engine) + Task 7/8 (routes read `gst_rate_bp`).
- §4 HTML quote: `GET /q/:token` (Task 7), `POST /quotes/:id/link` (Task 7), `POST /quotes/:id/send` emails link returning `{ url, emailed }` (Task 8), removal of `pdfQuote.ts` + `/pdf` + `/dl` (Task 8). HTML content (logo data-URI, ABN, business fields, bill-to, line items, subtotal/GST(rate%)/total, payment block, badge) → Task 5 (template) + Task 7 (loader inlines logo).
- §5 business details + `POST /profile/logo` → Task 1 (columns) + Task 2 (sync) + Task 6 (route) + Task 5/7 (render).
- §7 migration `0010` + sync wiring (wire keys, `logoR2Key` mapped normally) → Task 1 + Task 2.
- §9 backend phasing order (migration + sync before routes) → task order 1→8.
- §6 (#4, BAS pill) is iOS-only — correctly out of this backend plan.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code; all commands have expected output.

**Type consistency:** `recomputeTotals(..., gstRateBp?)` 4th param used identically in Tasks 3/7/8. `QuoteHtmlData`/`QuoteHtmlBusiness`/`QuoteHtmlLineItem` defined in Task 5, consumed in Task 7. `loadQuoteForRender(env, quoteId, userId)` defined in Task 7, consumed in Task 7's `/q` route. `signQuoteLinkToken`/`verifyQuoteLinkToken` defined in Task 4, consumed in Tasks 7/8. `QuoteEmail` (no `pdf`, has `url`) reworked in Task 8 and used by the Task 8 route. `SYNCABLE_TYPES.length` stays 18 (asserted in `schemas.test.ts`/`schemas-invoices.test.ts`/`sync-push.test.ts`) — untouched.

**Resolved ambiguities:**
1. Wire key for the address column is `address` (spec §7) — used despite §5 naming the iOS field `addressText`.
2. `email_outbox.export_format` is `NULL` for a link send (the CHECK only allows `'pdf'|'csv'|NULL`); the old `'pdf'` assertion is updated.
3. `POST /quotes/:id/send` response is `{ url, emailed, number }` — number is returned so iOS can display "Quote #N" immediately after sending; status/totals are persisted server-side and read from the DB in tests (not returned in the response).
4. `POST /profile/logo` is mounted at a new `/profile` group (distinct from the existing `/profiles` inbox prefix); auth-gated, `default` rate tier.
5. The quote-link token is a **new** `signQuoteLinkToken` (qid/uid, 90-day, distinct issuer/audience) reusing the `exportToken` HMAC machinery — `signDownloadToken` is kept only for `/invoices/dl`.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-20-quote-html-tax-business-backend.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
