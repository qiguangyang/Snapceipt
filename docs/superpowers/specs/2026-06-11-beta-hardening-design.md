# Beta Hardening — UI/UX Polish + Comprehensive E2E Sweep

**Date:** 2026-06-11
**Status:** Approved (brainstormed section-by-section with user)
**Scope:** Whole-app quality hardening between TestFlight beta (build 0.1.0(2), in external review) and the next build.

## §1 Context & goal

All 7 roadmap features (F1–F7) plus capture/extraction are shipped and merged to `main`; prod is live at `api.snapceipt.cc`; build 0.1.0(2) is WAITING_FOR_REVIEW in external beta. The beta smoke triage (2026-06-11) found five real-device defects, several of which were *visible-in-pixels-only* (sliced Snap FAB, white-on-white text fields) or *Release-codegen-only* (the SwiftData generic-context `#Predicate` crash). This program systematically hunts both classes before 1.0:

1. **Polish** every screen — fidelity to the design handoff *plus* a designer's-eye pass beyond it.
2. **Prove** the app — a comprehensive end-to-end QA sweep over the polished app, fixing every in-guardrail bug found and backfilling permanent automated coverage.

Execution is fully autonomous (orchestrated subagent workflows — the same pattern that built F1–F7), with one user review at the end (before/after gallery) before shipping.

## §2 Locked decisions

| Question | Decision |
|---|---|
| Sequencing | Polish first, then the e2e sweep (QA doubles as regression verification of the polish) |
| E2e meaning | Both: live QA sweep **and** automated test backfill |
| Environment | Sweep on iPhone 16 simulator + local `wrangler dev`; Release real-device smoke vs prod as the final gate |
| Polish bar | Design-ref fidelity **+** designer's eye (states, transitions, haptics, keyboard, accessibility) |
| Authority | Fully autonomous; user reviews once at the end via before/after gallery |
| Guardrails | Visual + micro-UX only — no flow/navigation restructuring, no new features, no v1.1 deferrals |
| Deliverable | PR `foundation` → `main`, then `BETA_INTERNAL_ONLY` TestFlight build 0.1.0(3) (external review slot untouched) |
| Execution approach | A: screenshot-tour harness + rendered-pixel audits (chosen over code-only audit and real-hardware live QA) |

## §3 Architecture overview

```
Phase 0                Phase 1                  Phase 2                Phase 3
Screenshot-tour   →    Polish pass         →    E2e sweep         →    Ship
harness                (per area, audit →       (journey matrix +      (gallery review →
(seeded fixtures,      verify → fix →           exploratory →          PR #→main →
 named PNGs,            re-shoot loop;           pin-fix-verify →       internal TestFlight
 "before" baseline)     consistency pass)        backfill tests)        0.1.0(3) → device smoke)
```

Work happens on `foundation` (the long-lived working branch). Full iOS + backend suites run after every polish area and every fix batch; a regression blocks progress until resolved.

## §4 Phase 0 — screenshot-tour harness

The only new infrastructure. A durable asset, not scaffolding: it produces Phase 1's audit input, Phase 3's before/after gallery, and a visual-regression baseline for all future work.

- **New UITest class `ScreenshotTourUITests`** (joins the existing 13 UITest classes, built on `UITestCase`). It launches the app with a deterministic seeded fixture set via the existing launch-environment seams: both profiles (Personal terracotta / Business teal), transactions across categories and months, budgets (incl. one over-threshold), logbook data (vehicle, trips, WFH entries), loyalty cards (multiple barcode formats), quotes (draft + sent), email-in items (incl. one `failed` extraction), smart rules, and the stub capture image.
- **Coverage:** every screen and key state across the 10 audit areas (§5) — empty *and* populated variants, sheets, editors, overlays, keyboard-up forms, both profile accents where the accent re-skins the screen.
- **Naming:** each stop saves a screenshot attachment; `scripts/tour.sh` runs the tour and exports PNGs to `artifacts/tour/<run-id>/<area>/<screen>-<state>.png` (export via `xcrun xcresulttool` attachment export; exact mechanics are plan detail). `artifacts/` is gitignored — PNG runs are local artifacts, never committed.
- **Determinism:** fixed date via the existing `Epoch` seam; `simctl status_bar override` for clock/battery; settle/wait before each shot so in-flight animations don't smear pixels. If a screen still renders nondeterministically, the tour disables or waits out the animation rather than accepting flaky pixels.
- **Baseline:** the first clean run is frozen locally as the "before" set for the final gallery.

**Exit gate:** tour runs green end-to-end, every area produces named PNGs, a second run is pixel-stable for static screens.

## §5 Phase 1 — polish pass

**Audit areas (10):**
1. Onboarding + Auth (incl. magic-link and SIWA entry screens)
2. App shell — tab bar, raised Snap FAB, single-slot overlays, sync pill
3. Home — tracker card, quick actions, alerts feed/bell
4. Capture flow — all 4 CaptureFlow stages
5. Reports + Export sheet
6. Logbooks — mileage (vehicle, trips, odometer) + WFH
7. Budgets — editor + alerts/notifications settings
8. Loyalty — wallet, add, card detail
9. Quotes — list, editor, client picker
10. Email-in + Settings (hub and every sub-screen) + Profiles (switcher, detail)

**Two audit lenses per area:**
- *Fidelity:* sim PNGs vs prototype PNGs (`design-ref/snapceipt/project/screenshots/`), prototype JSX (`design-ref/snapceipt/project/app/`), and the pixel spec (`docs/superpowers/specs/extracted/screens.md`). Every deviation filed. Where the implementation deliberately diverged (documented in feature specs — e.g. scope-by-profileId, full ATO logbook method), the spec decision wins over the prototype.
- *Designer's eye:* what the handoff never covered — spacing/alignment consistency, visual hierarchy, empty/loading/error states, transition + animation quality, haptics, keyboard avoidance, copy tone, accessibility labels, Dynamic Type robustness. Dynamic Type scope-limit: fix cheap layout-robustness wins (truncation, clipping at larger sizes); a full adaptive-type system is out of scope and gets deferred-logged.

**Pipeline per area:** audits run in parallel across areas → every finding is adversarially verified by an independent agent (real in the pixels? in-guardrail? not v1.1 scope?) → verified findings are fixed **area-by-area sequentially** (design tokens and shared primitives are heavily cross-referenced; parallel edits would conflict) → re-shoot that area's tour shots to confirm visually → full iOS suite must stay green before the next area starts.

**Pre-seeded finding:** AddLoyaltyView number field overlaps the pinned Save bar (known from F4 review).

**Out-of-guardrail findings** are logged to `docs/superpowers/specs/2026-06-11-beta-hardening-deferred-findings.md` — visible, never built.

**Closer — cross-screen consistency pass:** after all areas are individually clean, one audit looks across screens: token usage (color/spacing/radius/type scale), icon-set consistency, copy tone, haptic patterns. Findings follow the same verify → fix → re-shoot loop.

**Exit gate:** all verified in-guardrail findings fixed or explicitly deferred-logged; consistency pass clean; full iOS + backend suites green.

## §6 Phase 2 — comprehensive e2e sweep

**Journey matrix.** Enumerated during planning from the 9 journey-source specs (whole-app, capture/extraction, F1–F7) into one checklist (expected ~30–40 journeys). The matrix is the contract: nothing ships until every row is executed. Minimum categories, with examples:
- **Auth & lifecycle:** first-run onboarding → magic-link sign-in (E2E seam) → profile setup; SIWA path; token refresh rotation; sign-out; app lock (Face ID seam); change email (6-digit code); device revoke; account delete.
- **Capture & data:** capture (stub image) → extraction → review/edit → save → image upload; offline capture → HeuristicParser fallback → outbox queue → reconnect → drain → re-extract reconciler.
- **Sync correctness:** push/pull round-trip vs local `wrangler dev`; LWW conflict; tombstone propagation; the 4xx → `.error` visible-failure path; inflight→pending crash-recovery requeue.
- **Profile scoping (CRITICAL):** multi-profile fixtures probing that ALL domain data is scoped by `profileId` — switching profiles never leaks or hides another profile's data; business-only gating (Quotes) enforced.
- **Features end-to-end:** reports reflect saved transactions; period switcher; export CSV/PDF (+ accountant email outbox); logbook trip + WFH → FY tax pills; budget cap → cron → alert feed + deep-link; loyalty add/scan/render (every barcode format); quote create → send → SN-#### mint → PDF + outbox; email-in inbound (seam) → failed review → save (sign rule); inbox alias rotate.
- **Settings & config:** tax settings FY start threading; category default %; smart rules CRUD; notifications/quiet hours.

**Three coverage layers:**
1. *UI journeys:* XCUITests driving the simulator against a real local `wrangler dev` — extending the proven `E2E_LIVE` + `scripts/ios-e2e-live.sh` pattern from one smoke test into a journey suite.
2. *Backend e2e:* vitest real-HTTP (`unstable_dev`) tests for server behavior the UI can't reach — rate-limit tiers, cron logic, R2 object lifecycle, refresh-token edge cases, email outbox states.
3. *Exploratory:* unscripted agent sweeps — rapid navigation, input abuse (long strings, emoji, zero/negative amounts, paste garbage), interrupt-and-resume, empty/low-data states — hunting crashes and jank the matrix doesn't predict.

**Bug protocol.** Every bug: reproduce → pin with a failing test where feasible → fix → green → adversarial review of the fix. All in-guardrail bugs get fixed; anything needing a product decision goes to the deferred-findings log.

**Backfill.** Every matrix journey ends up covered by a permanent automated test (UITest or backend e2e). Suites should come out materially larger than today's baselines (§12).

**Prod safety.** The sweep only ever talks to local `wrangler dev`. `api.snapceipt.cc` is touched solely by the user's device smoke with their own account.

**Exit gate:** matrix 100% executed; zero open in-guardrail bugs; all suites green.

## §7 Phase 3 — ship

1. **Gallery review (the one user review):** before/after PNG pairs per area in the visual-companion browser, plus the bug ledger and deferred-findings list. Rejected changes are reverted and re-verified before shipping.
2. **PR:** `foundation` → `main`, following the established PR convention (PR #9 or next number free).
3. **TestFlight:** after merge, `fastlane` with the `BETA_INTERNAL_ONLY` switch cuts **0.1.0(3)** to internal testers only — the external review slot (build 2) stays untouched.
4. **Release device smoke (final gate):** the user runs a checklist tailored to what actually changed, on a real iPhone against prod. This is deliberately last: Release codegen has a bug class the simulator cannot reproduce (proven by the `#Predicate` crash). Smoke failures loop back: fix → build 0.1.0(4).

## §8 Guardrails & out of scope

**In scope:** visual polish; micro-UX (states, copy, haptics, keyboard handling, accessibility labels, small interaction fixes); bug fixes of any depth (incl. backend) for behavior that's already specced.

**Out of scope — logged to deferred-findings, never built:**
- Flow/navigation restructuring; new features of any size.
- All v1.1 deferrals: custom categories, invoice UI, email-in on-device image viewing, loyalty image/PassKit share, Activity tab, auto-lock timeout + app-switcher privacy screen, real-AI insights, dark mode, multi-currency, monetization.
- Sync performance optimization beyond user-visible jank (the O(B·T) mapper note stays a note).
- External provisioning beyond what exists (email-in Routing catch-all, Universal Links/AASA — separate go-live work).

## §9 Risks & mitigations

| Risk | Mitigation |
|---|---|
| Screenshot nondeterminism poisons audits | Seeded fixtures, fixed `Epoch` date, status-bar override, settle-before-shoot; animations disabled/waited-out per screen |
| Parallel fixes conflict on shared SwiftUI tokens/primitives | Audits parallel, fixes strictly sequential per area, full suite green between areas |
| Polish introduces functional regressions | Phase 2 runs *after* Phase 1 over the polished app — the sweep is the regression net by design |
| Release-only bugs survive the sim sweep | Phase 3 device smoke on a Release build is the explicit final gate |
| Sweep pollutes prod | Sweep is hard-scoped to local `wrangler dev`; prod only via the user's device smoke |
| Toolchain breakage | Repo wrangler stays 3.x (vitest-pool-workers pin); deploy/fastlane paths untouched until Phase 3 |
| Scope creep via "polish" | Adversarial finding-verification enforces guardrails; out-of-guardrail → deferred log |

## §10 Success criteria

1. Every screen audited in rendered pixels; all verified in-guardrail findings fixed or deferred-logged.
2. Journey matrix 100% executed; zero open in-guardrail bugs.
3. Full suites green and larger than the §12 baselines.
4. Before/after gallery approved by the user.
5. PR merged to `main`; 0.1.0(3) live for internal TestFlight testers; tailored smoke checklist delivered.

## §11 Implementation plan split

Next step: the **writing-plans** skill, producing two plans executed in order:
- **Plan A — Harness + polish** (Phases 0–1): tour harness + fixture seeding, per-area audit/fix loops, consistency pass.
- **Plan B — E2e sweep + ship** (Phases 2–3): journey-matrix finalization, the three coverage layers, bug protocol, backfill, gallery/PR/TestFlight.

Plan B's journey matrix is finalized during planning against the feature specs; the §6 categories are its minimum contents.

## §12 Baselines (2026-06-11)

- iOS: full `xcodebuild` suite green (last counted 359 pass / 1 LiveSmoke skip at F7; the beta-triage commits didn't re-count — re-baseline exact numbers at Phase 0 start). 13 UI test classes incl. LiveSmoke.
- Backend: `npm test` 327; `npm run test:e2e` 19; typecheck clean.
- Branch state: `main` == merged PR #8 (beta-launch + smoke-triage work); `foundation` is the working branch.
- Prod: `api.snapceipt.cc` live; build 0.1.0(2) WAITING_FOR_REVIEW (external) + internal "Team" group; Email Sending onboarded.
