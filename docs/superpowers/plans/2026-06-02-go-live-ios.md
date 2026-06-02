# Go-live iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Point the iOS app at the production backend by renaming the API origin and all `snapceipt.app` references → `snapceipt.cc`, keeping the suite green.

**Architecture:** The iOS API base URL is **compile-time** — three hardcoded literals (`SnapceiptApp.swift:51` and `RootView.swift:608` for Release, `AppLaunch.swift:120` for the DEBUG default) plus two relative-link bases. The only runtime override is `apiBaseURLOverride`, fed by the `API_BASE_URL` env var inside a `#if DEBUG` block (a UI-test seam). So this rename is a mechanical edit guarded by the existing test suite, with one functionally-coupled pair (`StubAPIClient` preview address ↔ `EmailInUITests` assertion). `MagicLinkParser` ignores the URL host, so no parser change is needed.

**Tech Stack:** Swift / SwiftUI, XcodeGen (`project.yml`), `xcodebuild`, iPhone 16 simulator.

**Spec:** `docs/superpowers/specs/2026-06-02-go-live-backend-design.md` (§4 Track B, §8 prerequisite).

**Cross-plan contract (must match the backend plan):**
- API origin: `https://api.snapceipt.cc`
- Email-in alias domain: `in.snapceipt.cc`
- Custom scheme (unchanged): `snapceipt://auth/verify?token=…`
- iOS bundle id (unchanged): `app.snapceipt.Snapceipt`

**Baseline:** `xcodebuild test` ≈ 359 (last green) + 1 `LiveSmoke` skip. The iOS tree has **no** `com.snapceipt.app` / `snapceipt.app` bundle-id strings (its bundle id is `app.snapceipt.Snapceipt`, which does not contain the substring `snapceipt.app`), so a blanket `snapceipt.app` → `snapceipt.cc` over the iOS dirs is safe.

---

## Task 1: Domain rename `snapceipt.app` → `snapceipt.cc` (iOS)

**Files:**
- Modify (source): `Snapceipt/App/AppLaunch.swift:120`, `Snapceipt/App/RootView.swift:608`, `Snapceipt/App/SnapceiptApp.swift:51`, `Snapceipt/Features/Quotes/QuoteEditorView.swift:239`, `Snapceipt/Features/Reports/ExportSheet.swift:154`, `Snapceipt/Features/Auth/AuthViewModel.swift:13-14` (comment), `Snapceipt/App/DevAccount.swift:6`, `Snapceipt/Features/Profiles/ProfileTabView.swift:168`, `Snapceipt/Features/Auth/SignInView.swift:196,200` (preview), `Snapceipt/Sync/StubAPIClient.swift:66,70` (preview — **coupled to the UI test below**)
- Modify (tests): `SnapceiptTests/AuthViewModelTests.swift` (108,134,188), `SnapceiptTests/APIClientTests.swift` (184,194), `SnapceiptTests/DeepLinkRoutingTests.swift` (16), `SnapceiptTests/MagicLinkParserTests.swift` (15,21,33), `SnapceiptTests/InboxAddressResponseTests.swift` (9,13,21,24), `SnapceiptTests/EmailInViewModelTests.swift` (62,63,67,69), `SnapceiptUITests/EmailInUITests.swift` (25)

- [ ] **Step 1: Update the production base-URL source literals**

```swift
// Snapceipt/App/AppLaunch.swift:120
        let base = apiBaseURLOverride ?? URL(string: "https://api.snapceipt.cc")!
```
```swift
// Snapceipt/App/RootView.swift:608
        return LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.cc")!, auth: auth)
```
```swift
// Snapceipt/App/SnapceiptApp.swift:51
        let api: APIClient = LiveAPIClient(baseURL: URL(string: "https://api.snapceipt.cc")!, auth: auth)
```
```swift
// Snapceipt/Features/Quotes/QuoteEditorView.swift:239
        let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
```
```swift
// Snapceipt/Features/Reports/ExportSheet.swift:154
                let full = url.hasPrefix("http") ? url : "https://api.snapceipt.cc\(url)"
```

- [ ] **Step 2: Update the remaining source references (comments, dev email, help URL, previews)**

For `AuthViewModel.swift:13-14` (doc comment), `DevAccount.swift:6` (`"dev@snapceipt.cc"`), `ProfileTabView.swift:168` (`"https://snapceipt.cc/help"`), `SignInView.swift:196,200` and `StubAPIClient.swift:66,70` (`"r.…@in.snapceipt.cc"`): replace `snapceipt.app` → `snapceipt.cc` in each. Concretely:
```swift
// Snapceipt/App/DevAccount.swift:6
    static let email = "dev@snapceipt.cc"
```
```swift
// Snapceipt/Sync/StubAPIClient.swift:66 & 70 (preview addresses — keep tokens, swap domain)
                             address: "r.stubtokeninitial@in.snapceipt.cc")
                             address: "r.stubtokenrotated@in.snapceipt.cc")
```
> The `StubAPIClient` change is **coupled** to `EmailInUITests:25` (Step 4) — the UI test asserts the displayed address contains `@in.snapceipt.cc`, which the stub now supplies.

- [ ] **Step 3: Update the test-file `snapceipt.app` strings → `snapceipt.cc`**

All are `snapceipt.app` → `snapceipt.cc` substitutions (none are bundle ids). Examples:
```swift
// SnapceiptTests/MagicLinkParserTests.swift:15,21,33
        let url = try #require(URL(string: "https://snapceipt.cc/auth/verify?token=xyz-789_QQ"))
        let url = try #require(URL(string: "https://snapceipt.cc/auth/magic?token=tok42"))
        let url = try #require(URL(string: "https://snapceipt.cc/blog?token=nope"))
```
```swift
// SnapceiptTests/AuthViewModelTests.swift:108,134,188
        let url = try #require(URL(string: "https://snapceipt.cc/auth/verify?token=deep-tok"))
        let url = try #require(URL(string: "https://snapceipt.cc/help"))
                                   user: SessionUser(id: "u-dev", email: "dev@snapceipt.cc", displayName: "Dev"))
```
```swift
// SnapceiptTests/APIClientTests.swift:184,194  → email: "dev@snapceipt.cc"
// SnapceiptTests/DeepLinkRoutingTests.swift:16 → URL(string: "https://snapceipt.cc/budget/x")
// SnapceiptTests/InboxAddressResponseTests.swift:9,13,21,24 → "r.…@in.snapceipt.cc"
// SnapceiptTests/EmailInViewModelTests.swift:62,63,67,69    → "r.t1@in.snapceipt.cc" / "r.t2@in.snapceipt.cc"
```

- [ ] **Step 4: Update the coupled UI-test assertion**

```swift
// SnapceiptUITests/EmailInUITests.swift:25
        XCTAssertTrue(address.label.contains("@in.snapceipt.cc"), "Address not formatted")
```

- [ ] **Step 5: Verify no `snapceipt.app` reference lingers in the iOS tree**

Run: `grep -rn 'snapceipt\.app' Snapceipt SnapceiptTests SnapceiptUITests`
Expected: no output.

- [ ] **Step 6: Build + run the iOS test suite**

Run:
```bash
xcodebuild test -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:SnapceiptTests -only-testing:SnapceiptUITests
```
Expected: PASS — ≈359 tests (1 `LiveSmokeUITests` XCTSkip). In particular `MagicLinkParserTests`, `EmailInUITests`, `InboxAddressResponseTests`, and `EmailInViewModelTests` pass against the renamed strings.

- [ ] **Step 7: Commit**

```bash
git add Snapceipt SnapceiptTests SnapceiptUITests
git commit -m "refactor(go-live): point iOS at api.snapceipt.cc (rename snapceipt.app)"
```

---

## Verify prerequisite (operator — from spec §8)

Because the base URL is compiled in, the end-to-end verify needs a **rebuild + reinstall** on the iPhone 16 simulator after this rename. Run the verify as a **DEBUG build** (Xcode/`xcodebuild` → `AppLaunch.swift:120` default `https://api.snapceipt.cc`), or pass `API_BASE_URL=https://api.snapceipt.cc` as the DEBUG override. Then complete sign-in via `xcrun simctl openurl booted "snapceipt://auth/verify?token=…"` (the magic-link email lands in an external inbox; the `https://…/auth/magic` tap only reaches the app once Universal Links exist, which are out of scope).

---

## Self-review (completed during authoring)

- **Spec coverage:** Track B iOS rename → Task 1 (all 10 source sites + 7 test files from spec §4); compile-time/rebuild caveat → Verify prerequisite. ✓
- **Placeholder scan:** no TBD/TODO; each step shows the exact resulting line(s). ✓
- **Name consistency:** `apiBaseURLOverride`, `LiveAPIClient`, `MagicLinkParser`, `StubAPIClient`, `EmailInUITests` match the existing code; new host `https://api.snapceipt.cc` matches the backend plan's contract. ✓
- **Coupling called out:** `StubAPIClient` preview address ↔ `EmailInUITests:25` assertion (Steps 2 & 4) — the one functional change among otherwise cosmetic edits. ✓
