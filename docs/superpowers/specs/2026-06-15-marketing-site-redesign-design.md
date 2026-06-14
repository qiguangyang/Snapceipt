# Snapceipt marketing site redesign — design

**Date:** 2026-06-15
**Branch:** `feature/marketing-site-redesign`
**Status:** Approved direction (brainstorm complete) → ready for implementation plan
**Scope owner:** the static marketing site only (`site/`), not the iOS app or the API Worker.

---

## 1. Goal & context

The live site at `https://snapceipt.cc` is a single minimal placeholder page (one headline, one paragraph, two links, "Coming soon to the App Store"). It under-sells a finished, shipped app. This project replaces it with a **professional, informative, multi-page marketing site** that explains the product, shows it in action, presents pricing, and meets Apple App Store review requirements for the privacy and support URLs.

The site is an **assets-only Cloudflare Worker** (`site/wrangler.jsonc`, `assets.directory = ./public`, `workers_dev:false`, custom domains `snapceipt.cc` + `www.snapceipt.cc`). Cloudflare serves `./public` directly; `html_handling` serves `/privacy` from `privacy.html`, etc. **There is no server runtime** — everything is static HTML/CSS, with a small amount of vanilla JS for the auto-play demo. No build step is required to deploy, though we add an optional asset-prep step (see §9).

This is a separate concern from the app: in-app purchase wiring, App Store publication, and TestFlight are out of scope here. We design the *pages*.

## 2. Decisions made during brainstorm (do not re-litigate)

| Decision | Choice |
|---|---|
| Visual direction | **Warm Editorial** (cream + terracotta, Fraunces serif display + Inter body) — chosen over "Modern Fintech" and "Bold App" |
| Positioning | **Broad**: receipts + tax for all Australian sole traders **and** households (not the BAS-only wedge) |
| Primary CTA | **"Download on the App Store" badge** (user's explicit choice, even though the app is not yet publicly live) |
| Page scope | **Full marketing page** + dedicated pricing page + redesigned privacy & support |
| Product demo | **Scripted auto-play walkthrough** (looping, styled like the real app) — chosen over embedding the live React prototype or a custom interactive demo |
| Pricing model | **Free + Pro** (freemium) |
| Pro price | **$9.99/month or $79/year (save 34%)**, 14-day trial |

## 3. Pages (deliverables)

All four live under `site/public/`:

1. **`index.html`** — landing page (replaces current placeholder)
2. **`pricing.html`** — new; served at `/pricing`
3. **`privacy.html`** — redesigned + enriched (replaces current)
4. **`support.html`** — redesigned + enriched (replaces current)

Shared header (sticky nav) and footer pattern across all four. Cross-links: nav → Home / Features / Pricing / Support; footer → Privacy / Support / Pricing / email.

## 4. Design system (Warm Editorial)

**Colour tokens** (CSS custom properties, reused on every page):

```
--cream  #FBF6F0   page background
--cream2 #F4EADD   soft fills
--ink    #211C18   primary text
--ink2   #6B6258   secondary text
--ink3   #A99F93   tertiary / meta
--terra  #E8602C   primary accent (personal terracotta)
--terra2 #C2461A   accent-deep / links
--teal   #0E7C72   secondary accent (business teal) — GST/positive cues
--line   #EADFCE   hairlines / borders
--card   #FFFFFF   card surfaces
--income #1F9D6B   success/positive
```

**Typography:**
- Page chrome (marketing): **Fraunces** (display, weights 400–600, italic for emphasis) + **Inter** (body/UI). Loaded via Google Fonts `<link>`.
- The **demo phone screen only** uses the *real app* fonts — **Schibsted Grotesk** (numbers/headers) + **Hanken Grotesk** (UI) — so the preview is an honest representation of the app, visually distinct from the editorial page around it.

**Components:** sticky translucent nav (adds a hairline on scroll), "Download on the App Store" badge (dark lozenge, Apple logo + two-line text — see §9 on using the official Apple artwork for production), `.ghost` underlined text link, rounded cards with hover lift, dark "trust band", `<details>` FAQ accordions, kicker labels (uppercase terracotta), section dividers via top hairlines.

**Responsive:** single max-width container (~1040–1140px); grids collapse to one column under ~880px; secondary nav links hide on mobile (badge stays). All pages must look right on a phone.

## 5. Landing page (`index.html`)

Sections, in order:

1. **Sticky nav** — logo, links (See it work / Features / Pricing / FAQ), "Get the app" badge.
2. **Hero** — eyebrow "Made in Australia · for sole traders & households"; H1 "Every receipt, *sorted* for tax." (italic terracotta "sorted"); lede; App Store badge + "Watch it work ↓" ghost link; tagline "Snap it. Sort it. Sorted."; a **static** app-style phone mockup (home screen) on the right.
3. **"Reads from every receipt" strip** — Merchant · Date · Total · GST · Category · ABN.
4. **Auto-play demo** ("See it work") — see §6.
5. **Features** — 6 cards: Smart capture, Australian-accurate GST, Reports & insights, BAS-ready export, Synced & offline, Private by design. Plus an "also included" line: budgets & alerts · quotes & invoices · vehicle & WFH logbooks · email-in receipts · loyalty cards.
6. **Pricing teaser** — Free vs Pro ($9.99) two-card summary + "Compare plans in full →" linking to `/pricing`.
7. **Trust band** (dark) — Made in Australia · Works offline · No ads, no tracking · Sign in with Apple · Your data stays yours.
8. **FAQ** — 4 accordions (which receipts, GST-registered?, privacy, offline).
9. **Final CTA** — "Snap it. Sort it. *Sorted.*" + badge.
10. **Footer** — logo, Privacy / Support / Pricing / email, © 2026 · Made in Australia.

## 6. The auto-play demo (key novel element)

A looping, **scripted** (not interactive) walkthrough inside a phone frame, styled in the real app aesthetic. It tells the snap→sorted story without a keystroke.

**Scenes (cross-fade between them, ~2.2–2.8s each, ~10s loop):**
0. **Home** — greeting, net-this-month card, recent receipts, tab bar with terracotta Snap FAB; a "tap ＋" ripple animates on the Snap button.
1. **Camera** — a receipt image with an animated scan line + "Reading receipt…" with animated dots.
2. **Extraction** — fields populate one-by-one with check marks: Merchant (Woolworths Metro), Total $48.20, GST $3.11, Category Groceries, + a "GST read from receipt" pill.
3. **Sorted!** — a success check pops in, "Saved, categorised and synced. Ready for BAS and tax time.", and the receipt drops into a mini list row.

A 3-step legend beside the phone (Snap / Snapceipt reads it / Sorted for tax) highlights in sync with the active scene.

**Implementation requirements:**
- Pure CSS keyframes + a small vanilla-JS state machine (`setTimeout` loop toggling a `data-scene` attribute; internal animations are scoped to the active scene via `[data-scene="n"] .x` selectors so they (re)start on activation).
- **Pause when off-screen** via `IntersectionObserver` (perf + battery).
- **Respect `prefers-reduced-motion`**: when set, do not auto-animate — show a static representative frame (the "Sorted!" or extraction scene) and disable scene cycling. (Required addition vs the prototype.)
- No external images required — the receipt and screens are CSS-drawn.

## 7. Pricing page (`pricing.html`)

- Hero: kicker "Pricing", H1 "Start free. Go Pro when *tax* gets real.", lede.
- Two plan cards: **Free $0 forever** (download CTA) and **Pro $9.99/mo · $79/yr, save 34%** (highlighted "Most popular", "Start 14-day free trial" CTA).
- **Compare plans** matrix (12 rows). Gating (assumption, adjustable):
  - **Free:** snap & auto-sort, GST/ABN/category extraction, cloud sync & offline capture, loyalty wallet, **basic** reports, **12 months** receipt history, standard support.
  - **Pro:** everything in Free + BAS-ready export & accountant pack, quotes & invoices, vehicle & WFH logbooks, email-in receipts, budgets & smart alerts, **advanced** reports, **unlimited** history, priority support.
- "No ads. No data selling." reassurance band.
- Billing FAQ: free-forever, 14-day trial, cancel anytime (Apple ID), monthly vs annual, billing via Apple, prices AUD incl. GST, refunds per App Store.
- Footer.

> **Caveat:** the free/paid feature line and the trial length are marketing copy here; they must match whatever the in-app StoreKit configuration actually enforces. Treat §7 as the source of truth for the *page*, and reconcile with the app before publishing real prices.

## 8. Privacy (`privacy.html`) & Support (`support.html`) — Apple-compliant + enriched

Both redesigned into the Warm Editorial system. Content is written to be **honest to how the app actually works** (per the codebase) and to satisfy Apple App Store Review Guideline 5.1.1 (data collection & storage, account deletion, third-party handling) plus the Australian Privacy Principles.

**Privacy page covers:** effective/updated date + APP statement; "Privacy at a glance" box (no ads/trackers, no data selling, only receipt *text* sent for reading, delete-anytime); a *what we collect* table (account details, receipts & transactions, app content, device & push token, limited diagnostics); how we use it; **named processors** (Cloudflare hosting/storage, DeepSeek text extraction, Cloudflare Workers AI for email-in OCR, Apple sign-in + payments); **overseas-transfer disclosure**; sharing/disclosure (no sale/marketing); retention & deletion (immediate + 30-day backup purge); your choices & rights (access, **Account → Delete Account**, notifications, OAIC complaints); security; children (<16); changes; contact.

**Support page covers:** "How can we help?" with a working **`mailto:support@snapceipt.cc`** + stated response time (2 business days); 6 popular-topic cards; troubleshooting FAQ incl. magic-link not arriving, receipt didn't extract, sync issues, accountant export, **manage/cancel subscription via Apple ID + Restore Purchases**, **delete account & data**, data handling; **system requirements** (iOS 17+); feedback/feature-request channel.

**Compliance checklist (must remain true):**
- Privacy policy is reachable at a stable URL (`/privacy`) and from the App Store listing.
- Support is reachable at a stable URL (`/support`) with a working contact method.
- Account deletion is documented on both pages and points to the in-app flow.
- Third-party data processors are named; overseas processing is disclosed.
- All factual claims (no analytics SDKs, no data sale, what's sent to DeepSeek) match the real implementation. **Founder/legal to give privacy copy a final read — this is not legal advice.**

## 9. Technical notes

- **No new dependencies, no framework.** Hand-written HTML/CSS + a small inline `<script>` for the demo only.
- **App Store badge:** for production, use the **official Apple "Download on the App Store" badge artwork** per Apple's marketing/identity guidelines (the brainstorm previews use a close hand-drawn SVG as a stand-in). Badge links to the App Store listing: `https://apps.apple.com/au/app/id6778894594` (app id from prior milestones). Until the app is publicly released this URL may 404 — acceptable per the user's explicit "App Store badge" choice; revisit if a pre-launch fallback is wanted.
- **Fonts:** Google Fonts via `<link>` with `preconnect`. Marketing pages load Fraunces + Inter; the landing page additionally loads Schibsted Grotesk + Hanken Grotesk for the demo. Use `display=swap`. Consider self-hosting/subsetting later for performance; not required for v1.
- **Performance:** keep each page a single self-contained file; lazy demo animation (IntersectionObserver); no heavy JS; images (if any) optimised. Target a fast first paint on mobile.
- **Accessibility:** semantic headings, sufficient colour contrast, focus styles on links/CTAs, `prefers-reduced-motion` honoured by the demo, `alt`/`aria` on meaningful graphics, the demo marked decorative/`aria-hidden` with a text equivalent (the 3-step legend).
- **SEO / meta:** per-page `<title>` + `<meta name="description">`, Open Graph + Twitter card tags (title, description, image), `lang="en-AU"`, canonical URLs, a favicon/app icon, and a simple `robots.txt`/`sitemap` if cheap. (New addition — current pages have none.)
- **Routing:** `html_handling` already serves `/privacy`, `/support`; the new `/pricing` works the same way once `pricing.html` exists. No `wrangler.jsonc` change needed beyond confirming defaults.
- **Deploy:** unchanged from today — `wrangler deploy` from `site/` (assets-only). No migrations, no secrets.

## 10. Out of scope

- In-app purchase / StoreKit wiring and the actual Free/Pro entitlement enforcement (app side).
- App Store publication / TestFlight.
- Any change to the API Worker (`src/`) or the iOS app.
- A blog, changelog, or marketing CMS.
- Real analytics (deliberately none — consistent with the privacy stance).
- Self-hosted fonts / a bundler (optional future optimisation).

## 11. Success criteria

- Four pages render correctly and consistently (desktop + mobile) in the Warm Editorial system.
- The auto-play demo loops smoothly, pauses off-screen, and degrades to a static frame under reduced-motion.
- Pricing clearly communicates Free vs Pro and the $9.99/$79 Pro price.
- Privacy & Support satisfy the Apple 5.1.1 checklist in §8 and read as trustworthy, AU-specific copy.
- Site deploys via the existing assets-only Worker with no runtime and no new infrastructure.
- All copy is factually consistent with the shipped app.

## 12. Reference

Brainstorm previews live under `.superpowers/brainstorm/<session>/content/` (gitignored): `landing-v2.html` (landing + demo), `pages.html` (pricing/privacy/support board), `directions.html` (the A/B/C direction comparison). These are the visual source of truth for the build.
