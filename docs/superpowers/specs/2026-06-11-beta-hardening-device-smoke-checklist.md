# Beta hardening — Release device-smoke checklist

**Run on a real iPhone, the new build installed via TestFlight (internal), against prod `api.snapceipt.cc` with your own account.** This is the final gate (spec §7.4): Release codegen has a bug class the simulator cannot reproduce (the `#Predicate` crash that took down build 1). Any failure → triage individually (superpowers:systematic-debugging) → fix → re-cut the next build. PROD-SAFETY: this is the ONLY prod touch in the whole beta-hardening program.

> Build number: the `beta` lane mints `latest_testflight_build_number + 1`. If build 3 already existed from the prior beta-launch, this cut is **build 4** (or higher). Fill in the actual number the lane printed: **0.1.0(__)**.

## Core loop (from the TestFlight plan, retained)
1. [ ] Sign in with Apple → lands on Home. Sign out → SignIn screen. Sign in again via magic link (email arrives; link opens the app via `https://api.snapceipt.cc/auth/magic` → `snapceipt://`).
2. [ ] Capture a real paper receipt with the camera → extraction fills merchant / total / GST.
3. [ ] Force-quit, delete the app, reinstall from TestFlight, sign in → data syncs back.
4. [ ] Budget with a cap just above current-month spend; add a transaction crossing the threshold → push arrives within the hour → tapping it deep-links to the budget.
5. [ ] Reports tab renders; export CSV to a second email → email arrives with the CSV.
6. [ ] Business profile: create + send a quote → recipient gets the PDF email.

## Scoped to what beta hardening changed (verify the polish + the fixed journeys on REAL hardware)
7. [ ] **Profile scoping (CRITICAL):** with two profiles each holding data, switch profiles → Home/Reports show ONLY the active profile's data, both directions; no leak, no stale rows. On a personal profile the Quotes quick action is absent.
8. [ ] **App lock:** Settings → App Lock on → background → reopen → Face ID prompt appears and unlocks to the shell (Release biometrics path — sim can't exercise this).
9. [ ] **Capture review edit:** edit merchant/amount/category before Save → the saved transaction reflects the edits; a low-confidence scan shows the neutral "Double-check the details below." banner (exact copy, no confidence badge).
10. [ ] **Loyalty render + scan:** open a card of each format you hold (EAN-13 / QR / Code128 / PDF417) → the barcode renders crisp at full brightness; backgrounding restores brightness. Also SCAN a physical card to add (camera-bound path J44b — simulator can't exercise this) → the barcode auto-fills the add form.
11. [ ] **Email-in:** open the email-in screen → rotate the alias → the displayed address actually changes; open a failed item → Save is gated until merchant+amount are filled.
12. [ ] **Polish spot-check:** the Snap FAB is not sliced by the tab bar; no white-on-white text fields; sheets/keyboard avoidance behave on a notched device; accent swatches and AU date/BAS-due labels read correctly.
13. [ ] **Photo/file import (NEW):** on the camera stage, the bottom-left import button renders above the live scanner, receives taps, and doesn't collide with the native Flash/Filters/Shutter chrome. Tapping it offers **Photo Library** and **Files**. Import a receipt photo from Photos → it lands in Review with extracted fields. Import a receipt **PDF** from Files (ideally from a cloud provider like iCloud Drive, to exercise extension-less URLs) → its first page lands in Review. Pick an obviously-bad file (e.g. a non-receipt PDF) → a "Couldn't read that file." toast appears OR it lands in Review with the low-confidence banner; either way, no crash and you stay in the flow.

## Sign-off
- [ ] All 13 pass on a real device against prod → this build is good for the internal beta.
- [ ] Any failure logged with repro → fix → re-cut the next build via `BETA_INTERNAL_ONLY=1 bundle exec fastlane beta`.
