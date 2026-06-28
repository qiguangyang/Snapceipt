# Content/SEO Engine + ASO Tune-Up — Design

**Date:** 2026-06-28
**Status:** Approved design, ready for implementation planning
**Type:** Growth/marketing mechanism (acquisition)

## Goal

Build an owned, organic acquisition channel for Snapceipt: a Markdown-driven content engine on `snapceipt.cc` that ranks for receipt/expense-management search intent (differentiated by the AU/ATO/sole-trader angle), plus a small App Store Optimization (ASO) pass that reuses the same keyword research. New people discover the guides via Google, the guides convert to App Store installs.

## Why this, why now

- Funnel target: **acquisition** (net-new installs), chosen over activation/monetization/retention.
- Channel: **content/SEO + ASO** — low-risk (almost no app code), fully owned, no ongoing ad spend.
- Topic cluster: **receipt/expense management** (broader volume than the pure BAS niche), with the **AU differentiator woven through every page** so we don't compete head-on with Expensify/QuickBooks on generic head terms.
- The marketing site already exists as a static, Cloudflare-served asset Worker — adding a content section is a natural, contained extension.

## Architecture

The site (`site/`) is currently an **assets-only Worker**: `wrangler.jsonc` points `assets.directory` at `./public` and Cloudflare serves those files directly. `html_handling` gives clean URLs (`/privacy` → `privacy.html`). There is no build step today and no `site/package.json`.

We add a **small static-site generator** that turns Markdown into HTML in `public/` before deploy. Hosting is unchanged — Cloudflare still serves `public/` as-is.

### New layout under `site/`

```
site/
  content/guides/*.md      ← articles (Markdown + YAML frontmatter)
  build.mjs                ← generator: md → html, regenerates sitemap + /guides index
  template.js              ← shared HTML shell (nav, SEO meta, JSON-LD, CTA, footer)
  test.mjs                 ← node:test integrity checks on generated output
  package.json             ← new: marked + gray-matter devDeps; build/deploy/test scripts
  public/
    guides/<slug>.html     ← one per article, clean URL /guides/<slug>
    guides/index.html      ← guides hub index (clean URL /guides)
    sitemap.xml            ← regenerated to include every guide
```

### Generator contract (`build.mjs`)

- Reads every `.md` under `site/content/guides/`.
- Parses YAML frontmatter with `gray-matter`; renders the Markdown body with `marked`.
- Wraps the body in `template.js`, which carries the **exact** nav/footer/font links from the current `index.html` so guides look native to the site, and injects per-page SEO + schema (see SEO section).
- Writes `public/guides/<slug>.html`.
- Regenerates `public/sitemap.xml` from the full file list (existing top-level pages + all guides), with `<lastmod>` from each article's `updated` date.
- Generates `public/guides/index.html` — a lightweight hub listing all guides, pillar featured first.
- Runs integrity assertions (see Testing) and **exits non-zero** if any fail.

### Frontmatter schema (per article)

```yaml
---
title: "How to Track Business Expenses in Australia (2026 Guide)"
description: "..."          # ≤155 chars, used as meta description
slug: track-business-expenses-australia
role: pillar               # pillar | spoke
keywords: [business expenses, sole trader, ...]
related: [organise-receipts-for-tax, gst-on-business-expenses]   # slugs; must resolve
updated: 2026-06-28
---
```

### `site/package.json` scripts

```json
{
  "scripts": {
    "build": "node build.mjs",
    "test": "node test.mjs",
    "deploy": "npm run build && wrangler deploy"
  },
  "devDependencies": { "marked": "...", "gray-matter": "..." }
}
```

### Isolation rationale

- `build.mjs` is one unit: Markdown in → HTML out. Pure, testable.
- `template.js` is the **single source of layout truth** — eliminates per-page meta-tag drift.
- Articles are plain Markdown, fast to author. Two small, well-known devDeps; no framework.

## Content map (hub-and-spoke cluster)

**Pillar (1):** `/guides/track-business-expenses-australia` — *"How to Track Business Expenses in Australia (2026 Guide)"*. Comprehensive hub targeting the head term "track business expenses"; links down to every spoke; includes a Q&A section (FAQ schema).

**Spokes (7):**

| Slug | Title | Primary intent |
|---|---|---|
| `organise-receipts-for-tax` | How to Organise Receipts for Tax (Without the Shoebox) | "how to organise receipts" |
| `do-you-need-paper-receipts-ato` | Do You Need to Keep Paper Receipts? What the ATO Requires | "do I need to keep paper receipts" |
| `digital-receipts-ato` | Are Photos of Receipts Valid for Tax? Digital Receipts & the ATO | "are digital receipts valid" |
| `gst-on-business-expenses` | GST on Business Expenses, Explained Simply | "GST on expenses" |
| `expense-tracking-sole-traders` | Expense Tracking for Sole Traders: A Practical Setup | "expense tracking sole trader" |
| `track-receipts-on-phone` | The Best Way to Track Receipts on Your Phone | "receipt tracking app / scan receipts" |
| `best-receipt-scanner-app-australia` | Best Receipt Scanner Apps in Australia (2026) | "best receipt scanner app australia" (buyer-intent) |

**Internal linking (hub-and-spoke):** pillar links to all 7 spokes; each spoke links back to the pillar + its 2–3 `related` siblings. A **"Guides"** link is added to the main site nav (in `index.html` and the template). `/guides` is the hub index.

**CTA:** every page ends with the same Snapceipt CTA block (App Store badge + one-line pitch) — the acquisition conversion point.

**Quality bar:** genuinely useful, accurate guides — not keyword filler (Google's helpful-content system punishes thin pages). **ATO specifics (record-keeping period, the $75 receipt substantiation threshold, GST registration turnover threshold, etc.) MUST be fact-checked against current ATO guidance at write time, not asserted from memory.** Accuracy is both an SEO and a credibility requirement.

## SEO mechanics (baked into `template.js`)

- **`<head>` per page:** unique `<title>` (≤60 chars), meta description (≤155), `<link rel=canonical>`, full Open Graph (`og:type=article`, title, description, url, image), Twitter card.
- **Branded OG image:** add one static branded OG image (e.g. `public/assets/og-default.png`) instead of today's favicon-as-og-image, which previews poorly. Articles may override via frontmatter later; default is fine for v1.
- **JSON-LD structured data:** `Article` (headline, description, `datePublished`/`dateModified` from frontmatter, publisher=Snapceipt with logo) + `BreadcrumbList` (Home › Guides › Article). The **pillar additionally emits `FAQPage`** from its Q&A section.
- **Visible breadcrumb** matching the schema; descriptive internal-link anchor text.
- **Sitemap** regenerated with all guides + `lastmod` from `updated`. `robots.txt` already allows all + references the sitemap — no change needed.
- Pages are static HTML reusing `/site.css` plus a long-form **article typography** block (added to `site.css` or a small `article.css`). Fast by default; no perf work.

## ASO tune-up (reuses the keyword research)

**Current listing surface (fastlane `metadata/en-AU/`):**
- `name.txt` = `Snapceipt — Receipts & GST`
- `subtitle.txt` = `Expenses, GST & BAS, sorted` (27/30 chars)
- `keywords.txt` = `receipt,expense,gst,bas,tax,mileage,logbook,sole trader,small business,invoice,budget,quote`

**Key finding:** Apple indexes **name + subtitle + keywords together**. The `keywords` field currently *repeats* `receipt, expense, gst, bas` — all already present in the name/subtitle — wasting ~20 of the 100 chars.

**Tune-up:**
- **Reclaim the duplicated chars** in `keywords.txt` for un-covered high-intent terms surfaced by the content research (candidates: `scanner, tracker, ATO, deduction, bookkeeping, accounting, spending`). Final list chosen during implementation, kept ≤100 chars, no word that already appears in name/subtitle.
- **Refresh `promotional_text.txt`** — this field is **editable live** in App Store Connect with no new build.

**Dependency / constraint:** the `keywords` and `subtitle` fields can only change with the **next app version (1.0.x)** or while the listing is editable. The current version is in `WAITING_FOR_REVIEW`. Therefore:
- The **keyword swap rides the next build** — it cannot ship standalone today.
- The **`promotional_text` refresh can ship now** (live-editable).

This ASO change set is **metadata only** (no app code, no new screenshots).

## Testing & verification

- **`build.mjs` integrity assertions** (build fails if violated):
  1. every `.md` produces exactly one `.html`;
  2. every page has a non-empty title, description, canonical, and parseable JSON-LD;
  3. every `related` slug resolves to a real article (no dangling internal links);
  4. `sitemap.xml` contains every guide URL exactly once.
- **`site/test.mjs`** (Node's built-in `node:test`, no framework): runs the build into a temp output dir and asserts the above on the generated files. Wired as `npm test` in `site/package.json` (runnable + CI-able).
- **Manual pass:** `wrangler dev` in `site/`, eyeball the pillar + one spoke, confirm `/guides/<slug>` clean URLs resolve from the subdirectory, validate one page through Google's Rich Results test before submitting the sitemap.

## Rollout & measurement

- **Phase 1 (this build):** generator + `template.js` + `test.mjs` + nav "Guides" link + `/guides` index + **pillar + 2 spokes** (`organise-receipts-for-tax`, `do-you-need-paper-receipts-ato`). Deploy. Proves the engine end-to-end with real, indexable pages.
- **Phase 2:** the remaining 5 spokes — pure content, just add `.md` files and rebuild.
- **ASO:** ship the `promotional_text` refresh now; queue the keyword/subtitle swap onto the next app version (1.0.x).
- **Prerequisite (manual, external):** create a **Google Search Console** property for `snapceipt.cc` (DNS-verify via Cloudflare) and submit `sitemap.xml`. Without it there's no visibility into what ranks. This is the one hand-done setup step.
- **Success signal (8–12 weeks):** GSC impressions/clicks climbing on the target queries; App Store referral traffic from the guide CTAs.

## Out of scope (deferred)

- Programmatic/templated pages (per-category, per-profession) — approach B; layer on later only after a few spokes prove they rank.
- A headless CMS — overkill for a solo-run static site.
- Comparison-heavy content beyond the single "best receipt scanner app AU" spoke.
- Paid acquisition, referral loops, partner programs — different mechanisms, separate designs.

## Open items for the implementer

- Pick exact `marked` + `gray-matter` versions (latest stable, pinned).
- Decide `article.css` vs. appending to `site.css` (either is fine; follow whichever keeps `site.css` manageable).
- Produce the branded OG image asset.
- Final keyword string for `keywords.txt` (≤100 chars, no name/subtitle dupes).
- Write the pillar + 2 spokes with ATO facts verified at authoring time.
