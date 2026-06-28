# Content/SEO Engine + ASO Tune-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Markdown-driven static-site generator to `snapceipt.cc` that produces an SEO-optimized receipt/expense content cluster (pillar + spokes), plus a metadata-only ASO tune-up, to create an owned organic-acquisition channel.

**Architecture:** The site is an assets-only Cloudflare Worker serving `site/public/` directly. We add `site/build.mjs` (Markdown → HTML via `marked` + `gray-matter`), a single shared `site/template.js` HTML shell (nav/SEO/JSON-LD/CTA/footer), and `site/test.mjs` (`node:test`) that asserts generator output integrity. Articles live as `.md` files under `site/content/guides/`; generated `.html` lands in `site/public/guides/`. Hosting is unchanged.

**Tech Stack:** Node.js (ESM `.mjs`, built-in `node:test`/`node:fs`), `marked`, `gray-matter`, Cloudflare assets Worker (`wrangler`).

## Global Constraints

- All new build tooling lives under `site/`; the root project is untouched.
- Generated pages must reuse the existing design system in `site/public/site.css` (CSS vars: `--cream #FBF6F0`, `--ink #211C18`, `--terra #E8602C`, `--teal #0E7C72`, `--line #EADFCE`; fonts: Fraunces / Inter; container `.wrap` max 1080px, long-form `.prose` max 820px).
- App Store URL is exactly `https://apps.apple.com/au/app/id6778894594`. App Store badge image is `/assets/app-store-badge.svg`.
- Canonical/OG base URL is `https://snapceipt.cc`. Guide URLs are `https://snapceipt.cc/guides/<slug>` (clean, no `.html`).
- `<title>` ≤ 60 chars; meta `description` ≤ 155 chars.
- Every guide ends with the standard Snapceipt CTA block (defined in Task 4).
- The AU/ATO/sole-trader angle must appear in every guide (differentiation requirement).
- ATO factual claims must be verified against current ATO guidance at write time, never asserted from memory.
- ASO `keywords`/`subtitle` changes ride the NEXT app version (current version is `WAITING_FOR_REVIEW`); only `promotional_text` is live-editable.
- `keywords.txt` ≤ 100 chars and must not repeat any word already present in `name.txt` or `subtitle.txt`.
- Pin exact dependency versions in `site/package.json` (no `^`/`~` ranges).

---

## File Structure

| File | Responsibility |
|---|---|
| `site/package.json` (create) | Declares `marked`+`gray-matter` devDeps, `build`/`test`/`deploy` scripts |
| `site/template.js` (create) | Single source of page layout: head/SEO meta, JSON-LD, nav, breadcrumb, body slot, CTA, footer |
| `site/build.mjs` (create) | Reads `content/guides/*.md`, renders each to `public/guides/<slug>.html`, regenerates `sitemap.xml` + `/guides` index, runs integrity assertions |
| `site/test.mjs` (create) | `node:test` suite asserting generator output integrity |
| `site/content/guides/*.md` (create) | Article source (frontmatter + Markdown) |
| `site/public/guides/*.html` (generated) | Output — not hand-edited |
| `site/public/guides/index.html` (generated) | Guides hub index |
| `site/public/sitemap.xml` (regenerated) | All pages incl. guides |
| `site/public/assets/og-default.png` (create) | Branded 1200×630 Open Graph image |
| `site/public/site.css` (modify) | Append article typography + breadcrumb + CTA styles |
| `site/public/{index,pricing,support,privacy,terms}.html` (modify) | Add "Guides" nav link |
| `fastlane/metadata/en-AU/{keywords,promotional_text}.txt` (modify) | ASO tune-up |

---

## Task 1: Generator core (single-article render)

Builds the engine end-to-end for one article: package scaffold, the shared template shell with SEO `<head>`, the build loop, and the first integrity test.

**Files:**
- Create: `site/package.json`
- Create: `site/template.js`
- Create: `site/build.mjs`
- Create: `site/test.mjs`
- Create: `site/content/guides/_smoke.md` (temporary fixture, deleted in Task 5)

**Interfaces:**
- Produces:
  - `template.js` default export `renderPage(page) -> string` where `page = { title, description, slug, role, keywords: string[], related: string[], updated: string, bodyHtml: string, isGuide: boolean }`. Returns a full HTML document string.
  - `build.mjs` exports `async function build({ contentDir, outDir, publicDir }) -> { pages: Page[] }` and runs as a CLI when invoked directly. `Page` = the parsed object `{ title, description, slug, role, keywords, related, updated, bodyHtml }`.

- [ ] **Step 1: Create `site/package.json`**

```json
{
  "name": "snapceipt-site",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "test": "node --test",
    "deploy": "npm run build && npm test && wrangler deploy"
  },
  "devDependencies": {
    "gray-matter": "4.0.3",
    "marked": "12.0.2"
  }
}
```

- [ ] **Step 2: Install dependencies**

Run: `cd site && npm install`
Expected: `node_modules/` populated, `package-lock.json` created, no errors.

- [ ] **Step 3: Write `site/template.js`**

```js
// Single source of layout truth for generated guide pages.
// Mirrors the nav/footer/fonts of site/public/index.html so guides look native.

const SITE = "https://snapceipt.cc";
const APP_URL = "https://apps.apple.com/au/app/id6778894594";

const FONT_LINKS = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,500;0,9..144,600;1,9..144,500&family=Inter:wght@400;500;600&family=Schibsted+Grotesk:wght@500;600;700;800&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">`;

const NAV = `  <nav id="nav" class="nav">
    <a class="logo" href="/">Snap<b>ceipt</b></a>
    <div class="links">
      <a href="/guides">Guides</a>
      <a href="/pricing">Pricing</a>
      <a href="/support">Support</a>
      <a class="navbadge" href="${APP_URL}">Get the app</a>
    </div>
  </nav>`;

const FOOTER = `<footer class="footer"><div class="inner">
  <a class="logo" style="font-size:18px" href="/">Snap<b>ceipt</b></a>
  <a href="/guides">Guides</a><a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a>
  <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a>
  <span class="sp">© 2026 Snapceipt · Made in Australia 🇦🇺</span>
</div></footer>`;

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export default function renderPage(page) {
  const url = `${SITE}/guides/${page.slug}`;
  const title = page.title.length > 60 ? page.title.slice(0, 60) : page.title;
  return `<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(page.title)}</title>
<meta name="description" content="${esc(page.description)}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="${url}">
<meta property="og:type" content="article">
<meta property="og:title" content="${esc(page.title)}">
<meta property="og:description" content="${esc(page.description)}">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${SITE}/assets/og-default.png">
<meta name="twitter:card" content="summary_large_image">
${FONT_LINKS}
<link rel="stylesheet" href="/site.css">
</head>
<body>
<div class="wrap">
${NAV}
  <article class="prose article">
    <h1>${esc(page.title)}</h1>
    ${page.bodyHtml}
  </article>
</div>
${FOOTER}
</body>
</html>
`;
}

export { SITE, APP_URL, esc };
```

- [ ] **Step 4: Write `site/build.mjs`**

```js
import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import matter from "gray-matter";
import { marked } from "marked";
import renderPage from "./template.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function build({ contentDir, outDir }) {
  const mdFiles = (await readdir(contentDir)).filter((f) => f.endsWith(".md"));
  const pages = [];
  for (const file of mdFiles) {
    const raw = await readFile(path.join(contentDir, file), "utf8");
    const { data, content } = matter(raw);
    const bodyHtml = marked.parse(content);
    pages.push({
      title: data.title,
      description: data.description,
      slug: data.slug,
      role: data.role,
      keywords: data.keywords || [],
      related: data.related || [],
      updated: data.updated,
      bodyHtml,
    });
  }

  await mkdir(outDir, { recursive: true });
  for (const page of pages) {
    const html = renderPage(page);
    await writeFile(path.join(outDir, `${page.slug}.html`), html, "utf8");
  }
  return { pages };
}

// CLI entry
if (import.meta.url === `file://${process.argv[1]}`) {
  const contentDir = path.join(__dirname, "content/guides");
  const outDir = path.join(__dirname, "public/guides");
  const { pages } = await build({ contentDir, outDir });
  console.log(`Built ${pages.length} guide(s).`);
}
```

Note: Task 2 replaces this `build` function with a fuller version (validation + sitemap + index). Task 1's version intentionally has no `publicDir`/sitemap yet — that's expected; the Task 1 test does not check for a sitemap.

- [ ] **Step 5: Create temporary fixture `site/content/guides/_smoke.md`**

```markdown
---
title: "Smoke Test Guide"
description: "A temporary fixture to verify the generator renders a page correctly."
slug: _smoke
role: spoke
keywords: [smoke]
related: []
updated: 2026-06-28
---

This is a **smoke test** paragraph to confirm Markdown renders to HTML.
```

- [ ] **Step 6: Write `site/test.mjs`**

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, rm, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "./build.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const contentDir = path.join(__dirname, "content/guides");
const outDir = path.join(__dirname, ".test-out/guides");

test("renders each markdown file to an html file with required SEO head", async () => {
  await rm(path.join(__dirname, ".test-out"), { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });
  const { pages } = await build({ contentDir, outDir });
  assert.ok(pages.length >= 1, "expected at least one page");

  for (const page of pages) {
    const html = await readFile(path.join(outDir, `${page.slug}.html`), "utf8");
    assert.match(html, /<title>[^<]+<\/title>/, `${page.slug}: has title`);
    assert.match(html, /<meta name="description" content="[^"]+">/, `${page.slug}: has description`);
    assert.match(html, new RegExp(`<link rel="canonical" href="https://snapceipt.cc/guides/${page.slug}">`), `${page.slug}: canonical`);
    assert.match(html, /<meta property="og:type" content="article">/, `${page.slug}: og:type`);
  }
});
```

- [ ] **Step 7: Run the test — expect PASS**

Run: `cd site && npm test`
Expected: 1 test passing; `.test-out/guides/_smoke.html` produced with title, description, canonical, og:type.

- [ ] **Step 8: Run the real build and eyeball output**

Run: `cd site && npm run build`
Expected: `Built 1 guide(s).` and `site/public/guides/_smoke.html` exists.

- [ ] **Step 9: Commit**

```bash
git add site/package.json site/package-lock.json site/template.js site/build.mjs site/test.mjs site/content/guides/_smoke.md
git commit -m "feat(site): markdown->html guide generator core + SEO head"
```

(Do NOT commit `site/public/guides/_smoke.html` or `site/.test-out/` — add them in Step 10.)

- [ ] **Step 10: Ignore generated test output**

Append to `site/.gitignore` (create if absent):

```
.test-out/
public/guides/_smoke.html
```

Run: `git add site/.gitignore && git commit -m "chore(site): ignore generator test output"`

---

## Task 2: Sitemap regeneration, guides index, and integrity assertions

Extends the generator to regenerate `sitemap.xml`, emit the `/guides` hub index, and hard-fail the build on broken internal links or slug collisions.

**Files:**
- Modify: `site/build.mjs`
- Modify: `site/template.js` (add `renderIndex`)
- Modify: `site/test.mjs`

**Interfaces:**
- Consumes: `build({ contentDir, outDir })`, `Page` shape from Task 1.
- Produces:
  - `build.mjs` now also writes `<publicDir>/sitemap.xml` and `<outDir>/index.html`; accepts `publicDir` param: `build({ contentDir, outDir, publicDir })`.
  - `build.mjs` throws `Error` if: two pages share a slug; any `related` slug doesn't match a known slug.
  - `template.js` named export `renderIndex(pages) -> string`.

- [ ] **Step 1: Add the integrity + sitemap assertions to `test.mjs`**

Append these tests to `site/test.mjs`:

```js
import { writeFile } from "node:fs/promises";

test("regenerates sitemap.xml containing every guide url exactly once", async () => {
  const publicDir = path.join(__dirname, ".test-out");
  await build({ contentDir, outDir, publicDir });
  const sitemap = await readFile(path.join(publicDir, "sitemap.xml"), "utf8");
  const { pages } = await build({ contentDir, outDir, publicDir });
  for (const page of pages) {
    const loc = `https://snapceipt.cc/guides/${page.slug}`;
    const count = sitemap.split(loc).length - 1;
    assert.equal(count, 1, `${page.slug}: appears exactly once in sitemap`);
  }
});

test("writes a /guides index page listing the guides", async () => {
  const publicDir = path.join(__dirname, ".test-out");
  await build({ contentDir, outDir, publicDir });
  const index = await readFile(path.join(outDir, "index.html"), "utf8");
  assert.match(index, /<title>[^<]*Guides[^<]*<\/title>/i, "index has a Guides title");
});

test("throws when a related slug does not resolve", async () => {
  const tmpContent = path.join(__dirname, ".test-content");
  await rm(tmpContent, { recursive: true, force: true });
  await mkdir(tmpContent, { recursive: true });
  await writeFile(path.join(tmpContent, "a.md"),
    `---\ntitle: A\ndescription: d\nslug: a\nrole: spoke\nrelated: [does-not-exist]\nupdated: 2026-06-28\n---\nbody`, "utf8");
  await assert.rejects(
    () => build({ contentDir: tmpContent, outDir: path.join(__dirname, ".test-out2/guides"), publicDir: path.join(__dirname, ".test-out2") }),
    /related slug/i,
  );
  await rm(tmpContent, { recursive: true, force: true });
});
```

- [ ] **Step 2: Run the new tests — expect FAIL**

Run: `cd site && npm test`
Expected: FAIL — `sitemap.xml` not written, `index.html` not written, no throw on bad related slug.

- [ ] **Step 3: Add `renderIndex` to `site/template.js`**

Add before the final `export { ... }` line:

```js
export function renderIndex(pages) {
  const pillar = pages.find((p) => p.role === "pillar");
  const spokes = pages.filter((p) => p.role === "spoke");
  const ordered = pillar ? [pillar, ...spokes] : spokes;
  const items = ordered.map((p) =>
    `      <li><a href="/guides/${p.slug}">${esc(p.title)}</a><p>${esc(p.description)}</p></li>`).join("\n");
  return `<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Guides — Snapceipt</title>
<meta name="description" content="Practical guides to tracking receipts, expenses and GST in Australia.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="${SITE}/guides">
<meta property="og:type" content="website">
<meta property="og:title" content="Guides — Snapceipt">
<meta property="og:url" content="${SITE}/guides">
<meta property="og:image" content="${SITE}/assets/og-default.png">
${FONT_LINKS}
<link rel="stylesheet" href="/site.css">
</head>
<body>
<div class="wrap">
${NAV}
  <section class="prose article">
    <div class="kicker">Guides</div>
    <h1>Receipt &amp; expense guides</h1>
    <ul class="guideList">
${items}
    </ul>
  </section>
</div>
${FOOTER}
</body>
</html>
`;
}
```

Note: `FONT_LINKS`, `NAV`, `FOOTER`, `SITE`, `esc` are module-level constants in `template.js` from Task 1 — `renderIndex` references them directly.

- [ ] **Step 4: Extend `site/build.mjs` with validation, sitemap, and index**

Replace the body of `build(...)` so that after `pages` is populated and before writing per-page HTML, it validates; and after writing pages, it writes the index + sitemap. Full updated function:

```js
import renderPage, { renderIndex } from "./template.js";

const TOP_LEVEL = ["/", "/pricing", "/privacy", "/terms", "/support", "/guides"];

export async function build({ contentDir, outDir, publicDir }) {
  const mdFiles = (await readdir(contentDir)).filter((f) => f.endsWith(".md"));
  const pages = [];
  for (const file of mdFiles) {
    const raw = await readFile(path.join(contentDir, file), "utf8");
    const { data, content } = matter(raw);
    pages.push({
      title: data.title,
      description: data.description,
      slug: data.slug,
      role: data.role,
      keywords: data.keywords || [],
      related: data.related || [],
      updated: data.updated,
      bodyHtml: marked.parse(content),
    });
  }

  // Integrity: unique slugs, resolvable related links.
  const slugs = new Set();
  for (const p of pages) {
    if (slugs.has(p.slug)) throw new Error(`duplicate slug: ${p.slug}`);
    slugs.add(p.slug);
  }
  for (const p of pages) {
    for (const r of p.related) {
      if (!slugs.has(r)) throw new Error(`unresolved related slug "${r}" in "${p.slug}"`);
    }
  }

  await mkdir(outDir, { recursive: true });
  for (const page of pages) {
    await writeFile(path.join(outDir, `${page.slug}.html`), renderPage(page), "utf8");
  }
  await writeFile(path.join(outDir, "index.html"), renderIndex(pages), "utf8");

  // Sitemap: top-level pages + every guide.
  if (publicDir) {
    const guideUrls = pages.map((p) => `https://snapceipt.cc/guides/${p.slug}`);
    const allUrls = [...TOP_LEVEL.map((u) => `https://snapceipt.cc${u === "/" ? "/" : u}`), ...guideUrls];
    const body = allUrls.map((u) => `  <url><loc>${u}</loc></url>`).join("\n");
    const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`;
    await writeFile(path.join(publicDir, "sitemap.xml"), xml, "utf8");
  }

  return { pages };
}
```

Update the CLI block at the bottom to pass `publicDir`:

```js
if (import.meta.url === `file://${process.argv[1]}`) {
  const contentDir = path.join(__dirname, "content/guides");
  const publicDir = path.join(__dirname, "public");
  const outDir = path.join(publicDir, "guides");
  const { pages } = await build({ contentDir, outDir, publicDir });
  console.log(`Built ${pages.length} guide(s) + index + sitemap.`);
}
```

Remove the now-duplicate `import renderPage from "./template.js";` line at the top of Task 1's file — there must be exactly one import of `template.js`, the combined `import renderPage, { renderIndex } from "./template.js";`.

- [ ] **Step 5: Run the tests — expect PASS**

Run: `cd site && npm test`
Expected: all tests pass (smoke render, sitemap-once, index page, bad-related-slug throws).

- [ ] **Step 6: Run the build**

Run: `cd site && npm run build`
Expected: `Built 1 guide(s) + index + sitemap.`; `site/public/sitemap.xml` now lists top-level pages + `/guides/_smoke`; `site/public/guides/index.html` exists.

- [ ] **Step 7: Commit**

```bash
git add site/build.mjs site/template.js site/test.mjs site/public/sitemap.xml
git commit -m "feat(site): sitemap regen, /guides index, link-integrity assertions"
```

---

## Task 3: Structured data (JSON-LD) + visible breadcrumb

Adds `Article` + `BreadcrumbList` JSON-LD to every guide, `FAQPage` for the pillar, and a matching visible breadcrumb. This is what wins rich snippets.

**Files:**
- Modify: `site/template.js`
- Modify: `site/test.mjs`

**Interfaces:**
- Consumes: `renderPage(page)`, `Page` shape.
- Produces: `page` gains an optional `faq` field: `faq?: Array<{ q: string, a: string }>`. When present (pillar), template emits `FAQPage` JSON-LD. `build.mjs` passes `faq: data.faq || null` through.

- [ ] **Step 1: Add JSON-LD assertions to `test.mjs`**

Append:

```js
test("emits Article + BreadcrumbList JSON-LD that parses", async () => {
  const { pages } = await build({ contentDir, outDir, publicDir: path.join(__dirname, ".test-out") });
  for (const page of pages) {
    const html = await readFile(path.join(outDir, `${page.slug}.html`), "utf8");
    const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));
    const types = blocks.map((b) => b["@type"]);
    assert.ok(types.includes("Article"), `${page.slug}: has Article schema`);
    assert.ok(types.includes("BreadcrumbList"), `${page.slug}: has BreadcrumbList schema`);
  }
});
```

- [ ] **Step 2: Run — expect FAIL** (`No JSON-LD blocks`).

Run: `cd site && npm test`
Expected: FAIL on the new test.

- [ ] **Step 3: Add JSON-LD + breadcrumb to `template.js`**

In `renderPage`, build the schema blocks and a visible breadcrumb, then inject them. Add this helper above `renderPage`:

```js
function jsonLd(page, url) {
  const article = {
    "@context": "https://schema.org", "@type": "Article",
    headline: page.title, description: page.description,
    datePublished: page.updated, dateModified: page.updated,
    author: { "@type": "Organization", name: "Snapceipt" },
    publisher: { "@type": "Organization", name: "Snapceipt", logo: { "@type": "ImageObject", url: `${SITE}/favicon.svg` } },
    mainEntityOfPage: url,
  };
  const crumbs = {
    "@context": "https://schema.org", "@type": "BreadcrumbList",
    itemListElement: [
      { "@type": "ListItem", position: 1, name: "Home", item: SITE },
      { "@type": "ListItem", position: 2, name: "Guides", item: `${SITE}/guides` },
      { "@type": "ListItem", position: 3, name: page.title, item: url },
    ],
  };
  const blocks = [article, crumbs];
  if (page.faq && page.faq.length) {
    blocks.push({
      "@context": "https://schema.org", "@type": "FAQPage",
      mainEntity: page.faq.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })),
    });
  }
  return blocks.map((b) => `<script type="application/ld+json">${JSON.stringify(b)}</script>`).join("\n");
}
```

In `renderPage`, add `const schema = jsonLd(page, url);` after `url` is computed, insert `${schema}` just before `</head>`, and add a visible breadcrumb above the `<h1>` inside `<article>`:

```js
  <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> › <a href="/guides">Guides</a> › <span>${esc(page.title)}</span></nav>
```

- [ ] **Step 4: Pass `faq` through in `build.mjs`**

In the `pages.push({...})` object, add: `faq: data.faq || null,`

- [ ] **Step 5: Run — expect PASS**

Run: `cd site && npm test`
Expected: all tests pass; `_smoke.html` now contains Article + BreadcrumbList `<script type="application/ld+json">` blocks.

- [ ] **Step 6: Commit**

```bash
git add site/template.js site/build.mjs site/test.mjs
git commit -m "feat(site): Article/BreadcrumbList/FAQ JSON-LD + visible breadcrumb"
```

---

## Task 4: Article styling, CTA, nav link, and OG image

Visual layer: long-form typography, the shared CTA block, the breadcrumb/guide-list styles, the "Guides" nav link on existing pages, and the branded OG image.

**Files:**
- Modify: `site/public/site.css`
- Modify: `site/template.js` (inject CTA into every guide)
- Modify: `site/build.mjs` (append CTA to body)
- Modify: `site/public/index.html`, `pricing.html`, `support.html`, `privacy.html`, `terms.html` (nav link)
- Create: `site/public/assets/og-card.html` (source for the OG image)
- Create: `site/public/assets/og-default.png` (rendered)

**Interfaces:**
- Consumes: `renderPage`, body HTML.
- Produces: CTA HTML is appended to every guide's `bodyHtml` by `build.mjs` via the exported constant `CTA_HTML` from `template.js`.

- [ ] **Step 1: Add `CTA_HTML` constant to `template.js`**

Add at module level and to the export list:

```js
export const CTA_HTML = `<aside class="ctaBlock">
  <h2>Stop typing receipts.</h2>
  <p>Snapceipt reads the merchant, total, GST and category from a photo — instantly. Made in Australia for sole traders &amp; households.</p>
  <a class="badge" href="${APP_URL}" aria-label="Download Snapceipt on the App Store"><img src="/assets/app-store-badge.svg" alt="Download on the App Store"></a>
</aside>`;
```

- [ ] **Step 2: Append CTA to each guide body in `build.mjs`**

Import it: change the template import to `import renderPage, { renderIndex, CTA_HTML } from "./template.js";`
In the `pages.push`, change `bodyHtml: marked.parse(content),` to:

```js
      bodyHtml: marked.parse(content) + CTA_HTML,
```

- [ ] **Step 3: Append article styles to `site/public/site.css`**

```css
/* ---- guides / long-form articles ---- */
.crumbs{font-size:13px;color:var(--ink3);margin:28px 0 8px;}
.crumbs a{color:var(--ink2);text-decoration:none;}
.crumbs a:hover{color:var(--ink);}
.article{padding-bottom:64px;}
.article h1{font-family:Fraunces;font-weight:600;font-size:38px;line-height:1.15;letter-spacing:-.5px;margin:6px 0 22px;}
.article h2{font-family:Fraunces;font-weight:600;font-size:26px;margin:38px 0 12px;}
.article h3{font-size:20px;font-weight:600;margin:28px 0 10px;}
.article p,.article li{color:var(--ink);font-size:17px;line-height:1.7;}
.article p,.article ul,.article ol{margin:0 0 18px;}
.article ul,.article ol{padding-left:22px;}
.article li{margin:6px 0;}
.article a{color:var(--terra2);text-decoration:underline;text-underline-offset:2px;}
.article blockquote{border-left:3px solid var(--terra);padding:4px 0 4px 18px;margin:0 0 18px;color:var(--ink2);font-style:italic;}
.guideList{list-style:none;padding:0;margin:24px 0 64px;}
.guideList li{padding:18px 0;border-bottom:1px solid var(--line);}
.guideList li a{font-family:Fraunces;font-size:21px;color:var(--ink);text-decoration:none;}
.guideList li a:hover{color:var(--terra2);}
.guideList li p{color:var(--ink2);font-size:15px;margin:6px 0 0;}
.ctaBlock{background:var(--cream2);border:1px solid var(--line);border-radius:18px;padding:32px;margin:40px 0 0;text-align:center;}
.ctaBlock h2{font-family:Fraunces;font-weight:600;font-size:24px;margin:0 0 8px;}
.ctaBlock p{color:var(--ink2);max-width:520px;margin:0 auto 18px;}
.ctaBlock .badge{justify-content:center;}
```

- [ ] **Step 4: Add the "Guides" nav link to existing static pages**

In each of `site/public/index.html`, `pricing.html`, `support.html`, `privacy.html`, `terms.html`, inside the `<div class="links">` of the `<nav>`, add as the FIRST child link:

```html
      <a href="/guides">Guides</a>
```

(Place it before the existing first link in each file's `.links` block. If a page's nav differs, match its surrounding indentation.)

- [ ] **Step 5: Create the OG card source `site/public/assets/og-card.html`**

```html
<!doctype html><html><head><meta charset="utf-8">
<style>
  html,body{margin:0}
  .card{width:1200px;height:630px;background:#FBF6F0;display:flex;flex-direction:column;justify-content:center;padding:80px;box-sizing:border-box;font-family:Georgia,serif}
  .logo{font-size:44px;color:#211C18;font-weight:600}
  .logo b{color:#E8602C}
  h1{font-size:72px;color:#211C18;margin:24px 0 0;line-height:1.1;max-width:900px}
  p{font-size:30px;color:#6B6258;font-family:Arial,sans-serif;margin-top:28px}
</style></head>
<body><div class="card">
  <div class="logo">Snap<b>ceipt</b></div>
  <h1>Receipts &amp; expenses, sorted for tax.</h1>
  <p>Made in Australia for sole traders &amp; households</p>
</div></body></html>
```

- [ ] **Step 6: Render the OG card to PNG (1200×630)**

Open `site/public/assets/og-card.html` in a headless browser sized to 1200×630 and screenshot to `site/public/assets/og-default.png`. Use the project's available browser automation (e.g. the `browse` skill or `mcp__claude-in-chrome` screenshot) at exactly 1200×630, no device chrome. If no automation is available, open the file in any browser at that viewport and save the screenshot to that path.

Verify: `file site/public/assets/og-default.png` reports a PNG ~1200×630.

- [ ] **Step 7: Rebuild and verify CTA + styling present**

Run: `cd site && npm run build && npm test`
Expected: build succeeds, all tests pass; `site/public/guides/_smoke.html` contains `class="ctaBlock"`.

- [ ] **Step 8: Commit**

```bash
git add site/public/site.css site/template.js site/build.mjs site/public/index.html site/public/pricing.html site/public/support.html site/public/privacy.html site/public/terms.html site/public/assets/og-card.html site/public/assets/og-default.png
git commit -m "feat(site): article styling, shared CTA, Guides nav link, OG image"
```

---

## Task 5: Phase-1 content — pillar + 2 spokes

Writes the first three real articles, removes the smoke fixture, and ships. **This is content authoring, not code:** write genuinely useful prose in the Snapceipt voice (warm, plain-English, AU). Each numbered ATO fact below MUST be verified against current ATO guidance (ato.gov.au) before publishing — do not assert from memory.

**Files:**
- Create: `site/content/guides/track-business-expenses-australia.md`
- Create: `site/content/guides/organise-receipts-for-tax.md`
- Create: `site/content/guides/do-you-need-paper-receipts-ato.md`
- Delete: `site/content/guides/_smoke.md`
- Modify: `site/.gitignore` (drop the `_smoke` ignore line)

**Interfaces:**
- Consumes: frontmatter schema (Task 1), `faq` field (Task 3). Slugs must match the `related` cross-references below exactly.

- [ ] **Step 1: Verify the ATO facts to be cited**

Confirm each against current ATO guidance and note the source URL in your working notes (not in the article):
1. How long records must be kept (commonly 5 years from lodgment) — confirm the exact period and start point.
2. The receipt substantiation threshold for work-related expenses (commonly $300 total / individual receipt rules) — confirm current figures and what they apply to.
3. Whether digital/photographed copies of receipts are acceptable and any legibility/retention conditions.
4. The GST registration turnover threshold (commonly $75,000) — confirm current figure.

If any figure differs from the "commonly" note above, use the verified figure.

- [ ] **Step 2: Write the pillar `track-business-expenses-australia.md`**

Frontmatter (exact):

```yaml
---
title: "How to Track Business Expenses in Australia (2026 Guide)"
description: "A practical, plain-English guide to tracking business expenses in Australia — what to record, how to keep receipts the ATO accepts, and GST basics."
slug: track-business-expenses-australia
role: pillar
keywords: [track business expenses, business expenses australia, sole trader expenses, ATO records]
related: [organise-receipts-for-tax, do-you-need-paper-receipts-ato]
updated: 2026-06-28
faq:
  - q: "How long do I need to keep business records in Australia?"
    a: "<verified answer to fact #1>"
  - q: "Do I need to keep the paper receipt or is a photo enough?"
    a: "<verified answer to fact #3>"
  - q: "When do I have to register for GST?"
    a: "<verified answer to fact #4>"
---
```

Body outline (write ~900–1200 words of real prose under these H2s; weave the AU/ATO angle throughout; link to both spokes via Markdown links `[anchor](/guides/<slug>)`):
- Intro: why expense tracking matters for AU sole traders/small business (deductions, BAS, peace of mind at tax time).
- **What counts as a business expense** — deductible vs not, the "incurred in earning income" principle.
- **What to record for every expense** — date, supplier, amount, GST, business purpose.
- **Keeping receipts the ATO accepts** — verified fact #2 + #3; link to `/guides/do-you-need-paper-receipts-ato` and `/guides/organise-receipts-for-tax`.
- **GST basics** — verified fact #4; what GST-inclusive means on a receipt.
- **A simple monthly routine** — capture as you go, review monthly, export at BAS/tax time. (Mention Snapceipt naturally once here; the CTA block is auto-appended.)

- [ ] **Step 3: Write spoke `organise-receipts-for-tax.md`**

Frontmatter (exact):

```yaml
---
title: "How to Organise Receipts for Tax (Without the Shoebox)"
description: "Stop hoarding paper. A simple system to organise receipts for tax in Australia — capture, categorise, and find any receipt in seconds."
slug: organise-receipts-for-tax
role: spoke
keywords: [organise receipts for tax, receipt organisation, digital receipts]
related: [track-business-expenses-australia, do-you-need-paper-receipts-ato]
updated: 2026-06-28
---
```

Body (~700–900 words): the shoebox problem → capture-at-point-of-purchase → categorise by ATO-friendly categories → digital backup → retrieval at tax time. Link up to the pillar and across to `do-you-need-paper-receipts-ato`.

- [ ] **Step 4: Write spoke `do-you-need-paper-receipts-ato.md`**

Frontmatter (exact):

```yaml
---
title: "Do You Need to Keep Paper Receipts? What the ATO Requires"
description: "Can you throw out paper receipts in Australia? What the ATO actually requires for records, retention periods, and digital copies — explained simply."
slug: do-you-need-paper-receipts-ato
role: spoke
keywords: [keep paper receipts, ATO records, how long keep receipts]
related: [track-business-expenses-australia, organise-receipts-for-tax]
updated: 2026-06-28
---
```

Body (~700–900 words): the direct answer up front (digital copies acceptable per verified fact #3) → retention period (verified fact #1) → substantiation threshold (verified fact #2) → conditions (legible, complete) → practical takeaway. Link up to pillar + across to `organise-receipts-for-tax`.

- [ ] **Step 5: Remove the smoke fixture and its ignore line**

```bash
git rm site/content/guides/_smoke.md
```

Edit `site/.gitignore` to remove the `public/guides/_smoke.html` line, then `rm -f site/public/guides/_smoke.html`.

- [ ] **Step 6: Build + test**

Run: `cd site && npm run build && npm test`
Expected: `Built 3 guide(s) + index + sitemap.`; all tests pass (3 pages now have Article+BreadcrumbList; pillar also has FAQPage); sitemap lists the 3 real slugs and no `_smoke`.

- [ ] **Step 7: Local visual verification**

Run: `cd site && npx wrangler dev`
Then load `http://localhost:8787/guides`, `/guides/track-business-expenses-australia`, and one spoke. Confirm: clean URLs resolve (no `.html`), breadcrumb + CTA render, internal links work, styling matches the site. Validate the pillar's HTML source through Google's Rich Results test (paste the rendered HTML) — Article + FAQ should be detected.

- [ ] **Step 8: Commit**

```bash
git add site/content/guides/ site/public/guides/ site/public/sitemap.xml site/.gitignore
git commit -m "feat(site): phase-1 guides — expense-tracking pillar + 2 spokes"
```

- [ ] **Step 9: Deploy**

Run: `cd site && npm run deploy`
Expected: build + tests run, then `wrangler deploy` publishes. Verify live: `https://snapceipt.cc/guides/track-business-expenses-australia` loads, `https://snapceipt.cc/sitemap.xml` includes the 3 guides.

---

## Task 6: ASO tune-up (metadata only)

Reclaims wasted keyword characters and refreshes promotional text. No app code, no screenshots.

**Files:**
- Modify: `fastlane/metadata/en-AU/keywords.txt`
- Modify: `fastlane/metadata/en-AU/promotional_text.txt`

**Interfaces:** none (text files consumed by fastlane `deliver`).

- [ ] **Step 1: Confirm current name + subtitle (to avoid keyword dupes)**

Run: `cat fastlane/metadata/en-AU/name.txt fastlane/metadata/en-AU/subtitle.txt`
Expected: `Snapceipt — Receipts & GST` and `Expenses, GST & BAS, sorted`. Words already covered (do NOT repeat in keywords): receipt, receipts, gst, expenses, bas.

- [ ] **Step 2: Rewrite `fastlane/metadata/en-AU/keywords.txt`**

Replace contents with (single line, no spaces after commas, ≤100 chars, none of the covered words above):

```
scanner,tracker,ATO,deduction,mileage,logbook,sole trader,small business,invoice,quote,bookkeeping
```

Verify length: `awk '{print length}' fastlane/metadata/en-AU/keywords.txt` → must be ≤ 100. If over, drop `bookkeeping` then `invoice` until it fits.

- [ ] **Step 3: Refresh `fastlane/metadata/en-AU/promotional_text.txt`**

Replace with (≤170 chars):

```
Snap a receipt — Snapceipt reads the merchant, total, GST and category instantly. Sorted for tax time, made in Australia. Now with quotes & invoices.
```

Verify length: `awk '{print length}' fastlane/metadata/en-AU/promotional_text.txt` → must be ≤ 170.

- [ ] **Step 4: Commit**

```bash
git add fastlane/metadata/en-AU/keywords.txt fastlane/metadata/en-AU/promotional_text.txt
git commit -m "chore(aso): reclaim duplicate keyword chars + refresh promo text"
```

- [ ] **Step 5: Record the deploy split (no code)**

Note for the operator (do not script):
- `promotional_text` is live-editable — push now: `bundle exec fastlane deliver --skip_binary_upload true --skip_screenshots true --skip_metadata false` (or edit promo text directly in App Store Connect).
- `keywords.txt` change rides the NEXT app version (1.0.x) — it cannot ship while the current version is `WAITING_FOR_REVIEW`. It will be picked up automatically by the next `fastlane release`.

---

## Self-Review Notes

- **Spec coverage:** generator/architecture (T1–T2), SEO mechanics incl. JSON-LD/sitemap/canonical/OG (T1–T4), content cluster pillar+2 spokes for Phase 1 (T5), AU differentiation + fact-check gate (T5 Step 1), ASO keyword reclaim + promo refresh + deploy-split constraint (T6), Phase-2 remaining spokes = repeat T5 pattern per `.md` (noted). GSC property creation is an external manual prerequisite called out in the spec — it is not a code task and is intentionally omitted from the task list; flag to the operator at hand-off.
- **Type consistency:** `Page` shape, `build({contentDir,outDir,publicDir})`, `renderPage`/`renderIndex`/`CTA_HTML`/`jsonLd` names are consistent across T1–T4. Slugs in `related` cross-references match the filenames in T5.
- **Placeholder note:** the `<verified answer ...>` and `<slug>` markers in T5 are content the author writes after fact-checking — this is inherent to content authoring, not a code placeholder; the exact facts to verify are enumerated in T5 Step 1.
