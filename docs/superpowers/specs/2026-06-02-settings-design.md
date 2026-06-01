# F7 — Settings (Design)

> The final feature of the Snapceipt remaining-features roadmap (F1–F6 shipped & merged). Settings turns the Profile-tab stub into the real configuration + account hub: profile management, the Tax & GST editor, Categories & smart-rules, Privacy (Face ID lock), and Account & security (change email, device list/revoke, delete account) — plus the cross-cutting `financialYearStartMonth` wiring cleanup.

Roadmap capsule: `docs/superpowers/specs/2026-05-31-snapceipt-remaining-features-roadmap.md` (F7). Whole-app intent: `docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md` §12.5–12.10, §3.15. Pixel layouts: `docs/superpowers/specs/extracted/screens.md` (ProfileScreen / TaxScreen / ProfileDetail / Settings overlays).

## 1. Scope & locked decisions

**In scope (the full Settings hub + account backend):**
- **Settings hub** — restructure the Profile tab (`ProfileTabView`, currently a 3-row stub) into the real hub: identity header, profile-switcher grid, grouped setting rows (Capture & tax / App / Account), sign-out.
- **Profile management** — edit (name, business ABN/GST, accent) + delete (confirm) + a `ProfileDetail` screen (hero, switch-to-active, per-profile stats, export-this-profile link, delete). Today only *add* exists.
- **Tax & GST editor** — bound to `tax_settings` per profile: FY start month, GST registration + ABN + entity type + GST accounting basis (Business only; Personal hides tax identity), BAS period + derived next-due, deduction defaults (meals %, WFH c/hr, mileage c/km). Replaces the seed-only stub.
- **Categories & smart-rules** — edit each built-in category's default deductible % + full smart-rules CRUD (matcher → category / deductible % / mode, enable + priority + delete). Category list with derived receipt counts. **No user-created categories** (avoids the Reports/Budgets `cat_key` roll-up wrinkle).
- **Privacy & security** — a biometric **app-lock** toggle (Face ID / Touch ID, device-passcode fallback) gating cold-launch + return-from-background. Local-only (a `UserDefaults` flag — a non-secret boolean that should clear on reinstall); no backend.
- **Account & security (new backend)** — change email (in-app 6-digit code to the new address), device list + revoke (`DELETE /devices/:id`), delete account (immediate hard purge of D1 + R2). Sign-out is already wired.
- **FY-start cleanup** — thread `tax_settings.financialYearStartMonth` through the ~7 sites currently hardcoded to `startMonth: 7`.

**Locked behaviour decisions:**
1. **Delete account** = immediate, irreversible hard purge (all user D1 rows + all R2 objects under `u/<userId>/`), gated by a typed-confirmation dialog → sign out → auth. (User-initiated deletion overrides the ATO auto-retention note.)
2. **Change email** = `POST /users/me/email` issues a 6-digit code to the NEW address; the user types it back in-app (`POST /users/me/email/verify`) to commit the swap. Sessions stay valid.
3. **Categories** = edit built-in deduction defaults + smart-rules CRUD only; no custom categories.
4. **Face ID** = simple biometric lock toggle (no auto-lock-timeout, no app-switcher privacy screen) in v1.

**Out of scope / deferred (v1.1):** custom categories; Connected banks (stays the honest "Coming soon" placeholder, `/banks` 501); auto-lock timeout + app-switcher privacy screen; "Pro"/monetization (hidden); send-history/address-book (F2 deferred); Help content (an external link only); soft-delete/30-day-grace for account deletion (we ship immediate hard purge).

**Architecture:** built as **three plans under one spec** (Approach B): (1) **backend** account ops; (2) **iOS config** — hub + Tax editor + Categories/rules + profile edit/delete/detail + FY-start cleanup; (3) **iOS account & security** — change-email + delete-account + device list/revoke + Face ID. One PR at the end. No new synced entities (reuses `profiles`, `tax_settings`, `categories`, `smart_rules`, `devices`); the only new backend persistence is a KV entry for the email-change code.

## 2. Settings hub & navigation

`ProfileTabView` becomes the hub (the existing 5th tab; no new tab). Sections, top→bottom (mirrors `screens.md` ProfileScreen + §12.5):
- **Identity header** — signed-in user (data-bound from `AuthStore.session.user` / `me()` — no hardcoded name); "Pro" hidden.
- **Profile switcher grid** — one card per profile (active is highlighted; tap → `ProfileDetail`; "Add another profile" → existing `AddProfile`). Re-skins to the active profile's accent.
- **Capture & tax group** — rows: "AI auto-categorise" (existing inert toggle, keep as-is), "Categories & rules" → `.categories`, "Tax & GST settings" → `.tax` (detail "FY25–26"), "Connected banks" → existing placeholder.
- **App group** — "Notifications & alerts" → `.notificationSettings` (F3, existing), "Export & backup" → existing `.export` sheet, "Privacy & security" → `.privacy` (new), "Help & support" → external link (`openURL`).
- **Account group** — "Account" → `.account` (new: email + devices + delete).
- **Sign out** — existing `AuthViewModel.signOut()` (confirm → clear Keychain → auth).

New `Router.Overlay` cases (full-screen overlays, mirror the F5/F6 pattern): `.categories`, `.ruleEditor(id: String?)`, `.tax`, `.profileDetail(id: String)`, `.privacy`, `.account`, `.changeEmail`. Each wired in `RootView` with the established overlay + `sheetBinding` exclusion pattern. New `AccessibilityID`s per screen.

## 3. Profile management

- **Edit** (`ProfileDetail` → "Profile name", "Type", Business "ABN" + "Registered for GST", "Accent colour"): mutate the `Profile` `@Model`, `updatedAt = nowMs`, `try context.save()`, `sync.enqueue(op:"upsert", .profile)`. Extends `ProfilesStore` with `update(_:)` + `delete(_:)` (today only `add`).
- **Delete**: confirm dialog → soft-delete (`deletedAt = nowMs`) + enqueue delete. Guard: cannot delete the **last** profile, and cannot delete the **active** profile without first switching (or auto-switch to another then delete). `tax_settings` for the deleted profile is left (server tombstones via sync; harmless).
- **ProfileDetail**: hero (profile palette), "Switch to this profile" (`ProfilesStore.setActive`), per-profile **real** stats (receipt count + deductible-YTD or spent — derived via `FetchDescriptor`, not stored), "Export this profile" → the F2 `.export` sheet scoped to this profile, "Delete profile".

## 4. Tax & GST editor

Bound to the profile's `tax_settings` row (lazily ensured via the existing `TaxSettingsSeeder`). A `TaxSettingsViewModel` (`@Observable @MainActor`, injected `context`/`sync`/`profileId`) loads the row, edits fields, and on change `updatedAt = nowMs` + `try save()` + `enqueue(op:"upsert", .taxSettings)`.

| Group | Fields (→ `tax_settings` column) | Notes |
|---|---|---|
| Business identity (Business profiles only) | ABN (→ `profiles.abn`), Registered for GST (→ `profiles.gstRegistered`), Entity type, GST accounting basis | Entity type + GST basis are **local-only** prefs (UserDefaults, per profile) — no column exists; persist as `sc.tax.<profileId>.entityType` / `.gstBasis`. ABN/GST live on `Profile` (synced). Personal profiles **hide** this whole group. |
| Financial year | Tax year start month (→ `financial_year_start_month`), BAS period (local pref), Next BAS due (derived, read-only) | FY start drives Reports/Export/logbook FY (see §9). Next-BAS-due derived from BAS period + FY start (pure helper `nextBasDue(period, fyStartMonth, now)`). |
| Deduction defaults | Meals % (→ `meals_deductible_pct`), Home office c/hr (→ `wfh_rate_cents_per_hour`), Vehicle method (local pref) | These are the defaults capture/tax consume; editing them does **not** rewrite historical claims (F1 snapshots rates per entry). |

`gst_rate_bps` and `mileage_rate_cents_per_km` are shown read-only (current ATO values) in v1 — no editor field (YAGNI; not asked for).

## 5. Categories & smart-rules

- **Category list** (`CategoriesView`): the iOS-config plan adds a `CategorySeeder` (mirroring `TaxSettingsSeeder`) that ensures the built-in `Category` rows exist for the active profile on first open — derived from the `CategoryKey` set in `Snapceipt/Model/Categories.swift` (label/icon/tint/default deductible/`isIncome`). The list shows each category's label/icon + a **derived** receipt count (`FetchDescriptor<Transaction>` count by `catKey` for the active profile) + an editable **default deductible %** (→ `Category.defaultDeductiblePct`, `try save()` + `enqueue(op:"upsert", .category)`). No add/delete of categories.
- **Smart-rules** (`RuleEditorView` reached via `.ruleEditor(id:)`): full CRUD over `SmartRule` (matchType ∈ {merchant_contains, merchant_equals, merchant_regex}, matcher text, target category, set-deductible %, set-mode, priority, enabled). A `SmartRulesViewModel` does list + create/update/delete via `sync.enqueue`. Rules are profile-scoped.

## 6. Privacy & security — Face ID app-lock

- A `Privacy & security` screen with one toggle: **"Require Face ID / Touch ID to unlock"**. State stored in `UserDefaults` (`sc.lock.enabled` — a non-secret boolean, cleared on reinstall), read at launch.
- An `AppLockController` (`@Observable @MainActor`): on cold launch and `scenePhase` → `.active` (from background), if lock is enabled, present a blocking lock screen and call `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` (biometry with device-passcode fallback). On success, reveal the app; on failure, stay locked with a "Try again" button.
- Enabling the toggle requires a successful biometric check first (so a user can't lock themselves out on a device without biometry/passcode). If `canEvaluatePolicy` is false, the toggle is disabled with an explanatory caption.
- No backend. Hermetic-test seam: a launch argument (e.g. `-uiTestStub`) forces `AppLockController` to treat auth as unavailable/always-pass so UI tests are unaffected.

## 7. FY-start wiring cleanup

Replace the hardcoded `startMonth: 7` at every call site with the active profile's `tax_settings.financialYearStartMonth`. Sites (from the audit): `RootView.swift` (Mileage init, WFH init, export window), `ReportsView.swift` (constructor), `MileageScreen.swift` (`FinancialYear.of(...)`), `AppLaunch.swift` (seed). `FinancialYear.of(_:startMonth:)` keeps its `= 7` default (safe fallback) but callers pass the real value. A small `@MainActor` helper on `ProfilesStore` (or a `TaxSettingsStore`) resolves the active profile's FY-start month (defaulting to 7 if no row), so views read one source. Each touched screen keeps its existing tests green; add a test that a non-7 FY start flows through `FinancialYear.of`.

## 8. Account & Security backend — AUTHORITATIVE CONTRACT (backend ↔ iOS)

**The backend and the iOS account-security plan must both conform to this section verbatim.** New routes mounted under a new `src/routes/account.ts` (+ extend `src/routes/devices.ts`); all auth-gated; new rate tier `"account"` (tight, e.g. 20/hr/user). No `PUBLIC_PATHS` change.

### 8.1 Change email (6-digit code)

| Method & path | Behaviour | Response |
|---|---|---|
| `POST /users/me/email` | Validate `newEmail` (shape + not equal to current + not already used by another non-deleted user → `409 CONFLICT`). Generate a 6-digit numeric code; store `ec:<userId>` in KV = `{ codeHash: sha256(code), newEmail }`, TTL 600s (mirrors the magic-link `ml:` pattern). Email the code to `newEmail` via `env.EMAIL` (gated/try-catch like magic-link; in `E2E_TEST_MODE` also return the code as `devCode`). | `202 { sent: true, devCode?: string }` |
| `POST /users/me/email/verify` | Read `ec:<userId>`; if absent → `410 GONE`; compare `sha256(code)` → mismatch `400 VALIDATION_FAILED`. On match: `UPDATE users SET email = ?, updated_at = ? WHERE id = ?`, delete the KV key (single-use), return the updated user. | `200 { user: { id, email, displayName, plan } }` |

Request bodies: `{ "newEmail": string }` / `{ "code": string }`.

### 8.2 Device list + revoke

| Method & path | Behaviour | Response |
|---|---|---|
| `GET /auth/me` | **Existing** — already returns `{ user, devices: [{ id, platform, model, osVersion, hasApnsToken, pushEnabled, lastSeenAt, createdAt }] }`. The device-list UI reads this (no new endpoint). | `200` (unchanged) |
| `DELETE /devices/:id` | Verify the device belongs to `c.var.userId` (else `404`). Soft-delete it (`deleted_at = nowMs`, `updated_at = nowMs`) AND revoke its sessions: `UPDATE sessions SET revoked_at = ? WHERE user_id = ? AND device_id = ? AND revoked_at IS NULL`. Revoking the caller's own current device is allowed (the app then signs out). | `200 { ok: true }` |

### 8.3 Delete account (immediate hard purge)

`DELETE /account` (authed). Hard-delete every row owned by `c.var.userId` across the **25 user-scoped tables** (every table with a `user_id` column), in FK-safe child→parent order, then delete the user's R2 objects, then return. (`email_tokens` has no `user_id` column — if that table is in use, also delete its rows for the user's current email; the plan verifies this at build time.)

D1 deletes (run as one `db.batch([...])` transaction; order matters because D1 enforces FKs):
```
1. line_items, quote_line_items, receipt_images          -- leaves referencing transactions/quotes
2. transactions                                          -- references categories, profiles, mileage_trips
3. smart_rules, budgets                                  -- reference categories
4. mileage_trips, vehicle_years                          -- vehicle_years references vehicles
5. vehicles
6. categories
7. quotes                                                -- references clients
8. clients, tax_settings, loyalty_cards, wfh_logs,
   inbound_email_log, profile_inbox_tokens, quote_counters,
   email_outbox, processed_mutations, sessions, devices,
   auth_identities                                       -- all reference users/profiles only
9. profiles
10. users
```
R2 purge: `env.RECEIPTS.list({ prefix: "u/" + userId + "/" })` paginated (`cursor`/`truncated`) → `env.RECEIPTS.delete(keys)` per page until exhausted. Run the R2 purge inside `ctx.waitUntil` is NOT used (we must finish before responding so the client can trust completion); do it inline before the 200. Response: `200 { ok: true }`. After success the client clears the Keychain and returns to auth. (Sessions are purged in the D1 batch, so any other device is also logged out on its next call.)

### 8.4 iOS `APIClient` additions (all four conformers)

```swift
func requestEmailChange(newEmail: String) async throws -> EmailChangeRequested   // POST /users/me/email
func verifyEmailChange(code: String) async throws -> AccountUser                  // POST /users/me/email/verify
func revokeDevice(id: String) async throws                                        // DELETE /devices/:id
func deleteAccount() async throws                                                 // DELETE /account
// me() already exists -> drives the device list (MeResponse.devices).
```
DTOs: `struct EmailChangeRequested: Decodable { let sent: Bool; let devCode: String? }`; `struct AccountUser: Decodable, Equatable { let id: String; let email: String?; let displayName: String?; let plan: String }` (defined fresh — distinct from `SessionUser`, which lacks `plan`; the verify response is `{ user: AccountUser }`). Stub/Preview return canned values (`devCode: "000000"`, a fixed user); Mock records calls + returns configurable responses.

## 9. Error handling

- **Backend** — change-email: duplicate email `409`; expired/missing code `410`; wrong code `400`. Device revoke: not-owned `404`. Delete account: the D1 batch is atomic (all-or-nothing); the R2 purge is best-effort per page and logged (a failed R2 page does not 500 the request — the D1 rows are already gone, orphaned R2 objects are swept by a later lifecycle rule); return `200` once D1 is purged.
- **iOS** — change-email: invalid-email inline validation before send; wrong/expired code → inline error + "Resend code"; success → toast + the hub reflects the new email (re-fetch `me()`). Device revoke: confirm dialog; revoking the current device → sign out to auth. Delete account: typed-confirmation dialog (type `DELETE`) → on success clear Keychain + route to auth; on failure show an error and stay. Face ID: `canEvaluatePolicy` false → toggle disabled w/ caption; auth failure → stay locked with retry.

## 10. Testing

### 10.1 Backend (vitest; baseline 309 unit / 17 e2e)
- **Change email**: `POST /users/me/email` stores the KV code + (E2E) returns `devCode`; duplicate email → 409; `verify` with the right code swaps `users.email` + deletes the KV key; wrong code → 400; expired/missing → 410. (Use `E2E_TEST_MODE` for `devCode`.)
- **Device revoke**: `DELETE /devices/:id` soft-deletes + revokes that device's sessions; another user's device → 404; the device drops out of `GET /auth/me`.
- **Delete account**: seed a user with rows across several tables + an R2 object → `DELETE /account` → assert every user-scoped table has 0 rows for that user AND the R2 prefix is empty AND sessions are revoked. A second user's data is untouched (isolation).
- **e2e** (`+≈2`): sign in → `POST /users/me/email` (devCode) → verify → `GET /auth/me` shows the new email; and a delete-account round-trip (sign in → seed via `/sync/push` → `DELETE /account` → subsequent authed call 401).

### 10.2 iOS (Swift Testing + XCUITest; baseline 319 unit / 12 UI)
- **VMs**: `TaxSettingsViewModel` (load/edit/enqueue; Personal hides identity; `nextBasDue` pure helper), `CategoriesViewModel` (derived counts; edit default % enqueues), `SmartRulesViewModel` (CRUD + enqueue), `ProfilesStore.update/delete` (last-profile + active-profile guards), `AccountViewModel` (request→verify email via `MockAPIClient`; revoke device; delete account clears session), `AppLockController` (enabled+available → locked→unlock; unavailable → toggle disabled), and a `FinancialYear` test that a non-7 FY start flows correctly.
- **DTO decode** for `EmailChangeRequested` / `AccountUser` + Mock records.
- **UI (hermetic, seeded)**: Settings hub renders the groups; open Tax & GST → toggle GST / edit meals % → persists; open Categories → edit a default %; ProfileDetail → edit name → reflected; Account → enter new email → enter the stub code `000000` → success; the delete-account typed-confirm dialog appears (UI test asserts the dialog + cancel; the destructive confirm itself is exercised by the VM/`MockAPIClient`, not against a live backend). Face ID is stub-bypassed under `-uiTestStub`.

## 11. Targets after F7
- Backend: `npm test` ≈ 309 + new (`account`/change-email/device-revoke/delete-account suites), e2e 17 → ≈19, typecheck clean.
- iOS: unit 319 + new VM/DTO tests, UI 12 → ≈14 (Settings hub + account flows), full suite green.

## 12. Plan split (Approach B — one spec, three plans)
1. **`2026-06-02-settings-backend.md`** — `account.ts` (change-email request/verify, delete-account cascade), `DELETE /devices/:id`, the `account` rate tier, the KV `ec:` code store, tests + e2e. §8 is its contract.
2. **`2026-06-02-settings-ios-config.md`** — Settings-hub restructure, Tax & GST editor, Categories & smart-rules, profile edit/delete + ProfileDetail, FY-start cleanup, `ProfilesStore.update/delete`, the new Router overlays + AccessibilityIDs + RootView wiring, VM + UI tests.
3. **`2026-06-02-settings-ios-account.md`** — the four `APIClient` methods (+4 conformers) + DTOs, `AccountViewModel` + Account screen (email + device list/revoke + delete-account), `ChangeEmail` flow, `AppLockController` + Privacy screen, VM + UI tests. Depends on plan 1's contract (§8) and plan 2's hub (the Account/Privacy rows).
