# Snapceipt — TestFlight Beta Launch (Design Spec)

- **Status:** Approved (brainstorm)
- **Date:** 2026-06-10
- **Branch:** `foundation`
- **Builds on:** all seven roadmap features (F1–F7) + the go-live backend milestone
  (`docs/superpowers/specs/2026-06-02-go-live-backend-design.md`, `scripts/deploy.sh`).
  The production Worker is **not yet deployed**; this milestone executes go-live and
  carries the app to an external TestFlight beta.
- **Approach:** Fastlane from day one (match + gym + pilot, ASC API key) — chosen
  over manual-Organizer-with-runbook and hand-rolled xcodebuild scripts.

---

## 1. Goal & success criteria

An external tester receives a TestFlight invite, installs Snapceipt on a real
iPhone, and completes the core loop against production: sign in (Sign in with
Apple or magic link) → capture a receipt → extraction → sync → reports →
export email arrives.

**Done when all of these hold:**

1. `https://api.snapceipt.cc/health` returns OK over the custom domain.
2. A magic-link email from `noreply@snapceipt.cc` lands in a real, arbitrary inbox.
3. Sign in with Apple succeeds on a physical device.
4. `https://snapceipt.cc/privacy` and `/support` are live.
5. `bundle exec fastlane beta` archives, uploads, and the build reaches
   "Ready to Test" in App Store Connect.
6. Beta App Review passes; the external "Beta" group can install.
7. One external tester completes the §8 smoke checklist core loop.
8. A budget-alert push arrives on a real device (production APNs).

## 2. Out of scope (explicit)

- **Full App Store submission** — screenshots, marketing copy, finalized App
  Privacy questionnaire. The beta listing needs only TestFlight test info.
- **CI for fastlane** — lanes run locally; CI is a later milestone.
- **Universal Links / AASA** — the shipped `GET /auth/magic` →
  `snapceipt://` scheme bridge stands.
- **Real icon artwork** — the generated icon is a placeholder by design,
  replaced before App Store submission.
- **Email-in receipts (F6 activation)** — requires Email Routing on
  `in.snapceipt.cc`; fast-follow after the beta, not on the critical path.

## 3. Track 1 — Backend go-live

The machinery exists (`scripts/deploy.sh`, idempotent, DRY_RUN mode). This
track executes it, with two code changes first.

### Code changes

1. **`wrangler.jsonc` var `APPLE_BUNDLE_ID`:** `"com.snapceipt.app"` →
   `"app.snapceipt.Snapceipt"` (the app's real bundle ID, registered in §6).
   The go-live spec deferred this exact fix "to the SIWA milestone" — this is
   that milestone. **Test-transparent, verified:** `vitest.config.ts:42` pins
   `APPLE_BUNDLE_ID: "com.snapceipt.app"` for the test runtime, and
   `scripts/ios-e2e-live.sh` passes its own `--var`; no test or e2e file
   changes.
2. **`wrangler.jsonc` routes:** add
   `"routes": [{ "pattern": "api.snapceipt.cc", "custom_domain": true }]`.
   The deploy script today only prints instructions for this step.

### Manual prerequisites (user)

- Add `snapceipt.cc` as a Cloudflare zone on the techsiderau account; point
  registrar nameservers at Cloudflare. **Do this first — DNS propagation is
  the longest pole.**
- `npx --yes wrangler@4 login` as that account.
- A funded DeepSeek API key.

### Execution order

1. `DRY_RUN=1 ./scripts/deploy.sh` — read-only inventory; review output.
2. `DEEPSEEK_API_KEY=… ./scripts/deploy.sh` — provisions D1/KV/R2, patches
   real resource IDs into `wrangler.jsonc`, puts secrets, onboards
   `snapceipt.cc` for Email Sending (SPF/DKIM auto-injected; 5–15 min
   propagation), applies remote migrations, deploys.
3. The routes entry (code change 2) attaches `api.snapceipt.cc` during the
   live deploy — the zone prerequisite guarantees it exists by then. If the
   attach failed anyway, re-run `npx --yes wrangler@4 deploy` once the zone
   is active.
4. **Commit the patched `wrangler.jsonc`** — resource IDs are not secret.
5. Smoke: `curl https://api.snapceipt.cc/health`; then request a magic link
   to your own inbox and complete sign-in from the email.

### APNs secrets (after Track 4 produces the key)

`wrangler secret put` × 3: `APNS_KEY` (the `.p8` PEM body), `APNS_KEY_ID`,
`APNS_TEAM_ID`. Until set, `src/lib/apns.ts` returns a stub result and
nothing breaks — push comes online incrementally. `apns.ts` targets
`api.push.apple.com` (production), which matches TestFlight builds.

## 4. Track 2 — Public site (privacy + support)

A second, trivial Worker, fully separate from the API: `site/` directory
with its own minimal `wrangler.jsonc` using Workers **static assets** (no
build step, no framework). Three hand-written HTML pages with inline CSS in
the brand palette:

- `/` — one-paragraph landing ("Snapceipt — snap receipts, sorted for tax",
  App Store link placeholder).
- `/privacy` — the privacy policy. **Must disclose the real data flows:**
  account email; receipt images + transaction data stored on Cloudflare
  (R2/D1); **receipt text processed by DeepSeek** for extraction
  (third-party processor); Sign in with Apple; push tokens; no ads, no
  tracking, no sale of data; deletion via the in-app Delete Account (F7);
  contact address.
- `/support` — brief help text + `support@snapceipt.cc`.

Routed to `snapceipt.cc` + `www.snapceipt.cc` (custom domains on the site
worker). `support@snapceipt.cc` is an Email **Routing** forward rule to the
owner's Gmail — Routing (inbound) and Email Sending (outbound) coexist on
one zone.

## 5. Track 3 — iOS release readiness

All changes in `project.yml` / `Snapceipt/`:

1. **Entitlements** — new `Snapceipt/Snapceipt.entitlements`, wired via
   `CODE_SIGN_ENTITLEMENTS`:
   - `com.apple.developer.applesignin` = `[Default]`
   - `aps-environment` = `development` — the App Store export re-signs this
     to `production` from the provisioning profile. **Intentional; do not
     "fix" the file value.**
2. **App icon** — new `Snapceipt/Resources/Assets.xcassets` with a
   single-size 1024 px `AppIcon`. A committed generator script
   (`scripts/generate-app-icon.swift`, CoreGraphics, runs with plain
   `swift` on macOS) draws a receipt glyph (rounded rect, zigzag bottom
   edge) on the brand gradient. **Both the script and the rendered PNG are
   committed**; generation is not a build step.
3. **`PrivacyInfo.xcprivacy`** — privacy manifest in the app target:
   - `NSPrivacyTracking: false`, no tracking domains.
   - Collected data types: email address, purchase/financial data, user ID —
     each "linked to user", purpose app-functionality, not used for
     tracking.
   - Required-reason APIs: `NSPrivacyAccessedAPICategoryUserDefaults` reason
     `CA92.1` (certain — the app uses UserDefaults); file-timestamp /
     disk-space entries **only if** the implementation-time code audit
     finds usage.
4. **`Info.plist`** — add `NSFaceIDUsageDescription` ("Snapceipt uses Face
   ID to unlock the app when App Lock is on."). Implementation-time audit:
   if any photo-library import uses `UIImagePickerController` (not
   `PHPicker`), also add `NSPhotoLibraryUsageDescription`.
5. **`project.yml`** —
   - `DEVELOPMENT_TEAM` = the real team ID (committed; repo is private).
   - **Release config only:** `CODE_SIGN_STYLE: Manual`,
     `PROVISIONING_PROFILE_SPECIFIER: "match AppStore app.snapceipt.Snapceipt"`.
   - **Debug stays Automatic** — simulator development is untouched.
   - `MARKETING_VERSION` stays `0.1.0`; build number is fastlane-managed
     (§7), `CURRENT_PROJECT_VERSION` remains the local fallback.

## 6. Track 4 — App Store Connect ceremony (manual runbook)

Ordered; each step's output feeds the next.

1. **developer.apple.com → Identifiers:** register App ID
   `app.snapceipt.Snapceipt`; enable **Sign in with Apple** and **Push
   Notifications**. Note the **Team ID** (Membership page).
2. **Keys:** create an **APNs auth key** (`.p8`) — downloadable exactly
   once; store in the password manager. Feeds the three Worker secrets
   (§3). One key serves dev + prod APNs.
3. **App Store Connect → My Apps:** create the app record — name
   "Snapceipt" (fallback display names ready if taken, e.g. "Snapceipt —
   Receipts & Tax"; bundle ID unaffected), bundle ID
   `app.snapceipt.Snapceipt`, SKU `snapceipt-ios`, primary locale
   English (Australia).
4. **ASC API key** (Users and Access → Integrations): role App Manager.
   Record key ID + issuer ID; download the `.p8`. Lives **only** in
   gitignored `fastlane/.env` (§7).
5. **TestFlight setup:** beta app description, contact email, **privacy
   policy URL `https://snapceipt.cc/privacy`** (Track 2 must be live
   first), create external group "Beta", add testers by email. Beta review
   notes: reviewers sign in with their own Apple ID via SIWA; magic link is
   the fallback path.

## 7. Track 5 — Fastlane pipeline

Ruby via `Gemfile` (fastlane pinned; `bundle install`, no global install).

- **`fastlane/Appfile`** — `app_identifier "app.snapceipt.Snapceipt"`,
  `team_id`.
- **Signing: `match`** with a new **private GitHub repo**
  (e.g. `qiguangyang/snapceipt-certs`) storing the encrypted App Store
  distribution cert + profile. `MATCH_PASSWORD` in the password manager +
  `fastlane/.env`. One-time `fastlane match appstore` bootstraps; lanes
  thereafter run `readonly: true`.
- **`fastlane/Fastfile` — exactly two lanes (YAGNI):**
  - **`beta`:** `ensure_git_status_clean` → `xcodegen generate`
    (`project.yml` stays the project source of truth) →
    `match(type: "appstore", readonly: true)` → build number =
    `latest_testflight_build_number + 1` via the ASC API key (no local
    counter to drift) → `gym` (scheme `Snapceipt`, `export_method:
    "app-store"`) → `pilot` (upload, distribute to "Beta",
    `changelog` prompted at run time).
  - **`certs`:** thin `match` wrapper for new-machine bootstrap.
- **Secrets:** `fastlane/.env` (gitignored) — `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_PATH`, `MATCH_PASSWORD`, `MATCH_GIT_URL`.
  A committed `fastlane/.env.example` documents every variable.
- `.gitignore` additions: `fastlane/.env`, fastlane build artifacts
  (`*.ipa`, `*.dSYM.zip`, `fastlane/report.xml`, `fastlane/test_output`).

## 8. Verification

- **Existing baselines stay green** — backend `npm test` (325) and the iOS
  suites. This milestone makes **no behavioral code change**, so any test
  movement is a red flag. The `APPLE_BUNDLE_ID` var change is pinned-over
  in test config (§3).
- **Pre-TestFlight device check** — a Debug build on a real iPhone
  validates SIWA, camera capture, and the Face ID prompt *before* spending
  a TestFlight cycle. (SIWA works on-device once the App ID + entitlement
  exist.)
- **Beta smoke checklist** (the tester-facing core loop):
  1. Sign in with Apple; sign out; sign in via magic link.
  2. Capture a real paper receipt → extraction fills merchant/total/GST.
  3. Force-quit, delete, reinstall, sign in → data syncs back.
  4. Create a budget near current spend → push arrives on-device →
     tapping deep-links to the budget.
  5. Reports render; export CSV emailed to a second address arrives.
  6. Business profile: create + send a quote; PDF email arrives.

## 9. Failure modes

| Failure | Response |
|---|---|
| Zone/DNS propagation slow | It is deliberately the first prerequisite; all other tracks proceed in parallel. |
| Email Sending onboarding stalls | SIWA carries the beta. Last resort: the go-live spec's temporary `E2E_TEST_MODE` seam — never left enabled, removed before milestone-done. |
| "Snapceipt" name taken in ASC | Fallback display names; bundle ID and code unaffected. |
| Beta App Review rejection | Pre-empted: privacy URL live before submission (Track 2 → 4 ordering), SIWA reviewer notes, camera-permission string already ships. Iterate on the review feedback. |
| Push doesn't arrive in beta | TestFlight builds use production APNs and `apns.ts` targets the production host — match. A **Debug** device build gets sandbox tokens that production APNs rejects: known, documented, not a bug. |
| Build stuck "Processing" | Bump build (`fastlane beta` auto-increments) and re-upload. |
| match repo loss/lockout | `MATCH_PASSWORD` + repo access in the password manager; `fastlane match nuke` + re-bootstrap is the documented recovery. |

## 10. Sequencing

```
zone/DNS (longest pole)
   ├─ Track 1 backend deploy ──┐
   ├─ Track 2 public site ─────┤  (parallel)
   └─ Track 3 iOS readiness ───┤
                               ▼
              Track 4 ASC ceremony  (needs App ID before signed device
                               │     builds; privacy URL before TF info)
                               ▼
              Track 5 fastlane → `fastlane beta` → Beta App Review → testers
```

## 11. User-supplied inputs (collected during implementation)

- Apple Team ID (§5 `project.yml`, §7 Appfile).
- APNs `.p8` + key ID (§6 step 2 → §3 secrets).
- ASC API key trio (§6 step 4 → `fastlane/.env`).
- DeepSeek API key (§3 live run).
- New private GitHub repo for match + `MATCH_PASSWORD`.
- Registrar nameserver change for `snapceipt.cc`.
