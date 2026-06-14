# Marketing Site Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder `snapceipt.cc` site with a four-page Warm Editorial marketing site (landing + auto-play demo, pricing, privacy, support) served by the existing assets-only Cloudflare Worker.

**Architecture:** Static HTML/CSS under `site/public/`, one shared stylesheet (`site.css`) for the design system, a small inline `<script>` for the landing-page auto-play demo. No framework, no bundler, no server runtime, no new dependencies. Cloudflare serves `./public` directly with `html_handling` (so `/pricing` → `pricing.html`).

**Tech Stack:** HTML5, CSS (custom properties, Google Fonts: Fraunces + Inter; Schibsted Grotesk + Hanken Grotesk inside the demo), vanilla JS (IntersectionObserver), Cloudflare Workers assets, `wrangler` v4 for local serve + deploy.

---

## Spec & content source of truth

- **Spec:** `docs/superpowers/specs/2026-06-15-marketing-site-redesign-design.md`
- **Approved visual previews** (gitignored, under `.superpowers/brainstorm/29812-1781449159/content/`):
  - `landing-v2.html` → port to `index.html` (full landing + auto-play demo)
  - `pages.html` → its three `<script type="text/template">` blocks `tplPricing` / `tplPrivacy` / `tplSupport` are the body content for `pricing.html` / `privacy.html` / `support.html`
- **Rule for "port from preview":** copy the `<body>` markup verbatim from the named preview, then apply the explicit production deltas listed in that task (link `site.css` instead of an inline `<style>`, swap to the shared badge include, add `<head>` meta/OG, fix `href`s to real routes, add accessibility attributes). The previews are the authoritative content; do not paraphrase copy.

## File structure

| File | Action | Responsibility |
|---|---|---|
| `site/public/site.css` | **Create** | Shared design system: tokens, nav, footer, badge, buttons, + all page sections |
| `site/public/index.html` | **Rewrite** | Landing page + auto-play demo (inline `<script>`) |
| `site/public/pricing.html` | **Create** | Pricing page (Free + Pro, compare matrix, billing FAQ) |
| `site/public/privacy.html` | **Rewrite** | Privacy policy (Apple 5.1.1 + APP) |
| `site/public/support.html` | **Rewrite** | Support page (Apple-compliant contact + FAQ) |
| `site/public/assets/app-store-badge.svg` | **Create** | "Download on the App Store" badge artwork |
| `site/public/favicon.svg` | **Create** | Snapceipt favicon |
| `site/public/robots.txt` | **Create** | Allow-all + sitemap pointer |
| `site/public/sitemap.xml` | **Create** | Four URLs |
| `site/wrangler.jsonc` | **Verify only** | Confirm assets/routing unchanged |

## Conventions used by every task

- **App Store badge link:** `https://apps.apple.com/au/app/id6778894594`
- **Support email:** `support@snapceipt.cc`
- **Local serve (used in every verify step):**
  ```bash
  cd site && npx --yes wrangler@4 dev --port 8788 --local
  ```
  Run it in the background; stop it after checks. (Assets-only dev honours `html_handling`, so `/pricing` resolves to `pricing.html`.) If `wrangler dev` is inconvenient in your environment, any static file server rooted at `site/public` works for content checks, but only `wrangler dev` reproduces extension-less routing.
- **Commit style:** `feat(site): …` / `chore(site): …`, on branch `feature/marketing-site-redesign` (already created).

---

### Task 1: Shared stylesheet + brand assets

**Files:**
- Create: `site/public/site.css`
- Create: `site/public/assets/app-store-badge.svg`
- Create: `site/public/favicon.svg`

- [ ] **Step 1: Create the App Store badge SVG**

Create `site/public/assets/app-store-badge.svg`. This is a faithful, self-contained "Download on the App Store" badge. **Before public launch, replace it with Apple's official badge artwork** (Apple Marketing Resources) to comply with Apple's identity guidelines — keep the same filename so no markup changes are needed.

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="160" height="54" viewBox="0 0 160 54" role="img" aria-label="Download on the App Store">
  <rect width="160" height="54" rx="12" fill="#1A1A1A"/>
  <path fill="#fff" d="M40.9 27.3c0-3.1 2.5-4.6 2.6-4.7-1.4-2.1-3.6-2.3-4.4-2.4-1.9-.2-3.6 1.1-4.6 1.1-.9 0-2.4-1.1-3.9-1-2 0-3.9 1.2-4.9 3-2.1 3.7-.5 9.1 1.5 12.1 1 1.5 2.2 3.1 3.7 3 1.5-.1 2-1 3.8-1s2.3 1 3.9.9c1.6 0 2.6-1.5 3.6-2.9 1.1-1.7 1.6-3.3 1.6-3.4-.1 0-3-1.2-3-4.8zm-3-8.8c.8-1 1.4-2.4 1.2-3.8-1.2.1-2.7.8-3.5 1.8-.8.9-1.5 2.3-1.3 3.7 1.3.1 2.7-.7 3.6-1.7z"/>
  <text x="54" y="21" fill="#fff" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="9" opacity="0.9">Download on the</text>
  <text x="54" y="39" fill="#fff" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="18" font-weight="600">App Store</text>
</svg>
```

- [ ] **Step 2: Create the favicon SVG**

Create `site/public/favicon.svg` — a rounded terracotta tile with an "S".

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="15" fill="#E8602C"/>
  <text x="32" y="44" text-anchor="middle" fill="#fff" font-family="Georgia,'Times New Roman',serif" font-size="38" font-weight="700">S</text>
</svg>
```

- [ ] **Step 3: Create `site.css` — design tokens + shared components**

Create `site/public/site.css`. Start with the shared core (tokens, base, nav, badge, buttons, footer). These rules are used by all four pages.

```css
/* ===== Snapceipt site — shared design system (Warm Editorial) ===== */
:root{
  --cream:#FBF6F0; --cream2:#F4EADD; --ink:#211C18; --ink2:#6B6258; --ink3:#A99F93;
  --terra:#E8602C; --terra2:#C2461A; --teal:#0E7C72; --teal2:#0a5f57; --line:#EADFCE;
  --card:#fff; --income:#1F9D6B;
}
*{box-sizing:border-box;margin:0;}
html{scroll-behavior:smooth;}
body{background:var(--cream);color:var(--ink);font:17px/1.6 Inter,sans-serif;-webkit-font-smoothing:antialiased;}
a{color:inherit;}
.wrap{max-width:1140px;margin:0 auto;padding:0 28px;}
.wrap-narrow{max-width:900px;margin:0 auto;padding:0 28px;}
.fr{font-family:Fraunces,serif;}
.kicker{font-size:13px;letter-spacing:2px;text-transform:uppercase;color:var(--terra2);font-weight:600;}

/* nav */
.nav{display:flex;align-items:center;gap:28px;padding:24px 0;position:sticky;top:0;background:rgba(251,246,240,.86);backdrop-filter:blur(10px);z-index:30;border-bottom:1px solid transparent;}
.nav.scrolled{border-bottom:1px solid var(--line);}
.logo{font-family:Fraunces;font-weight:600;font-size:23px;letter-spacing:-.3px;text-decoration:none;color:var(--ink);}
.logo b{color:var(--terra);}
.nav .links{margin-left:auto;display:flex;gap:26px;font-size:15px;color:var(--ink2);align-items:center;}
.nav .links a{color:var(--ink2);text-decoration:none;}
.nav .links a:hover{color:var(--ink);}
.navbadge{display:inline-flex;align-items:center;gap:8px;background:var(--ink);color:#fff !important;padding:9px 15px;border-radius:11px;text-decoration:none;font-weight:600;font-size:14px;}

/* App Store badge (image) */
.badge{display:inline-flex;transition:transform .15s;}
.badge:hover{transform:translateY(-2px);}
.badge img{height:54px;width:auto;display:block;}
.ghost{color:var(--ink);font-weight:600;text-decoration:none;border-bottom:2px solid var(--terra);padding-bottom:2px;}
.ghost:hover{color:var(--terra2);}

/* footer */
.footer{border-top:1px solid var(--line);margin-top:8px;}
.footer .inner{padding:40px 28px;max-width:1140px;margin:0 auto;color:var(--ink2);font-size:14px;display:flex;gap:24px;align-items:center;flex-wrap:wrap;}
.footer a{color:var(--ink2);text-decoration:none;}
.footer a:hover{color:var(--ink);}
.footer .sp{margin-left:auto;}

/* section primitives */
.sec{padding:64px 0;border-top:1px solid var(--line);}
.sec h2{font-family:Fraunces;font-weight:500;font-size:40px;letter-spacing:-.6px;margin-top:12px;}
.sec .intro{color:var(--ink2);margin-top:14px;max-width:34em;font-size:18px;}

@media(max-width:880px){
  .nav .links a:not(.navbadge){display:none;}
}
```

- [ ] **Step 4: Append page-section CSS to `site.css`**

Append the page-specific rules. Port the `<style>` rule bodies from the previews, namespaced as they already are, into one file (hero, phone/device, demo, features, pricing plans/table, privacy prose/glance/table, support topics/cards). Source blocks:
- From `landing-v2.html` `<style>`: `.hero`, `h1`, `.lede`, `.cta`, `.tagline`, `.device`/`.app`/`.h-*`/`.tabbar`/`.fab`, `.demoSec`/`.demoStage`/`.demoSteps`/`.dStep`/`.scenes`/`.scene`/all `@keyframes` (`tap`,`scan`,`dots`,`pop`,`popin`)/`.cam`/`.receiptImg`/`.scanline`/`.ex*`/`.ok*`, `.steps`/`.step`, `.grid`/`.f`, `.alsoline`, `.ptease`/`.plan`, `.band`/`.bullets`, `details`/`summary`/`.faqwrap`, `.final`.
- From `pages.html` `tplPricing` `<style>`: `.plans`/`.plan`/`.price`/`.pcta`/`.plist`, `.cmp`/`table`/`th`/`td`/`.yes`/`.no`/`.lim`, `.why`, pricing `.faq`.
- From `pages.html` `tplPrivacy` `<style>`: `.glance`/`.glist`/`.gi`, `.table`/`.tr`/`.th`/`.c`, `.callout2`, privacy headings/prose.
- From `pages.html` `tplSupport` `<style>`: `.contact`/`.cbtn`/`.resp`, `.topics`/`.topic`, support `.faq`, `.info`/`.infocard`.

Remove duplicate token/nav/footer/badge declarations (now in the shared core). Keep the malformed values already fixed in previews (`#cdbfad`; no stray `.callout`).

- [ ] **Step 5: Verify the CSS parses (no syntax errors)**

Run:
```bash
npx --yes csstree-validator site/public/site.css || echo "review any reported errors"
```
Expected: no fatal parse errors (warnings about vendor prefixes are fine). If `csstree-validator` is unavailable, open `site.css` and confirm balanced braces.

- [ ] **Step 6: Commit**

```bash
git add site/public/site.css site/public/assets/app-store-badge.svg site/public/favicon.svg
git commit -m "feat(site): shared site.css design system + app-store badge + favicon"
```

---

### Task 2: Landing page (`index.html`) + auto-play demo

**Files:**
- Modify (rewrite): `site/public/index.html`
- Reference: `.superpowers/brainstorm/29812-1781449159/content/landing-v2.html`

- [ ] **Step 1: Write `index.html` head + ported body**

Rewrite `site/public/index.html`. Use this `<head>` (note shared CSS link, fonts, meta/OG, favicon):

```html
<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Snapceipt — snap receipts, sorted for tax</title>
<meta name="description" content="Snap a receipt and Snapceipt reads the merchant, total, GST and category for you — instantly. Cloud-synced, private, made in Australia for sole traders & households.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="https://snapceipt.cc/">
<meta property="og:type" content="website">
<meta property="og:title" content="Snapceipt — snap receipts, sorted for tax">
<meta property="og:description" content="Snap a receipt and Snapceipt reads the merchant, total, GST and category for you. Made in Australia.">
<meta property="og:url" content="https://snapceipt.cc/">
<meta property="og:image" content="https://snapceipt.cc/favicon.svg">
<meta name="twitter:card" content="summary">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,500;0,9..144,600;1,9..144,500&family=Inter:wght@400;500;600&family=Schibsted+Grotesk:wght@500;600;700;800&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/site.css">
</head>
<body>
```

Then copy the `<body>` inner markup from `landing-v2.html` with these deltas:
- `<nav id="nav">` → `<nav id="nav" class="nav">` (use shared class).
- Replace every hand-coded badge (`<a class="badge" …><svg>…</svg><span class="t">…</span></a>`) with the shared image badge:
  ```html
  <a class="badge" href="https://apps.apple.com/au/app/id6778894594" aria-label="Download Snapceipt on the App Store"><img src="/assets/app-store-badge.svg" alt="Download on the App Store"></a>
  ```
  (Nav "Get the app" stays as `.navbadge` text link pointing to the same URL.)
- Real links: nav/footer hrefs → `#demo`, `#features`, `#pricing` (on-page), and footer Privacy/Support → `/privacy`, `/support`; "Compare plans in full →" → `/pricing`.
- Mark the demo device decorative for AT: on `<div class="device" id="demoDevice" …>` add `aria-hidden="true"`. The visible 3-step legend (`.demoSteps`) is the text equivalent.
- Close with `</body></html>` after the script in Step 2.

- [ ] **Step 2: Add the demo script + reduced-motion guard**

Before `</body>`, add the nav-scroll + demo loop script (ported from `landing-v2.html`) wrapped so it respects reduced motion:

```html
<script>
  var nav=document.getElementById('nav');
  addEventListener('scroll',function(){ nav.classList.toggle('scrolled', scrollY>8); });

  (function(){
    var dev=document.getElementById('demoDevice');
    if(!dev) return;
    var steps=document.querySelectorAll('.dStep');
    var sceneToStep=[0,0,1,2], durations=[2600,2200,2800,2400];
    var scene=0,timer=null,running=false;
    function render(){ dev.setAttribute('data-scene',scene);
      var st=sceneToStep[scene];
      steps.forEach(function(s){ s.classList.toggle('on', +s.dataset.step===st); }); }
    function tick(){ scene=(scene+1)%4; render(); timer=setTimeout(tick,durations[scene]); }
    function start(){ if(running)return; running=true; render(); timer=setTimeout(tick,durations[scene]); }
    function stop(){ running=false; clearTimeout(timer); }
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if(reduce){ scene=2; render(); return; }   // static "extracted" frame, no animation
    render();
    if('IntersectionObserver' in window){
      new IntersectionObserver(function(es){ es.forEach(function(e){ e.isIntersecting?start():stop(); }); },{threshold:.3}).observe(dev);
    } else { start(); }
  })();
</script>
</body>
</html>
```

Also add this rule to `site.css` (reduced-motion: freeze cross-fades/animations) and commit it with this task:
```css
@media (prefers-reduced-motion: reduce){
  *{animation-duration:.001ms !important;animation-iteration-count:1 !important;transition-duration:.001ms !important;scroll-behavior:auto !important;}
  .scene{transition:none;}
}
```

- [ ] **Step 3: Serve and verify content + the demo**

Start `cd site && npx --yes wrangler@4 dev --port 8788 --local` (background), then:
```bash
curl -s http://localhost:8788/ -o /tmp/idx.html
grep -c 'site.css\|app-store-badge.svg\|id="demo"\|Every receipt\|Start free\|prefers-reduced-motion' /tmp/idx.html
```
Expected: all markers present (count ≥ 6). Open `http://localhost:8788/` in a browser: confirm the demo loops (Home→Camera→Extract→Sorted), the step legend tracks it, the nav gains a hairline on scroll, and the badge image renders. Toggle OS "Reduce Motion" and reload: the demo should sit on a static frame.

- [ ] **Step 4: Commit**

```bash
git add site/public/index.html site/public/site.css
git commit -m "feat(site): landing page with auto-play demo + reduced-motion fallback"
```

---

### Task 3: Pricing page (`pricing.html`)

**Files:**
- Create: `site/public/pricing.html`
- Reference: `pages.html` → `tplPricing`

- [ ] **Step 1: Write `pricing.html`**

Create `site/public/pricing.html`. `<head>` mirrors Task 2 with pricing-specific title/description/canonical:
```html
<title>Pricing — Snapceipt</title>
<meta name="description" content="Snapceipt is free to capture and sort receipts. Go Pro for BAS-ready export, quotes, logbooks and email-in — $9.99/month or $79/year.">
<link rel="canonical" href="https://snapceipt.cc/pricing">
```
(Include the same favicon, OG tags adjusted, Fraunces+Inter+Schibsted Grotesk fonts, and `<link rel="stylesheet" href="/site.css">`.)

Body: port the `tplPricing` markup from `pages.html` with deltas:
- Outer container class `row` → reuse as-is (its CSS is in `site.css`) **or** rename to `.wrap`; keep whichever you ported the CSS under. (If you ported `.row` rules, keep `.row`.)
- `<nav>` → add shared class: `<nav class="nav">`.
- Plan CTAs: Free card `Download on the App Store` → wrap as the image badge linking to the App Store URL; Pro card "Start 14-day free trial" stays a styled `.pcta terra` linking to the App Store URL.
- Footer: use the shared `.footer` structure; links `/privacy`, `/support`, `mailto:support@snapceipt.cc`.

- [ ] **Step 2: Serve and verify**

With `wrangler dev` running:
```bash
curl -s http://localhost:8788/pricing -o /tmp/pricing.html
grep -c 'Compare plans\|\$9.99\|\$79\|14-day free trial\|BAS-ready export\|incl. GST\|Apple ID' /tmp/pricing.html
```
Expected: markers present (≥ 6). Visually confirm: Pro card highlighted with "Most popular", the 12-row compare table renders, FAQ accordions open/close.

- [ ] **Step 3: Commit**

```bash
git add site/public/pricing.html
git commit -m "feat(site): pricing page (Free + Pro, compare matrix, billing FAQ)"
```

---

### Task 4: Privacy page (`privacy.html`)

**Files:**
- Modify (rewrite): `site/public/privacy.html`
- Reference: `pages.html` → `tplPrivacy`

- [ ] **Step 1: Write `privacy.html`**

Rewrite `site/public/privacy.html`. `<head>`:
```html
<title>Privacy Policy — Snapceipt</title>
<meta name="description" content="How Snapceipt collects, uses and protects your data. No ads, no trackers, no data selling. Delete your account any time.">
<link rel="canonical" href="https://snapceipt.cc/privacy">
```
(Favicon, Fraunces + Inter only — no demo fonts needed — and `/site.css`.)

Body: port `tplPrivacy` markup with deltas: `<nav class="nav">`; shared `.footer`; keep the effective/updated dates current (15 June 2026); ensure the processor list (Cloudflare, DeepSeek, Cloudflare Workers AI, Apple), the overseas-transfer callout, and the **Account → Delete Account** instructions are intact.

- [ ] **Step 2: Serve and verify the Apple/APP compliance markers**

```bash
curl -s http://localhost:8788/privacy -o /tmp/privacy.html
grep -c 'Delete Account\|DeepSeek\|Cloudflare\|Workers AI\|Apple\|outside Australia\|Australian Privacy Principles\|support@snapceipt.cc\|30 days' /tmp/privacy.html
```
Expected: all markers present (≥ 8). These map directly to the spec §8 compliance checklist (data disclosure, named processors, overseas transfer, account deletion, retention, contact).

- [ ] **Step 3: Commit**

```bash
git add site/public/privacy.html
git commit -m "feat(site): redesigned privacy policy (Apple 5.1.1 + APP, enriched)"
```

---

### Task 5: Support page (`support.html`)

**Files:**
- Modify (rewrite): `site/public/support.html`
- Reference: `pages.html` → `tplSupport`

- [ ] **Step 1: Write `support.html`**

Rewrite `site/public/support.html`. `<head>`:
```html
<title>Support — Snapceipt</title>
<meta name="description" content="Help with Snapceipt — capturing receipts, signing in, sync, GST &amp; BAS export, subscriptions and deleting your account. Email support@snapceipt.cc.">
<link rel="canonical" href="https://snapceipt.cc/support">
```
(Favicon, Fraunces + Inter, `/site.css`.)

Body: port `tplSupport` markup with deltas: `<nav class="nav">`; shared `.footer`; keep the working `mailto:` contact, the manage/cancel-subscription + Restore Purchases FAQ, the delete-account FAQ, and the iOS 17+ system requirement.

- [ ] **Step 2: Serve and verify**

```bash
curl -s http://localhost:8788/support -o /tmp/support.html
grep -c 'support@snapceipt.cc\|Delete Account\|Subscriptions\|Restore Purchases\|iOS 17\|magic-link\|2 business days' /tmp/support.html
```
Expected: markers present (≥ 6).

- [ ] **Step 3: Commit**

```bash
git add site/public/support.html
git commit -m "feat(site): redesigned support page (Apple-compliant contact + FAQ)"
```

---

### Task 6: SEO/robots, cross-page link audit, and full verification

**Files:**
- Create: `site/public/robots.txt`
- Create: `site/public/sitemap.xml`
- Verify: `site/wrangler.jsonc`

- [ ] **Step 1: Create `robots.txt`**

```
User-agent: *
Allow: /
Sitemap: https://snapceipt.cc/sitemap.xml
```

- [ ] **Step 2: Create `sitemap.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://snapceipt.cc/</loc></url>
  <url><loc>https://snapceipt.cc/pricing</loc></url>
  <url><loc>https://snapceipt.cc/privacy</loc></url>
  <url><loc>https://snapceipt.cc/support</loc></url>
</urlset>
```

- [ ] **Step 3: Confirm `wrangler.jsonc` needs no change**

Open `site/wrangler.jsonc`; confirm `assets.directory` is `./public` and the custom-domain routes are intact. No edit expected.

- [ ] **Step 4: Cross-page link + routing audit**

With `wrangler dev` running, check every route returns 200 and internal links resolve:
```bash
for p in / /pricing /privacy /support /site.css /assets/app-store-badge.svg /favicon.svg /robots.txt /sitemap.xml; do
  printf "%s -> " "$p"; curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8788$p";
done
```
Expected: all `200`. Then grep each HTML page for only-valid internal hrefs (`/`, `/pricing`, `/privacy`, `/support`, `#…`, `mailto:`, the App Store URL) — no leftover `href="#"` placeholders on primary CTAs.

- [ ] **Step 5: Responsive + accessibility spot check**

In the browser dev tools, view each page at 375px width: nav collapses (badge visible), grids stack, no horizontal scroll. Confirm: headings are sequential, links have visible focus, badge `<img>` has alt text, the demo device is `aria-hidden`. (Optional: run the project's `gstack browse`/`qa` skill for automated screenshots across the four routes.)

- [ ] **Step 6: Commit**

```bash
git add site/public/robots.txt site/public/sitemap.xml
git commit -m "chore(site): robots.txt + sitemap.xml; finalize link/routing audit"
```

---

### Task 7: Deploy (run by the site owner)

**Files:** none (uses committed `site/`).

> Requires Cloudflare auth for the `snapceipt-site` Worker (account `techsiderau@gmail.com`). The user runs this. Assets-only — no secrets, no migrations.

- [ ] **Step 1: Open the PR**

```bash
git push -u origin feature/marketing-site-redesign
gh pr create --base main --title "Marketing site redesign: landing+demo, pricing, privacy, support" --body "Implements docs/superpowers/specs/2026-06-15-marketing-site-redesign-design.md"
```

- [ ] **Step 2: Deploy after merge**

```bash
cd site && npx --yes wrangler@4 deploy
```

- [ ] **Step 3: Verify production**

```bash
for p in / /pricing /privacy /support; do printf "%s -> " "$p"; curl -s -o /dev/null -w "%{http_code}\n" "https://snapceipt.cc$p"; done
```
Expected: all `200`. Open `https://snapceipt.cc` and confirm the demo runs and the badge links to the App Store listing.

---

## Self-review (completed by plan author)

- **Spec coverage:** §3 pages → Tasks 2–5; §4 design system → Task 1; §5 landing sections → Task 2; §6 demo (scenes, off-screen pause, reduced-motion) → Task 2 Steps 2–3; §7 pricing → Task 3; §8 privacy/support compliance → Tasks 4–5 verify steps; §9 technical (badge artwork, App Store URL, fonts, meta/OG, a11y, routing, deploy) → Tasks 1, 2, 6, 7; §11 success criteria → Task 6 audit + Task 7 prod verify. No uncovered requirement.
- **Placeholder scan:** all new infra code (CSS core, demo JS, reduced-motion media query, badge/favicon SVG, robots, sitemap, meta block) shown in full; page bodies are "port from named preview + explicit deltas" (previews are committed-spec content per §spec). No "TBD/handle edge cases".
- **Type/name consistency:** shared classes (`.nav`, `.badge`, `.footer`, `.ghost`, `.kicker`, `.sec`) defined in Task 1 and used consistently in Tasks 2–5; badge filename `app-store-badge.svg` and App Store URL identical across tasks; demo ids (`#demoDevice`, `.dStep[data-step]`, `data-scene`) match between the ported CSS and the Task 2 script.
