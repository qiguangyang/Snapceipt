# Snapceipt iOS App Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. **Read the "Canonical Contracts" section below before any task — it is authoritative and overrides any conflicting name, signature, path, or build-order in a task block. Execute the tasks in the build order given there (it differs slightly from numeric order to remove backward dependencies).**

**Goal:** Stand up the Snapceipt iOS app foundation — the design system, the SwiftData model + sync envelope, the local-first sync client (APIClient + SyncEngine + Keychain + offline outbox), auth + onboarding UI, profiles + switcher, and the app shell + cross-cutting toast/sync-status/offline UI — all building and testing on the iOS Simulator.

**Architecture:** SwiftUI + SwiftData + Observation, local-first. SwiftData is the instant write store; an offline `OutboxMutation` queue + a `SyncEngine` reconcile with the backend (`/sync/push` + `/sync/pull`, LWW on `updatedAt`, tombstones) defined in the backend-foundation plan. Active profile drives a runtime accent re-skin via the environment. Capture/OCR, reports, budgets, loyalty, quotes, logbooks, and settings detail are later phases (reuse `ReceiptScanner.swift` for capture in P1).

**Tech Stack:** Swift 5.10+, iOS 17+, SwiftUI, SwiftData, Observation; Swift Testing (`import Testing`); XcodeGen (`project.yml`) → `Snapceipt.xcodeproj`; build/test via `xcodebuild ... -destination "platform=iOS Simulator,name=iPhone 16"`. Sign in with Apple (`AuthenticationServices`), Keychain (`Security`), `NWPathMonitor`.

**Spec:** `docs/superpowers/specs/2026-05-30-snapceipt-ios-app-design.md` (§5.2, §6, §7, §8, §9, §13, §15). Pixel tokens: `docs/superpowers/specs/extracted/screens.md`. **Backend contract this app calls:** `docs/superpowers/plans/2026-05-30-backend-foundation.md`.

---

## Canonical Contracts (AUTHORITATIVE — reconcile every task to these)

The tasks were drafted in parallel; this section pins the cross-cutting names and the build order. **Where a task disagrees, this section wins.**

### Canonical names (resolve the drift)

| Concept | Canonical | Reject these variants |
|---|---|---|
| Push result element | `PushResult` (element of `PushResponse.results`) | `PushMutationResult` |
| Pull change element | `PullChange` (element of `PullResponse.changes`) | `EntityEnvelope`, `PulledEnvelope` |
| Container factory | `makeSnapceiptContainer(inMemory: Bool = false)` in `Model/ModelContainer+Snapceipt.swift` | `makeContainer(inMemory:)` |
| Sync-status view | `SyncStatusView` in `Shared/SyncStatusView.swift` | `SyncStatusPill` |
| Money formatting | free funcs `fmt(_:sign:showCents:)`, `fmtK(_:)`, `fmtDate(_:style:)` (Task 4) | `Money.fmt` method |
| API mock (tests) | one `MockAPIClient` in `SnapceiptTests/Mocks/MockAPIClient.swift` | per-task duplicates |

- **`makeSnapceiptContainer`:** Task 1 **creates** it with an empty schema; Task 8 **modifies** it to register all `@Model` types + `OutboxMutation` (do not create a second factory). Add an `inMemory:` parameter (used by tests via `ModelConfiguration(isStoredInMemoryOnly: true)`).
- **`MockAPIClient`:** the SyncEngine task (Task 11) creates `SnapceiptTests/Mocks/MockAPIClient.swift` (conforming to the `APIClient` protocol); Tasks 12 and 14 **reuse** it (no redefinition).
- **Accent hexes single source:** Task 2 owns the personal (`#E8602C/#FDEBE0/#C2461A`) and business (`#0E7C72/#DCF0ED/#0A5950`) `AccentPalette` presets (`AccentPalette.personal`, `.business`). Task 13's `AP_ACCENTS` swatch list **references** those two presets and adds the other six swatches — the personal/business triples are defined once, in Task 2.

### SmartRule (the 12th syncable type)

`EntityType` has 12 cases including `smartRule` (backend table `smart_rules`). **Task 8 must add this `SmartRule` `@Model`** at `Model/Entities/SmartRule.swift`, register it in `makeSnapceiptContainer`'s schema, and map it in the SyncEngine entity registry so all 12 types round-trip (do not leave `smartRule` unmapped):

```swift
import SwiftData

@Model final class SmartRule: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?
    var matchType: String        // "merchant_contains" | "merchant_equals" | "merchant_regex"
    var matcher: String
    var categoryId: String?
    var setDeductiblePct: Int?
    var setMode: String?         // "business" | "personal" | nil
    var priority: Int
    var enabled: Bool
    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?
    var entityType: EntityType { .smartRule }

    init(id: String = ID.uuidv7(), userId: String, profileId: String? = nil,
         matchType: String = "merchant_contains", matcher: String,
         categoryId: String? = nil, setDeductiblePct: Int? = nil, setMode: String? = nil,
         priority: Int = 0, enabled: Bool = true,
         createdAt: Int = Clock.nowMs(), updatedAt: Int = Clock.nowMs(),
         deletedAt: Int? = nil, rev: Int = 0, lastEditedDeviceId: String? = nil) {
        self.id = id; self.userId = userId; self.profileId = profileId
        self.matchType = matchType; self.matcher = matcher; self.categoryId = categoryId
        self.setDeductiblePct = setDeductiblePct; self.setMode = setMode
        self.priority = priority; self.enabled = enabled
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.rev = rev; self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

### Build order & early shared types (resolve backward dependencies)

Several small types are *defined* in late tasks but *used* by earlier ones. To remove the cycle, **create these three files as part of Task 1's scaffold**, then let the later tasks add behavior to them (modify, not recreate):

1. **`App/Router.swift`** — create in Task 1 with this canonical definition (Task 14 only adds new `Overlay` cases + wiring later):

```swift
import SwiftUI
import Observation

enum Tab: String, CaseIterable { case home, activity, snap, reports, profile }
enum Overlay: Equatable { case profilePicker, addProfile }   // more cases added in later phases

@Observable final class Router {
    var tab: Tab = .home
    var overlay: Overlay? = nil
    func go(_ tab: Tab) { self.tab = tab }
    func present(_ overlay: Overlay) { self.overlay = overlay }
    func dismissOverlay() { overlay = nil }
}
```

2. **`Shared/Toast.swift`** — create in Task 1 with this canonical definition (Task 14 adds the `ToastHost` overlay view if not already present here):

```swift
import SwiftUI
import Observation

enum ToastKind { case info, success, error }
struct ToastItem: Identifiable, Equatable { let id = UUID(); let message: String; let kind: ToastKind }

@Observable final class ToastCenter {
    private(set) var current: ToastItem?
    func show(_ message: String, kind: ToastKind = .info) { current = ToastItem(message: message, kind: kind) }
    func clear() { current = nil }
}

struct ToastHost: ViewModifier {
    @Bindable var center: ToastCenter
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = center.current {
                Text(t.message).font(.ui(13.5, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(t.kind == .error ? Palette.alert : Palette.ink, in: Capsule())
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); center.clear() }
            }
        }
    }
}
extension View { func toastHost(_ center: ToastCenter) -> some View { modifier(ToastHost(center: center)) } }
```

3. **`Sync/DTOs.swift`** — create in Task 1 (or as the first step of Task 9) using the exact Codable structs defined in Task 10. They must exist before Task 9 (`AuthStore`) so there is **no** "guarded shim" and **no** duplicate `SessionResponse`/`SessionUser`. Canonical DTO set (full bodies in Task 10): `SessionResponse { accessToken, refreshToken, expiresIn, user: SessionUser }`, `SessionUser { id, email?, displayName? }`, `MeResponse { user, devices }`, `PushMutation`, `PushResult { mutationId, status, reason?, entity? }`, `PushResponse { results: [PushResult], serverTime }`, `PullChange` (the envelope), `PullResponse { changes: [PullChange], nextCursor?, hasMore, serverTime }`, `ApiErrorEnvelope { error: { code, message, requestId } }`.

**`SyncEngine` ↔ `ToastCenter`:** `SyncEngine` is constructed with an injected `ToastCenter` (add it to the init) so a push `conflict` can `toast.show("Updated on another device")` without a backward dependency.

**RootView composition:** Task 1 creates `App/RootView.swift` (placeholder); Task 12 edits it to gate on auth (signed-out → SignIn, signed-in-no-profile → Onboarding); Task 14 edits it to compose the authed shell (TabBar + tab content + overlays + ToastHost + OfflineBanner + SyncStatusView). Apply these edits in order 1 → 12 → 14; they compose (each adds a branch/section), they do not overwrite.

**Recommended execution order:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14. (Task 1 now also creates `Router.swift`, `Toast.swift`, and the `DTOs.swift` structs per above, which is why 9–14 have no backward dependency.)

---

## Tasks

### Task 1: Scaffold — XcodeGen project, app shell stub, fonts, and the Swift Testing harness

This task stands up the buildable foundation: a checked-in `project.yml` that XcodeGen turns into `Snapceipt.xcodeproj`, an app target (iOS 17 deployment, SwiftUI) with a minimal `SnapceiptApp` + placeholder `RootView`, a SwiftData `ModelContainer` over an **empty** schema (later tasks register `@Model` types into `makeSnapceiptContainer`), the two bundled font files wired through `Info.plist` `UIAppFonts`, and a `SnapceiptTests` target running the Swift Testing framework with a first trivial test. No domain types are defined here — those are owned by later tasks and will be added to the schema/sources then.

Verified against this machine before writing: XcodeGen `2.45.4`, Xcode `26.5` (only `iphonesimulator26.5` SDK present), Swift `6.3.2` (Swift Testing ships in-toolchain — `import Testing` needs no package dependency). Note: the simulators installed here are the iPhone 17 family; the shared spine pins **"iPhone 16"** for every task, so **Step 0** ensures that simulator exists before any `xcodebuild` run.

**Files**
- Create: `project.yml`
- Create: `Snapceipt/Info.plist`
- Create: `Snapceipt/App/SnapceiptApp.swift`
- Create: `Snapceipt/App/RootView.swift`
- Create: `Snapceipt/Model/ModelContainer+Snapceipt.swift`
- Create: `Snapceipt/Resources/Fonts/.gitkeep` (+ author notes for the two `.ttf` files)
- Modify: `.gitignore` (ignore the generated `*.xcodeproj`)
- Test: `SnapceiptTests/SmokeTests.swift`

---

- [ ] **Step 0: Ensure the pinned "iPhone 16" simulator exists**

The whole plan runs `xcodebuild ... -destination "platform=iOS Simulator,name=iPhone 16"`. This machine ships iPhone 17 simulators only, so create an "iPhone 16" runtime-backed device once (idempotent — it no-ops if already present). Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
if ! xcrun simctl list devices available | grep -q "iPhone 16 ("; then
  RUNTIME=$(xcrun simctl list runtimes | awk -F'[()]' '/iOS/{print $0}' | tail -1 | sed -n 's/.*(\(com.apple.CoreSimulator.SimRuntime.iOS[^)]*\)).*/\1/p')
  DEVTYPE=$(xcrun simctl list devicetypes | sed -n 's/.*(\(com.apple.CoreSimulator.SimDeviceType.iPhone-16\)).*/\1/p' | head -1)
  if [ -z "$DEVTYPE" ]; then DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16"; fi
  xcrun simctl create "iPhone 16" "$DEVTYPE" "$RUNTIME"
fi
xcrun simctl list devices available | grep "iPhone 16 ("
```

Expected: the final `grep` prints a line containing `iPhone 16 (` (either a pre-existing device or the one just created). If the device type `iPhone-16` is unavailable in this Xcode, substitute the nearest device type id printed by `xcrun simctl list devicetypes` and re-run; the name must remain exactly `iPhone 16` so the pinned destination resolves.

- [ ] **Step 1: Write `project.yml` (XcodeGen spec for the app + test targets)**

Defines target `Snapceipt` (iOS 17 deployment, SwiftUI app, sources under `Snapceipt/`, the fonts folder as a resource, `Info.plist` path) and target `SnapceiptTests` (unit-test bundle depending on `Snapceipt`). Swift Testing needs no extra dependency — it is bundled with the toolchain and discovered by the XCTest-compatible test bundle. A scheme `Snapceipt` wires build + test. Create `project.yml`:

```yaml
name: Snapceipt
options:
  bundleIdPrefix: app.snapceipt
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true
settings:
  base:
    SWIFT_VERSION: "5.10"
    DEVELOPMENT_TEAM: ""
    CODE_SIGN_STYLE: Automatic
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  Snapceipt:
    type: application
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Snapceipt
        excludes:
          - "Info.plist"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.snapceipt.Snapceipt
        INFOPLIST_FILE: Snapceipt/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO
        TARGETED_DEVICE_FAMILY: "1"
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"
        ENABLE_PREVIEWS: YES
        SWIFT_EMIT_LOC_STRINGS: YES
  SnapceiptTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: SnapceiptTests
    dependencies:
      - target: Snapceipt
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.snapceipt.SnapceiptTests
        GENERATE_INFOPLIST_FILE: YES
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/Snapceipt.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Snapceipt"
        BUNDLE_LOADER: "$(TEST_HOST)"
schemes:
  Snapceipt:
    build:
      targets:
        Snapceipt: all
        SnapceiptTests: [test]
    test:
      targets:
        - SnapceiptTests
      gatherCoverageData: false
```

- [ ] **Step 2: Write `Snapceipt/Info.plist` (UIAppFonts + scene config)**

Registers the two bundled font files under `UIAppFonts` and supplies a minimal SwiftUI app Info.plist (`GENERATE_INFOPLIST_FILE: NO`, so this file is authoritative). Filenames match the Google Fonts static TTF exports dropped in Step 3. Create `Snapceipt/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en_AU</string>
	<key>CFBundleDisplayName</key>
	<string>Snapceipt</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>UILaunchScreen</key>
	<dict>
		<key>UIColorName</key>
		<string></string>
	</dict>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
	</array>
	<key>UIRequiresFullScreen</key>
	<true/>
	<key>UIAppFonts</key>
	<array>
		<string>SchibstedGrotesk-Regular.ttf</string>
		<string>SchibstedGrotesk-Medium.ttf</string>
		<string>SchibstedGrotesk-SemiBold.ttf</string>
		<string>SchibstedGrotesk-Bold.ttf</string>
		<string>SchibstedGrotesk-ExtraBold.ttf</string>
		<string>HankenGrotesk-Regular.ttf</string>
		<string>HankenGrotesk-Medium.ttf</string>
		<string>HankenGrotesk-SemiBold.ttf</string>
		<string>HankenGrotesk-Bold.ttf</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Create the fonts folder + author note for the `.ttf` files**

`project.yml` lists `Resources/Fonts` as a resource and `Info.plist` references the nine TTFs above. The actual font binaries are not in the repo yet. Create a placeholder so the folder is tracked, and document exactly which files to drop. Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
mkdir -p Snapceipt/Resources/Fonts
cat > Snapceipt/Resources/Fonts/.gitkeep <<'EOF'
Drop the bundled font binaries here (static TTF, NOT variable). Filenames MUST match
Snapceipt/Info.plist UIAppFonts exactly:

  Schibsted Grotesk (--display: numbers, headings, initials):
    SchibstedGrotesk-Regular.ttf      (400)
    SchibstedGrotesk-Medium.ttf       (500)
    SchibstedGrotesk-SemiBold.ttf     (600)
    SchibstedGrotesk-Bold.ttf         (700)
    SchibstedGrotesk-ExtraBold.ttf    (800)

  Hanken Grotesk (--ui: all body/UI text):
    HankenGrotesk-Regular.ttf         (400)
    HankenGrotesk-Medium.ttf          (500)
    HankenGrotesk-SemiBold.ttf        (600)
    HankenGrotesk-Bold.ttf            (700)

Source: Google Fonts (https://fonts.google.com/specimen/Schibsted+Grotesk and
/Hanken+Grotesk). Download each family, take the STATIC instances from the
"static/" folder of the zip, rename to the exact names above (Google ships e.g.
"SchibstedGrotesk-Regular.ttf" already; Hanken static files are named likewise).
Both fonts are OFL-1.1 licensed — keep the OFL.txt alongside.

DesignSystem/Fonts.swift (Task 2) maps Font.display(_:_:) -> Schibsted Grotesk
and Font.ui(_:_:) -> Hanken Grotesk by these registered PostScript family names.
EOF
ls -la Snapceipt/Resources/Fonts
```

Expected: `.gitkeep` exists under `Snapceipt/Resources/Fonts`. The build still succeeds with the folder present even before the TTFs are added (custom-font lookups fall back to the system font at runtime; only the on-device visual fidelity needs the real files). Drop the nine TTFs before any UI screenshot/QA step in later tasks.

- [ ] **Step 4: Write `Snapceipt/Model/ModelContainer+Snapceipt.swift` (shared container factory, empty schema for now)**

Centralises SwiftData container creation. Later tasks append their `@Model` types to the `schema` array and the in-memory test container. For this task the schema is empty (SwiftData accepts an empty `Schema([])`). Verified API: `Schema(_:)`, `ModelConfiguration(schema:isStoredInMemoryOnly:)`, `ModelContainer(_:configurations:)` (iOS 17+). Create `Snapceipt/Model/ModelContainer+Snapceipt.swift`:

```swift
import Foundation
import SwiftData

/// Central place that knows the full SwiftData schema for the app.
/// Later tasks append their `@Model` types to `snapceiptSchema`.
enum SnapceiptSchema {
    /// Every persisted `@Model` type. Empty in the foundation scaffold;
    /// Task 3+ register `Profile`, `Transaction`, `OutboxMutation`, etc. here.
    static var models: [any PersistentModel.Type] { [] }

    static var schema: Schema { Schema(models) }
}

/// Builds the app's shared `ModelContainer`.
/// - Parameter inMemory: when `true`, nothing is written to disk (used by tests/previews).
func makeSnapceiptContainer(inMemory: Bool = false) -> ModelContainer {
    let configuration = ModelConfiguration(
        schema: SnapceiptSchema.schema,
        isStoredInMemoryOnly: inMemory
    )
    do {
        return try ModelContainer(
            for: SnapceiptSchema.schema,
            configurations: [configuration]
        )
    } catch {
        // A failure here means the on-disk store is incompatible/corrupt.
        // Fall back to an in-memory store so the app still launches; the
        // real recovery flow (migration/reset) is owned by a later task.
        let fallback = ModelConfiguration(
            schema: SnapceiptSchema.schema,
            isStoredInMemoryOnly: true
        )
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: SnapceiptSchema.schema, configurations: [fallback])
    }
}
```

- [ ] **Step 5: Write `Snapceipt/App/RootView.swift` (placeholder shell)**

The real 5-tab shell + `Router` + overlays land in a later task. For the scaffold this is a single placeholder screen on the cream canvas showing the app name. No design tokens are referenced yet (Task 2 owns `Palette`/`Font.display`), so colors/fonts are inline literals here and will be replaced when `RootView` is rebuilt. Create `Snapceipt/App/RootView.swift`:

```swift
import SwiftUI

/// Placeholder root. Replaced by the real tab-bar shell (TabBar + Router + overlays)
/// in a later foundation task. Kept intentionally token-free so it builds before
/// the DesignSystem exists.
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 0xFB / 255, green: 0xF6 / 255, blue: 0xF0 / 255) // cream #FBF6F0
                .ignoresSafeArea()
            Text("Snapceipt")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color(red: 0x21 / 255, green: 0x1C / 255, blue: 0x18 / 255)) // ink #211C18
        }
    }
}

#Preview {
    RootView()
}
```

- [ ] **Step 6: Write `Snapceipt/App/SnapceiptApp.swift` (App entry + shared container)**

The `@main` entry creates the shared `ModelContainer` via `makeSnapceiptContainer()` and injects it with `.modelContainer(_:)` so later tasks can `@Environment(\.modelContext)` / `@Query` from anywhere. Hosts `RootView`. Create `Snapceipt/App/SnapceiptApp.swift`:

```swift
import SwiftUI
import SwiftData

@main
struct SnapceiptApp: App {
    /// The app-wide SwiftData container. Built once at launch; later tasks
    /// add models to `SnapceiptSchema` and wire stores (Sync, Profiles, etc.).
    let container: ModelContainer = makeSnapceiptContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 7: Add the generated Xcode project to `.gitignore`**

`Snapceipt.xcodeproj` is produced by `xcodegen generate` from the checked-in `project.yml`, so it should not be committed. Append an ignore rule. Apply this edit to `.gitignore` (insert after the existing `# Xcode / SwiftPM` block, before `.swiftpm/`):

```bash
cd /Users/yangqi/Documents/github/Snapceipt
printf '\n# Generated by XcodeGen from project.yml (do not commit)\n*.xcodeproj/\n' >> .gitignore
cat .gitignore
```

Expected: `.gitignore` now ends with a `*.xcodeproj/` rule under a "Generated by XcodeGen" comment. (The repo already ignores `*.xcodeproj/xcuserdata/`; the broader `*.xcodeproj/` rule supersedes it for the regenerated project.)

- [ ] **Step 8: Write the first failing test `SnapceiptTests/SmokeTests.swift`**

A trivial Swift Testing test proving the test target compiles, links against the host app, and runs on the simulator. Written to **fail first** (TDD discipline) so we see the harness actually execute, then flipped to pass in Step 10. Create `SnapceiptTests/SmokeTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("Smoke")
struct SmokeTests {
    @Test("test harness runs")
    func harnessRuns() {
        #expect(false) // deliberately failing first — flipped to true in the next step
    }
}
```

- [ ] **Step 9: Generate the project and run the test (expect FAIL)**

Install XcodeGen if missing, generate the Xcode project, then run only the smoke test. Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen generate
xcodebuild test -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:SnapceiptTests/Smoke/harnessRuns
```

Expected: `xcodegen generate` prints "Generated project at ... Snapceipt.xcodeproj". The test run **FAILS** with `Test harnessRuns() recorded an issue ... Expectation failed: (false ...)` and ends with `** TEST FAILED **`. This confirms the harness compiles, links, and executes the assertion.

- [ ] **Step 10: Make the smoke test pass**

Flip the expectation to a true condition that also touches the host app (proves `@testable import Snapceipt` linked the app module). Apply this edit to `SnapceiptTests/SmokeTests.swift`:

```swift
import Testing
@testable import Snapceipt

@Suite("Smoke")
struct SmokeTests {
    @Test("test harness runs")
    func harnessRuns() {
        #expect(Bool(true))
    }

    @Test("app module is importable and the SwiftData container builds")
    func containerBuilds() {
        let container = makeSnapceiptContainer(inMemory: true)
        #expect(container.configurations.isEmpty == false)
    }
}
```

- [ ] **Step 11: Build the app, then run the tests (expect PASS)**

Verify the app target builds on the simulator and the full smoke suite passes. Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
xcodebuild -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" build
xcodebuild test -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:SnapceiptTests/Smoke
```

Expected: the `build` invocation ends with `** BUILD SUCCEEDED **`. The `test` invocation runs both `harnessRuns()` and `containerBuilds()`, reports them passing, and ends with `** TEST SUCCEEDED **`.

- [ ] **Step 12: Commit the scaffold**

Stage everything (the `.xcodeproj` is git-ignored from Step 7). Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
git add project.yml Snapceipt SnapceiptTests .gitignore
git status --short
git commit -m "$(cat <<'EOF'
feat(ios): scaffold XcodeGen project, app shell stub, fonts, and Swift Testing harness

Add project.yml (Snapceipt app target iOS 17 + SnapceiptTests unit-test
target with Swift Testing), Info.plist with UIAppFonts for the two bundled
families, a minimal SnapceiptApp + placeholder RootView, an empty-schema
shared ModelContainer factory, the Resources/Fonts drop folder, and a
passing smoke suite. Generated *.xcodeproj is git-ignored.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: `git status --short` lists the new/modified tracked files (no `Snapceipt.xcodeproj` entry), and the commit is created. The foundation is now buildable and testable; Task 2 (DesignSystem) and Task 3 (Model/SwiftData) build on this scaffold — they add their sources under `Snapceipt/` (auto-picked up by the `sources` glob, so no `project.yml` change is needed unless a new top-level resource appears) and register their `@Model` types into `SnapceiptSchema.models`.



---

### Task 2: theme-tokens — `Color(hex:)`, `Palette`, `Radius`, shadow modifiers + `AccentPalette`/environment

Builds the static design-system foundation: the hex `Color` initializer, the `Palette` color tokens, the `Radius` enum, the `cardShadow()`/`popShadow()` modifiers (matching `sh-card`/`sh-pop`), and `AccentPalette` + its SwiftUI `\.accent` environment key (default = personal terracotta `#E8602C / #FDEBE0 / #C2461A`, plus a `business` teal preset and an `init(hexes:)` builder for per-profile palettes). All values are verbatim from `extracted/screens.md` line 100 (color tokens + `--sh-card`/`--sh-pop`) and the AP_ACCENTS list (line 651: `[#E8602C,#FDEBE0,#C2461A]` = personal, `[#0E7C72,#DCF0ED,#0A5950]` = business). TDD the two pure-logic pieces (hex decode RGBA, default accent base) with Swift Testing; the shadow modifiers + `Palette` get a build-verify.

**Files**
- Create: `Snapceipt/DesignSystem/Theme.swift`
- Create: `Snapceipt/DesignSystem/AccentTheme.swift`
- Create: `SnapceiptTests/ThemeTests.swift`
- Modify: `project.yml` (only if Task 1's globbed sources don't already pick up `Snapceipt/**` — verify; no edit expected)

> Depends on Task 1 (scaffold) having created `project.yml`, the `Snapceipt` app target, and the `SnapceiptTests` target. This task assumes `xcodegen generate` already produced `Snapceipt.xcodeproj` and that target sources are globbed from `Snapceipt/**` + `SnapceiptTests/**`. Do NOT redefine `Font.display`/`Font.ui`/`.numeric()` (owned by the Fonts task) — those are referenced by other tasks, not here.

---

- [ ] **Step 1: Write the failing test for `Color(hex:)` RGBA + the default accent base**

Create `SnapceiptTests/ThemeTests.swift`. The tests assert that `Color(hex: 0xE8602C)` decodes to the expected 0–1 RGBA components (R 232/255, G 96/255, B 44/255, A 1.0) by round-tripping through `UIColor` (the supported way to read components from a SwiftUI `Color` on iOS 17), and that `AccentPalette.personal.base` equals `Color(hex: 0xE8602C)` (terracotta). Use a small tolerance for the float compare.

```swift
import Testing
import SwiftUI
import UIKit
@testable import Snapceipt

@Suite("Theme")
struct ThemeTests {

    /// Reads 0...1 RGBA components from a SwiftUI Color via UIColor (iOS 17 supported path).
    private func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    @Test("Color(hex:) decodes RGB channels and opaque alpha")
    func hexDecodesTerracotta() {
        let c = rgba(Color(hex: 0xE8602C))
        #expect(abs(c.r - 232.0 / 255.0) < 0.005)
        #expect(abs(c.g - 96.0 / 255.0) < 0.005)
        #expect(abs(c.b - 44.0 / 255.0) < 0.005)
        #expect(abs(c.a - 1.0) < 0.001)
    }

    @Test("Color(hex:) decodes pure black and pure white")
    func hexDecodesBlackAndWhite() {
        let black = rgba(Color(hex: 0x000000))
        #expect(black.r < 0.005 && black.g < 0.005 && black.b < 0.005)
        #expect(abs(black.a - 1.0) < 0.001)

        let white = rgba(Color(hex: 0xFFFFFF))
        #expect(white.r > 0.995 && white.g > 0.995 && white.b > 0.995)
    }

    @Test("Default accent base is terracotta #E8602C")
    func defaultAccentBaseIsTerracotta() {
        let base = rgba(AccentPalette.personal.base)
        let expected = rgba(Color(hex: 0xE8602C))
        #expect(abs(base.r - expected.r) < 0.005)
        #expect(abs(base.g - expected.g) < 0.005)
        #expect(abs(base.b - expected.b) < 0.005)
    }

    @Test("AccentPalette(hexes:) maps base/soft/deep in order")
    func accentFromHexesMapsInOrder() {
        // Business teal AP_ACCENTS[4]: base #0E7C72, soft #DCF0ED, deep #0A5950
        let teal = AccentPalette(hexes: [0x0E7C72, 0xDCF0ED, 0x0A5950])
        #expect(teal != nil)
        let base = rgba(teal!.base)
        let expected = rgba(Color(hex: 0x0E7C72))
        #expect(abs(base.r - expected.r) < 0.005)
        #expect(abs(base.g - expected.g) < 0.005)
        #expect(abs(base.b - expected.b) < 0.005)
        // Wrong-length input is rejected.
        #expect(AccentPalette(hexes: [0x0E7C72, 0xDCF0ED]) == nil)
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL (symbols undefined)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Theme
```

Expected: **FAIL** — compilation error (`Color(hex:)`, `AccentPalette`, `AccentPalette.personal` are not yet defined), so the `Theme` suite does not build/run.

- [ ] **Step 3: Implement `DesignSystem/Theme.swift` (`Color(hex:)`, `Palette`, `Radius`, shadow modifiers)**

`Color(hex:)` takes a `UInt32` RGB value (no alpha byte) and produces an opaque sRGB color. `Palette` holds every static token from `screens.md`. `Radius` mirrors `r-card 22 / r-inner 16 / r-chip 12`. The two shadow modifiers reproduce the two-layer CSS shadows exactly: `sh-card = 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14)` and `sh-pop = 0 8px 24px -8px rgba(33,28,24,.22), 0 2px 6px rgba(33,28,24,.08)`. CSS `box-shadow: Xpx Ypx Bpx Spx color` maps to SwiftUI `.shadow(color:radius:x:y:)` with `radius = blur/2` and (since spread isn't expressible) the negative spread on `sh-card`'s second layer is approximated by halving its blur — documented inline. The shadow base color is `ink` (`#211C18` = rgb 33,28,24) at the given opacities.

```swift
import SwiftUI

// MARK: - Hex Color

extension Color {
    /// Builds an opaque sRGB color from a 24-bit RGB hex value, e.g. `Color(hex: 0xE8602C)`.
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

// MARK: - Palette (design tokens, screens.md line 100)

enum Palette {
    static let cream = Color(hex: 0xFBF6F0)
    static let paper = Color(hex: 0xFFFFFF)
    static let paper2 = Color(hex: 0xF6EEE4)
    static let ink = Color(hex: 0x211C18)
    static let ink2 = Color(hex: 0x6B6258)
    static let ink3 = Color(hex: 0xA99F93)
    static let line = Color(hex: 0xECE3D8)
    static let line2 = Color(hex: 0xF3EBE1)
    static let income = Color(hex: 0x1F9D6B)
    static let incomeSoft = Color(hex: 0xDEF3E9)
    static let alert = Color(hex: 0xD6452B)
}

// MARK: - Radii

enum Radius {
    static let card: CGFloat = 22
    static let inner: CGFloat = 16
    static let chip: CGFloat = 12
}

// MARK: - Shadows

/// `sh-card`: 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14).
/// SwiftUI radius = CSS blur / 2; the -16px spread on the second layer is approximated
/// by halving its blur (SwiftUI has no spread parameter).
private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Palette.ink.opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: Palette.ink.opacity(0.14), radius: 5, x: 0, y: 10)
    }
}

/// `sh-pop`: 0 8px 24px -8px rgba(33,28,24,.22), 0 2px 6px rgba(33,28,24,.08).
private struct PopShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: Palette.ink.opacity(0.22), radius: 8, x: 0, y: 8)
            .shadow(color: Palette.ink.opacity(0.08), radius: 3, x: 0, y: 2)
    }
}

extension View {
    /// Applies the `sh-card` two-layer shadow.
    func cardShadow() -> some View { modifier(CardShadow()) }
    /// Applies the `sh-pop` two-layer shadow.
    func popShadow() -> some View { modifier(PopShadow()) }
}
```

- [ ] **Step 4: Implement `DesignSystem/AccentTheme.swift` (`AccentPalette` + `\.accent` environment)**

`AccentPalette` carries `base/soft/deep`. `personal` is the default terracotta (AP_ACCENTS[0]); `business` is the teal preset (AP_ACCENTS[4]). `init(hexes:)` is a failable initializer that builds an `AccentPalette` from a `[base, soft, deep]` hex array (rejecting wrong-length input) — this is how `ProfilesStore` derives the active accent from a profile's stored palette. `Equatable` lets tests compare. The `\.accent` environment key defaults to `.personal`.

```swift
import SwiftUI

/// Accent triad driving every `--accent / --accent-soft / --accent-deep` surface.
/// The active profile supplies this at runtime; default = personal terracotta.
struct AccentPalette: Equatable {
    let base: Color
    let soft: Color
    let deep: Color

    /// Personal terracotta — AP_ACCENTS[0]: #E8602C / #FDEBE0 / #C2461A.
    static let personal = AccentPalette(
        base: Color(hex: 0xE8602C),
        soft: Color(hex: 0xFDEBE0),
        deep: Color(hex: 0xC2461A)
    )

    /// Business teal — AP_ACCENTS[4]: #0E7C72 / #DCF0ED / #0A5950.
    static let business = AccentPalette(
        base: Color(hex: 0x0E7C72),
        soft: Color(hex: 0xDCF0ED),
        deep: Color(hex: 0x0A5950)
    )

    /// Builds an accent from a stored profile palette `[base, soft, deep]` (24-bit RGB hexes).
    /// Returns `nil` for any array that is not exactly three elements.
    init?(hexes: [UInt32]) {
        guard hexes.count == 3 else { return nil }
        self.base = Color(hex: hexes[0])
        self.soft = Color(hex: hexes[1])
        self.deep = Color(hex: hexes[2])
    }

    /// Memberwise initializer (the failable one above shadows the synthesized init).
    init(base: Color, soft: Color, deep: Color) {
        self.base = base
        self.soft = soft
        self.deep = deep
    }
}

// MARK: - Environment

private struct AccentEnvironmentKey: EnvironmentKey {
    static let defaultValue: AccentPalette = .personal
}

extension EnvironmentValues {
    /// `@Environment(\.accent) var accent` — the active profile's accent triad.
    var accent: AccentPalette {
        get { self[AccentEnvironmentKey.self] }
        set { self[AccentEnvironmentKey.self] = newValue }
    }
}
```

- [ ] **Step 5: Run the test — expect PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Theme
```

Expected: **PASS** — all four `Theme` tests green (hex RGBA decode for terracotta/black/white, default accent base = terracotta, `init(hexes:)` ordering + nil rejection).

- [ ] **Step 6: Build the app target to verify the shadow modifiers + `Palette` compile in a view context**

Add a `#Preview` exercising the tokens at the bottom of `DesignSystem/Theme.swift` so the modifiers are type-checked against real SwiftUI views.

```swift
#Preview("Theme tokens") {
    VStack(spacing: 16) {
        RoundedRectangle(cornerRadius: Radius.card)
            .fill(Palette.paper)
            .frame(width: 220, height: 96)
            .overlay(Text("cardShadow()").foregroundStyle(Palette.ink))
            .cardShadow()
        RoundedRectangle(cornerRadius: Radius.inner)
            .fill(Palette.cream)
            .frame(width: 220, height: 72)
            .overlay(Text("popShadow()").foregroundStyle(Palette.ink2))
            .popShadow()
        HStack(spacing: 10) {
            Circle().fill(AccentPalette.personal.base).frame(width: 28, height: 28)
            Circle().fill(AccentPalette.personal.soft).frame(width: 28, height: 28)
            Circle().fill(AccentPalette.business.base).frame(width: 28, height: 28)
        }
    }
    .padding(40)
    .background(Palette.cream)
}
```

Then build:

```bash
xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

Expected: **BUILD SUCCEEDED** — `Theme.swift`, `AccentTheme.swift`, and the `#Preview` compile; `cardShadow()`/`popShadow()` apply cleanly to `RoundedRectangle`.

- [ ] **Step 7: Commit**

```bash
git -C /Users/yangqi/Documents/github/Snapceipt add Snapceipt/DesignSystem/Theme.swift Snapceipt/DesignSystem/AccentTheme.swift SnapceiptTests/ThemeTests.swift
git -C /Users/yangqi/Documents/github/Snapceipt commit -m "feat(ios): add design-system color/radius/shadow tokens + accent palette

Color(hex:) sRGB initializer, Palette tokens, Radius enum, cardShadow()/
popShadow() modifiers matching sh-card/sh-pop, and AccentPalette with the
\\.accent environment key (default personal terracotta, business teal preset,
init(hexes:) builder for per-profile palettes). TDD-covered: hex RGBA decode
and default accent base.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

Expected: commit created on the working branch (Task 1 already branched off the default branch).


---

### Task 3: fonts — `Font.display` / `Font.ui` helpers, `.numeric()` modifier, bundled-family registration

Brings up the typography layer the whole design system uses: the two bundled families (Schibsted Grotesk for numbers/headings, Hanken Grotesk for UI) exposed as `Font.display(_:_:)` / `Font.ui(_:_:)`, and a `.numeric(_:_:)` view modifier (display face + monospaced digits + tight tracking) for every monetary/figure value. The nine `.ttf` files were wired into `Info.plist` `UIAppFonts` by Task 1; this task adds the Swift API + a data test for the registered family names.

**Files**
- Create: `Snapceipt/DesignSystem/Fonts.swift`
- Test: `SnapceiptTests/FontsTests.swift`

---

- [ ] **Step 1: Add the static TTFs (one-time asset step)**

Download the **static** TTF exports from Google Fonts and drop them in `Snapceipt/Resources/Fonts/` with the exact filenames listed in `Info.plist` (Task 1, Step 2): `SchibstedGrotesk-Regular/Medium/SemiBold/Bold/ExtraBold.ttf` and `HankenGrotesk-Regular/Medium/SemiBold/Bold.ttf`. Run:

```bash
cd /Users/yangqi/Documents/github/Snapceipt
ls -1 Snapceipt/Resources/Fonts/*.ttf | wc -l
```

Expected: prints `9`. (If you only have variable-font TTFs, that is fine too — register them under the same filenames; the family names below still resolve. The build will not embed the fonts until these files exist.)

- [ ] **Step 2: Write the failing test `SnapceiptTests/FontsTests.swift`**

The family-name constants are the load-bearing contract (`Font.custom` looks the family up by these exact strings). Test them as data, plus assert the registered families are actually present in the running test host.

```swift
import Testing
import UIKit
@testable import Snapceipt

struct FontsTests {
    @Test func familyNameConstantsAreExact() {
        #expect(Typeface.display == "Schibsted Grotesk")
        #expect(Typeface.ui == "Hanken Grotesk")
    }

    @Test func bundledFamiliesAreRegistered() {
        // UIFont sees app-bundled fonts (UIAppFonts) at runtime in the test host.
        let families = Set(UIFont.familyNames)
        #expect(families.contains(Typeface.display))
        #expect(families.contains(Typeface.ui))
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/FontsTests`
Expected: FAIL — `Typeface` is undefined (compile error), so the suite does not build yet.

- [ ] **Step 4: Implement `Snapceipt/DesignSystem/Fonts.swift`**

```swift
import SwiftUI

/// Bundled font family names. These exact strings are what `Font.custom` looks up;
/// they must match the families registered via Info.plist `UIAppFonts` (Task 1).
enum Typeface {
    static let display = "Schibsted Grotesk"   // numbers, headings, initials
    static let ui = "Hanken Grotesk"           // all other UI text
}

extension Font {
    /// Schibsted Grotesk at a point size + weight (default bold, matching the design).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom(Typeface.display, size: size).weight(weight)
    }

    /// Hanken Grotesk at a point size + weight (default regular).
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.ui, size: size).weight(weight)
    }
}

/// Applies the design's numeric treatment: display face, monospaced (tabular) digits,
/// and ~-0.01em tracking — used for every amount/figure so columns align.
private struct NumericText: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content
            .font(.display(size, weight).monospacedDigit())
            .tracking(-0.01 * size)   // -0.01em, expressed in points relative to size
    }
}

extension View {
    /// Render numeric text in the display face with tabular digits + tight tracking.
    func numeric(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(NumericText(size: size, weight: weight))
    }
}

#if DEBUG
#Preview("Typography") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Snapceipt").font(.display(28, .bold))
        Text("Snap it. Sort it. Sorted.").font(.ui(15, .medium))
        Text("−$42.50").numeric(34)
        Text("$4,200").numeric(18, .semibold)
    }
    .padding()
    .background(Color.cream)   // from Theme.swift (Task 2)
}
#endif
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/FontsTests`
Expected: PASS — both tests green (constants exact, families registered). If `bundledFamiliesAreRegistered` fails, the TTF filenames in `Snapceipt/Resources/Fonts/` do not match `Info.plist` `UIAppFonts`; reconcile the names.

- [ ] **Step 6: Commit**

```bash
cd /Users/yangqi/Documents/github/Snapceipt
git add Snapceipt/DesignSystem/Fonts.swift SnapceiptTests/FontsTests.swift Snapceipt/Resources/Fonts
git commit -m "feat(ios): typography — Font.display/ui helpers + .numeric() modifier

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```


---

### Task 4: money-format-cats — Money (Int cents + Decimal bridge), Formatters (fmt/fmtK/fmtDate), Categories (CategoryKey + CategoryMeta + CATS)

Ground truth: `theme.jsx` lines 5-20 (`fmt`/`fmtK`/`fmtDate`) and 91-100 (`CATS`); spec §6 (design tokens), §7 (money = INTEGER cents, dates `'YYYY-MM-DD'`), §13/§15 (en-AU, U+2212 minus, AUD); `extracted/screens.md` (category tints, `fmt(amount, sign:true)` shows leading `+`/`−`, budgets/summary use `cents:false`).

This task owns the pure-logic money + category layer. It **consumes** `Palette` and `Color.init(hex:)` from the Theme task (already defined there — do NOT redefine `Color` extension or `Palette` here). The `fmt`/`fmtK` thresholds are evaluated on the **dollar** value derived from Int cents, exactly mirroring the JS (`a >= 10000` dollars → integer `k`). Negatives use Unicode MINUS SIGN U+2212 (`\u{2212}`), never an ASCII hyphen. Formatting uses `NumberFormatter` decimal style with `Locale(identifier: "en_AU")` (comma grouping) + a literal `"$"` prefix, matching `toLocaleString('en-AU', …)` + literal `'$'` — NOT a currency formatter (which would emit `A$`).

#### Files
- **Create:** `Snapceipt/Model/Money.swift` (defines `Money`)
- **Create:** `Snapceipt/Model/Formatters.swift` (defines `fmt`, `fmtK`, `DateStyle`, `fmtDate`)
- **Create:** `Snapceipt/Model/Categories.swift` (defines `CategoryKey`, `CategoryMeta`, `CATS`)
- **Modify:** `project.yml` (no change needed if `Snapceipt/**` glob already includes `Model/` — verify only)
- **Test:** `SnapceiptTests/FormattersTests.swift`
- **Test:** `SnapceiptTests/CategoriesTests.swift`
- **Test:** `SnapceiptTests/MoneyTests.swift`

---

- [ ] **Step 1: Write the failing Formatters test (TDD red).**

Create `SnapceiptTests/FormattersTests.swift`. Uses Swift Testing (`import Testing`, `@Test`, `#expect`). Pins the exact expectations from the task brief, including the literal U+2212 minus in the negative case.

```swift
import Testing
@testable import Snapceipt

@Suite("Formatters")
struct FormattersTests {

    // fmt(-4250) == "−$42.50"  (leading character is U+2212 MINUS SIGN, not hyphen)
    @Test func negativeUsesUnicodeMinusAndCents() {
        let result = fmt(-4250)
        #expect(result == "\u{2212}$42.50")
        // Guard against an accidental ASCII hyphen regression.
        #expect(result.first == "\u{2212}")
        #expect(!result.contains("-"))
    }

    // fmt(420000, showCents: false) == "$4,200"  (grouped thousands, no decimals)
    @Test func showCentsFalseDropsDecimalsAndGroups() {
        #expect(fmt(420000, showCents: false) == "$4,200")
    }

    // fmt(85000, sign: true) == "+$850.00"  (explicit + for positives when sign)
    @Test func signTruePrefixesPlusForPositive() {
        #expect(fmt(85000, sign: true) == "+$850.00")
    }

    // Default positive has no sign prefix.
    @Test func positiveNoSignByDefault() {
        #expect(fmt(85000) == "$850.00")
    }

    // Zero renders without a sign even when sign:true.
    @Test func zeroHasNoSign() {
        #expect(fmt(0, sign: true) == "$0.00")
        #expect(fmt(0) == "$0.00")
    }

    // fmtK(120000 cents == $1200) == "$1.2k"  (one decimal, under $10k)
    @Test func fmtKUnderTenThousandKeepsOneDecimal() {
        #expect(fmtK(120000) == "$1.2k")
    }

    // fmtK(1200000 cents == $12000) == "$12k"  (integer k at >= $10000)
    @Test func fmtKAtTenThousandDropsDecimal() {
        #expect(fmtK(1200000) == "$12k")
    }

    // fmtK under $1000 falls back to a plain integer dollar string.
    @Test func fmtKUnderThousandNoK() {
        #expect(fmtK(50000) == "$500")
    }

    // fmtDate("2026-05-28") == "28 May"  (en-AU day + short month, no leading zero)
    @Test func fmtDateDayShortMonth() {
        #expect(fmtDate("2026-05-28") == "28 May")
    }

    // fmtDate long style includes the year.
    @Test func fmtDateLongStyleIncludesYear() {
        #expect(fmtDate("2026-05-28", style: .long) == "28 May 2026")
    }
}
```

- [ ] **Step 2: Run the Formatters test — expect FAIL (does not compile / symbols undefined).**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Formatters
```

Expected: **FAIL** — compilation error, `cannot find 'fmt' in scope` / `cannot find 'fmtK'` / `cannot find 'fmtDate'` (the symbols don't exist yet).

- [ ] **Step 3: Implement `Money` (Int cents + Decimal bridge).**

Create `Snapceipt/Model/Money.swift`. `Money` is a value type wrapping `cents: Int` (the canonical storage unit everywhere in the app), with a `Decimal` bridge for the manual-entry keypad and display math. Rounding uses banker's-free `.plain` half-up to mirror currency expectations.

```swift
import Foundation

/// Canonical money value: integer **cents** (AUD), with a `Decimal` bridge.
/// All persisted amounts in Snapceipt are stored as `Int` cents; `Money`
/// is the in-memory helper for converting to/from `Decimal` dollars
/// (keypad input, GST math) without ever using binary floating point.
struct Money: Equatable, Hashable, Codable, Sendable {
    /// Amount in whole cents. Negative = expense, positive = income.
    var cents: Int

    init(cents: Int) {
        self.cents = cents
    }

    /// The amount as a `Decimal` number of dollars (e.g. `4250` cents -> `42.50`).
    var decimal: Decimal {
        Decimal(cents) / 100
    }

    /// Build from a `Decimal` dollar amount, rounding to the nearest cent.
    static func fromDecimal(_ dollars: Decimal) -> Money {
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Money(cents: (rounded as NSDecimalNumber).intValue)
    }

    /// Build from an integer dollar amount (convenience for seeds/tests).
    static func fromDollars(_ dollars: Int) -> Money {
        Money(cents: dollars * 100)
    }

    static let zero = Money(cents: 0)
}
```

- [ ] **Step 4: Implement `Formatters` (`fmt`, `fmtK`, `DateStyle`, `fmtDate`).**

Create `Snapceipt/Model/Formatters.swift`. Mirrors `theme.jsx` exactly: `fmt` takes Int **cents**, derives a `Decimal` dollar value, formats with a cached en-AU decimal `NumberFormatter`, prefixes the U+2212 minus for negatives and `+` for positives only when `sign` is set, then the literal `"$"`. `fmtK` derives dollars from cents and applies the `>= $10000 ? 0 : 1` decimal rule. `fmtDate` parses `'YYYY-MM-DD'` and emits a localized `d MMM` (or `d MMM yyyy`) string.

```swift
import Foundation

private let auLocale = Locale(identifier: "en_AU")

/// Decimal (NOT currency) formatter so we control the literal "$" prefix
/// and avoid the "A$" symbol a currency formatter would emit — matching
/// theme.jsx's `Number.toLocaleString('en-AU', …)` + literal '$'.
private func makeMoneyFormatter(showCents: Bool) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = auLocale
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = showCents ? 2 : 0
    f.maximumFractionDigits = showCents ? 2 : 0
    f.roundingMode = .halfUp
    return f
}

private let moneyWithCents = makeMoneyFormatter(showCents: true)
private let moneyNoCents = makeMoneyFormatter(showCents: false)

/// Format Int **cents** as AUD: "$42.50", "−$42.50" (U+2212), "+$850.00".
/// - sign: when true, prefix "+" for positive (non-zero) amounts.
/// - showCents: when false, drop the decimals (budgets/summary use this).
func fmt(_ cents: Int, sign: Bool = false, showCents: Bool = true) -> String {
    let absCents = abs(cents)
    let dollars = Decimal(absCents) / 100
    let formatter = showCents ? moneyWithCents : moneyNoCents
    let body = formatter.string(from: dollars as NSDecimalNumber) ?? (showCents ? "0.00" : "0")
    let prefix: String
    if cents < 0 {
        prefix = "\u{2212}" // MINUS SIGN, not hyphen-minus
    } else if sign && cents > 0 {
        prefix = "+"
    } else {
        prefix = ""
    }
    return prefix + "$" + body
}

/// Compact AUD: "$500", "$1.2k", "$12k". Threshold mirrors theme.jsx:
/// dollars >= 10000 -> integer "k"; >= 1000 -> one-decimal "k"; else plain "$N".
func fmtK(_ cents: Int) -> String {
    let absCents = abs(cents)
    let dollars = Double(absCents) / 100.0
    if dollars >= 1000 {
        let k = dollars / 1000.0
        let digits = dollars >= 10000 ? 0 : 1
        return "$" + String(format: "%.\(digits)f", k) + "k"
    }
    return "$" + String(format: "%.0f", dollars)
}

/// Date display style for `fmtDate`.
enum DateStyle {
    case short // "28 May"
    case long  // "28 May 2026"
}

private let isoDateParser: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func makeDateFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = auLocale
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = format
    return f
}

private let dateShort = makeDateFormatter("d MMM")
private let dateLong = makeDateFormatter("d MMM yyyy")

/// Format a `'YYYY-MM-DD'` string as en-AU "28 May" (short) or "28 May 2026" (long).
/// Returns the raw input unchanged if it cannot be parsed.
func fmtDate(_ iso: String, style: DateStyle = .short) -> String {
    guard let date = isoDateParser.date(from: iso) else { return iso }
    switch style {
    case .short: return dateShort.string(from: date)
    case .long: return dateLong.string(from: date)
    }
}
```

- [ ] **Step 5: Run the Formatters test — expect PASS.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Formatters
```

Expected: **PASS** — all 10 Formatters tests green (`negativeUsesUnicodeMinusAndCents`, `showCentsFalseDropsDecimalsAndGroups`, `signTruePrefixesPlusForPositive`, `positiveNoSignByDefault`, `zeroHasNoSign`, `fmtKUnderTenThousandKeepsOneDecimal`, `fmtKAtTenThousandDropsDecimal`, `fmtKUnderThousandNoK`, `fmtDateDayShortMonth`, `fmtDateLongStyleIncludesYear`).

- [ ] **Step 6: Write the failing Categories test (TDD red).**

Create `SnapceiptTests/CategoriesTests.swift`. Asserts the 9 keys exist, the count is exactly 9, `meals` metadata matches `theme.jsx` (label "Meals & Coffee", icon "cup", tint `#E8602C`, soft `#FBEADF`), and a spot-check on `software` tint `#7B5BD6`. Tint/soft are compared via the canonical `Color(hex:)` initializer (owned by the Theme task) so we verify the exact hex was used.

```swift
import Testing
import SwiftUI
@testable import Snapceipt

@Suite("Categories")
struct CategoriesTests {

    @Test func exactlyNineCategories() {
        #expect(CATS.count == 9)
    }

    @Test func allRawValuesPresent() {
        let keys = Set(CategoryKey.allCases.map(\.rawValue))
        #expect(keys == ["meals", "groceries", "fuel", "software",
                         "office", "home", "health", "travel", "income"])
    }

    @Test func everyKeyHasMeta() {
        for key in CategoryKey.allCases {
            #expect(CATS[key] != nil)
        }
    }

    @Test func mealsMetaMatchesThemeJSX() {
        let meals = CATS[.meals]
        #expect(meals?.label == "Meals & Coffee")
        #expect(meals?.iconName == "cup")
        #expect(meals?.tint == Color(hex: 0xE8602C))
        #expect(meals?.soft == Color(hex: 0xFBEADF))
    }

    @Test func softwareTintMatches() {
        #expect(CATS[.software]?.tint == Color(hex: 0x7B5BD6))
        #expect(CATS[.software]?.iconName == "film")
    }

    @Test func incomeUsesArrowDownIcon() {
        #expect(CATS[.income]?.iconName == "arrowDown")
        #expect(CATS[.income]?.tint == Color(hex: 0x1F9D6B))
    }
}
```

- [ ] **Step 7: Run the Categories test — expect FAIL (symbols undefined).**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Categories
```

Expected: **FAIL** — `cannot find 'CATS' in scope` / `cannot find type 'CategoryKey' in scope` (not implemented yet).

- [ ] **Step 8: Implement `Categories` (`CategoryKey`, `CategoryMeta`, `CATS`).**

Create `Snapceipt/Model/Categories.swift`. Mirrors `theme.jsx` `CATS` (lines 91-100) one-to-one. `CategoryKey` is the 9-value `String` raw enum (matching the extraction contract, no `other`). `CategoryMeta` carries `label`, `iconName`, and `tint`/`soft` as `Color` built via the canonical `Color(hex:)` initializer (owned by the Theme task).

```swift
import SwiftUI

/// The 9 canonical category keys (matches theme.jsx CATS + the /extract
/// contract; there is no `other` — the extractor always picks one of these).
enum CategoryKey: String, CaseIterable, Codable, Sendable {
    case meals
    case groceries
    case fuel
    case software
    case office
    case home
    case health
    case travel
    case income
}

/// Display metadata for a category: human label, line-icon name (theme.jsx
/// ICONS key), and the tint/soft color pair for IconCircle + chips.
struct CategoryMeta: Equatable {
    let label: String
    let iconName: String
    let tint: Color
    let soft: Color
}

/// Category metadata table, mirroring theme.jsx `CATS` exactly.
let CATS: [CategoryKey: CategoryMeta] = [
    .meals:     CategoryMeta(label: "Meals & Coffee",   iconName: "cup",       tint: Color(hex: 0xE8602C), soft: Color(hex: 0xFBEADF)),
    .groceries: CategoryMeta(label: "Groceries",        iconName: "cart",      tint: Color(hex: 0xC99A22), soft: Color(hex: 0xF6EECE)),
    .fuel:      CategoryMeta(label: "Fuel & Transport", iconName: "fuel",      tint: Color(hex: 0x2F6FB0), soft: Color(hex: 0xE2ECF6)),
    .software:  CategoryMeta(label: "Software & Subs",  iconName: "film",      tint: Color(hex: 0x7B5BD6), soft: Color(hex: 0xEBE5F8)),
    .office:    CategoryMeta(label: "Office & Supplies",iconName: "building",  tint: Color(hex: 0x0E7C72), soft: Color(hex: 0xDCF0ED)),
    .home:      CategoryMeta(label: "Home & Utilities", iconName: "home",      tint: Color(hex: 0xB0568F), soft: Color(hex: 0xF4E4EF)),
    .health:    CategoryMeta(label: "Health",           iconName: "heart",     tint: Color(hex: 0xD6452B), soft: Color(hex: 0xF8E2DD)),
    .travel:    CategoryMeta(label: "Travel & Stays",   iconName: "pin",       tint: Color(hex: 0x1F9D6B), soft: Color(hex: 0xDEF3E9)),
    .income:    CategoryMeta(label: "Income",           iconName: "arrowDown", tint: Color(hex: 0x1F9D6B), soft: Color(hex: 0xDEF3E9)),
]
```

- [ ] **Step 9: Run the Categories test — expect PASS.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Categories
```

Expected: **PASS** — all 6 Categories tests green.

- [ ] **Step 10: Write the failing Money test (TDD red).**

Create `SnapceiptTests/MoneyTests.swift`. Verifies the cents/Decimal bridge round-trips exactly (no float drift) and that `fromDecimal` rounds to the nearest cent.

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("Money")
struct MoneyTests {

    @Test func centsToDecimal() {
        #expect(Money(cents: 4250).decimal == Decimal(string: "42.50"))
        #expect(Money(cents: -4250).decimal == Decimal(string: "-42.50"))
        #expect(Money.zero.decimal == Decimal(0))
    }

    @Test func fromDecimalExact() {
        #expect(Money.fromDecimal(Decimal(string: "42.50")!).cents == 4250)
        #expect(Money.fromDecimal(Decimal(string: "850")!).cents == 85000)
    }

    @Test func fromDecimalRoundsToNearestCent() {
        // 42.505 -> 42.51 (half up), 42.504 -> 42.50
        #expect(Money.fromDecimal(Decimal(string: "42.505")!).cents == 4251)
        #expect(Money.fromDecimal(Decimal(string: "42.504")!).cents == 4250)
    }

    @Test func fromDollars() {
        #expect(Money.fromDollars(850).cents == 85000)
        #expect(Money.fromDollars(0) == Money.zero)
    }

    @Test func roundTripThroughDecimal() {
        for c in [0, 1, 99, 4250, -4250, 99_999_99] {
            #expect(Money.fromDecimal(Money(cents: c).decimal).cents == c)
        }
    }
}
```

- [ ] **Step 11: Run the Money test — expect PASS (implementation from Step 3 satisfies it).**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Money
```

Expected: **PASS** — all 5 Money tests green. (`Money` was implemented in Step 3 to support `Formatters`; this step formalizes its TDD coverage.)

- [ ] **Step 12: Run all three suites together to confirm no cross-file breakage.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Formatters -only-testing:SnapceiptTests/Categories -only-testing:SnapceiptTests/Money
```

Expected: **PASS** — 21 tests total (10 Formatters + 6 Categories + 5 Money), 0 failures.

- [ ] **Step 13: Commit.**

```bash
git -C /Users/yangqi/Documents/github/Snapceipt add Snapceipt/Model/Money.swift Snapceipt/Model/Formatters.swift Snapceipt/Model/Categories.swift SnapceiptTests/FormattersTests.swift SnapceiptTests/CategoriesTests.swift SnapceiptTests/MoneyTests.swift
git -C /Users/yangqi/Documents/github/Snapceipt commit -m "feat(ios): add Money cents/Decimal bridge, AUD formatters, and category metadata

Port theme.jsx fmt/fmtK/fmtDate (en-AU, U+2212 minus, literal \$) and the
9-key CATS table to Swift; add Money(Int cents) with a Decimal bridge.
TDD: Formatters, Categories, and Money suites (21 tests).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Notes / cross-task contracts:**
- This task **defines**: `Money` (+ `.cents`, `.decimal`, `.fromDecimal(_:)`, `.fromDollars(_:)`, `.zero`), `fmt(_:sign:showCents:)`, `fmtK(_:)`, `DateStyle`, `fmtDate(_:style:)`, `CategoryKey`, `CategoryMeta`, `CATS`.
- This task **consumes** (must already exist from the Theme task): `Color.init(hex: UInt32)` and `Palette`. If running before the Theme task, that task's `Color(hex:)` initializer is the only hard dependency for `Categories.swift` + `CategoriesTests.swift` to compile — sequence Task 4 after the Theme/Color task, or stub `Color(hex:)` only in that earlier task (never here).
- `project.yml` already globs `Snapceipt/**` and `SnapceiptTests/**` as sources from the scaffold task; new files under `Snapceipt/Model/` are picked up automatically. Only re-run `xcodegen generate` if your glob is file-explicit (it is not in this plan) — otherwise no project.yml edit is required.



---

### Task 5: icons — `Icon` view + `Icons` path table + SVG-path→`Path` parser (with arcs)

Ports the design's 24-grid line-icon set (`theme.jsx` `ICONS`) into SwiftUI: an `Icons` table of the raw SVG `d` strings, a parser that turns any `d` string (commands `M m L l H h V v C c S s Q q T t A a Z z`, including elliptical arcs) into a `SwiftUI.Path` on the 24×24 grid, and an `Icon` view that strokes (default 1.85pt, round caps/joins) or fills it at any size/color. A focused core set is included; the remaining glyphs are added identically from `theme.jsx`.

**Files**
- Create: `Snapceipt/DesignSystem/Icons.swift` (the `d`-string table)
- Create: `Snapceipt/DesignSystem/Icon.swift` (parser + `SVGShape` + `Icon` view)
- Test: `SnapceiptTests/IconParserTests.swift`

---

- [ ] **Step 1: Write the failing test `SnapceiptTests/IconParserTests.swift`**

The parser is the load-bearing logic, so it gets real tests: a simple closed triangle has the expected bounding rect; every core glyph parses to a non-empty path bounded within the 24×24 grid (this exercises lines, `H/V/h/v`, cubics, and arcs without asserting pixels).

```swift
import Testing
import SwiftUI
@testable import Snapceipt

struct IconParserTests {
    @Test func simpleClosedTriangleHasExpectedBounds() {
        let p = Path(svgPath: "M0 0 L10 0 L10 10 Z")
        let b = p.boundingRect
        #expect(abs(b.minX - 0) < 0.001)
        #expect(abs(b.minY - 0) < 0.001)
        #expect(abs(b.maxX - 10) < 0.001)
        #expect(abs(b.maxY - 10) < 0.001)
    }

    @Test func relativeAndVHCommandsAdvance() {
        // M then implicit-lineto, relative l, V, H — must not collapse to a point.
        let p = Path(svgPath: "M3 10.6 12 4l9 6.6M5.5 9.2V19H10")
        #expect(!p.isEmpty)
        #expect(p.boundingRect.width > 1)
        #expect(p.boundingRect.height > 1)
    }

    @Test func everyCoreGlyphParsesWithinGrid() {
        for (name, d) in Icons.paths {
            let p = Path(svgPath: d)
            #expect(!p.isEmpty, "\(name) parsed empty")
            let b = p.boundingRect
            // Allow a small epsilon for stroke geometry; icons live on a 0...24 grid.
            #expect(b.minX >= -0.5 && b.minY >= -0.5, "\(name) out of grid (min)")
            #expect(b.maxX <= 24.5 && b.maxY <= 24.5, "\(name) out of grid (max)")
        }
    }

    @Test func arcCommandProducesCurve() {
        // 'a1 1 0 0 0 1 1' (relative arc) used by home/user/bell/camera etc.
        let p = Path(svgPath: "M5 9a1 1 0 0 0 1 1")
        #expect(!p.isEmpty)
        #expect(p.boundingRect.width > 0.5)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/IconParserTests`
Expected: FAIL — `Path(svgPath:)` and `Icons` are undefined (suite does not compile).

- [ ] **Step 3: Implement `Snapceipt/DesignSystem/Icons.swift` (core glyph table)**

```swift
import Foundation

/// Raw 24×24-grid SVG path data ported verbatim from theme.jsx ICONS.
/// Core set used by the app shell, profiles, and auth flows. The remaining
/// theme.jsx glyphs are added here identically (same `d` strings, no other change).
enum Icons {
    static let paths: [String: String] = [
        "home": "M3 10.6 12 4l9 6.6M5.5 9.2V19a1 1 0 0 0 1 1H10v-5h4v5h3.5a1 1 0 0 0 1-1V9.2",
        "receipt": "M6 3h12v18l-2.2-1.4L13.6 21 12 19.6 10.4 21 8.2 19.6 6 21V3ZM9 8h6M9 12h6M9 16h3",
        "chart": "M4 20V10M10 20V4M16 20v-7M22 20H2",
        "user": "M12 12.6a4.1 4.1 0 1 0 0-8.2 4.1 4.1 0 0 0 0 8.2ZM4.6 20a7.5 7.5 0 0 1 14.8 0",
        "camera": "M3.5 8.5A2 2 0 0 1 5.5 6.5h1.7l1-1.7a1 1 0 0 1 .9-.5h5.8a1 1 0 0 1 .9.5l1 1.7h1.7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5ZM12 17a3.7 3.7 0 1 0 0-7.4 3.7 3.7 0 0 0 0 7.4Z",
        "plus": "M12 5v14M5 12h14",
        "chevR": "M9 6l6 6-6 6",
        "chevD": "M6 9l6 6 6-6",
        "arrowLeft": "M19 12H5M11 6l-6 6 6 6",
        "check": "M5 12.5 10 17.5 19.5 7",
        "close": "M6 6l12 12M18 6 6 18",
        "bell": "M6.5 10a5.5 5.5 0 0 1 11 0c0 5 2 6.5 2 6.5H4.5s2-1.5 2-6.5ZM9.5 19.5a2.6 2.6 0 0 0 5 0",
        "sparkles": "M12 3l1.7 4.6L18.3 9.3 13.7 11 12 15.6 10.3 11 5.7 9.3 10.3 7.6 12 3ZM18.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z",
        "gear": "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4ZM19.4 12c0-.5-.05-1-.13-1.46l1.7-1.32-1.9-3.3-2 .8a7.5 7.5 0 0 0-2.5-1.45L14.2 3h-4.4l-.3 2.27A7.5 7.5 0 0 0 7 6.72l-2-.8-1.9 3.3 1.7 1.32a7.7 7.7 0 0 0 0 2.92l-1.7 1.32 1.9 3.3 2-.8a7.5 7.5 0 0 0 2.5 1.45L9.8 21h4.4l.3-2.27a7.5 7.5 0 0 0 2.5-1.45l2 .8 1.9-3.3-1.7-1.32c.08-.46.13-.96.13-1.46Z",
        "wallet": "M4 7.5A1.5 1.5 0 0 1 5.5 6H18a1 1 0 0 1 1 1v1.5M4 7.5V18a1 1 0 0 0 1 1h13a1 1 0 0 0 1-1v-3.5M4 7.5h14.5M16 11.5h3.5v3H16a1.5 1.5 0 0 1 0-3Z",
        "building": "M5 20V5a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v15M14 20V9h4a1 1 0 0 1 1 1v10M4 20h16M8 8h3M8 12h3M8 16h3",
        "star": "M12 3.5l2.6 5.3 5.9.86-4.25 4.14 1 5.85L12 17.1l-5.25 2.6 1-5.85L3.5 9.66l5.9-.86L12 3.5Z",
    ]
    // ADD THE REMAINING theme.jsx ICONS HERE the same way (arrowUp, arrowDown, arrowRight,
    // car, wfh, search, flash, image, share, tag, calendar, edit, filter, dots, cup, cart,
    // fuel, film, bank, doc, heart, trash, pencil, link, shield, lock, pin, clock, swap,
    // scan, download, info, logout, phone) — copy each `d` string verbatim from theme.jsx.
}
```

- [ ] **Step 4: Implement `Snapceipt/DesignSystem/Icon.swift` (parser + shape + view)**

```swift
import SwiftUI
import CoreGraphics

extension Path {
    /// Build a Path from an SVG `d` string on the source coordinate system
    /// (icons author at a 24×24 grid). Supports M/m L/l H/h V/v C/c S/s Q/q T/t A/a Z/z.
    init(svgPath d: String) {
        self.init()
        var scanner = SVGScanner(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var prevControl: CGPoint? = nil       // for S/T reflection
        var prevCmd: Character = " "
        while let cmd = scanner.nextCommand() {
            let rel = cmd.isLowercase
            switch Character(cmd.lowercased()) {
            case "m":
                var p = scanner.point(); if rel { p = current + p }
                move(to: p); current = p; start = p
                // subsequent coordinate pairs after a moveto are implicit linetos
                while scanner.hasNumber {
                    var q = scanner.point(); if rel { q = current + q }
                    addLine(to: q); current = q
                }
            case "l":
                while scanner.hasNumber {
                    var p = scanner.point(); if rel { p = current + p }
                    addLine(to: p); current = p
                }
            case "h":
                while scanner.hasNumber {
                    let x = scanner.number(); current.x = rel ? current.x + x : x
                    addLine(to: current)
                }
            case "v":
                while scanner.hasNumber {
                    let y = scanner.number(); current.y = rel ? current.y + y : y
                    addLine(to: current)
                }
            case "c":
                while scanner.hasNumber {
                    var c1 = scanner.point(); var c2 = scanner.point(); var p = scanner.point()
                    if rel { c1 = current + c1; c2 = current + c2; p = current + p }
                    addCurve(to: p, control1: c1, control2: c2); prevControl = c2; current = p
                }
            case "s":
                while scanner.hasNumber {
                    var c2 = scanner.point(); var p = scanner.point()
                    if rel { c2 = current + c2; p = current + p }
                    let c1 = (prevCmd == "c" || prevCmd == "s"), reflected = c1 ? current + (current - (prevControl ?? current)) : current
                    addCurve(to: p, control1: reflected, control2: c2); prevControl = c2; current = p
                }
            case "q":
                while scanner.hasNumber {
                    var c = scanner.point(); var p = scanner.point()
                    if rel { c = current + c; p = current + p }
                    addQuadCurve(to: p, control: c); prevControl = c; current = p
                }
            case "t":
                while scanner.hasNumber {
                    var p = scanner.point(); if rel { p = current + p }
                    let useRefl = (prevCmd == "q" || prevCmd == "t")
                    let c = useRefl ? current + (current - (prevControl ?? current)) : current
                    addQuadCurve(to: p, control: c); prevControl = c; current = p
                }
            case "a":
                while scanner.hasNumber {
                    let rx = scanner.number(), ry = scanner.number(), rot = scanner.number()
                    let large = scanner.flag(), sweep = scanner.flag()
                    var p = scanner.point(); if rel { p = current + p }
                    SVGArc.append(to: &self, from: current, to: p, rx: rx, ry: ry,
                                  xAxisRotationDeg: rot, largeArc: large, sweep: sweep)
                    current = p
                }
            case "z":
                closeSubpath(); current = start
            default:
                break
            }
            prevCmd = Character(cmd.lowercased())
            if prevCmd != "c" && prevCmd != "s" && prevCmd != "q" && prevCmd != "t" { prevControl = nil }
        }
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }

/// Tokenizes an SVG path: command letters + SVG floats (handles "0-8.2", ".5.5", flags).
private struct SVGScanner {
    private let s: [Character]; private var i = 0
    init(_ str: String) { s = Array(str) }
    private mutating func skipSep() {
        while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
    }
    mutating func nextCommand() -> Character? {
        skipSep()
        guard i < s.count else { return nil }
        if s[i].isLetter { let c = s[i]; i += 1; return c }
        return nil // a number with no preceding command shouldn't happen at top level
    }
    var hasNumber: Bool {
        var j = i
        while j < s.count, s[j] == " " || s[j] == "," || s[j] == "\n" || s[j] == "\t" { j += 1 }
        guard j < s.count else { return false }
        let c = s[j]; return c == "-" || c == "+" || c == "." || c.isNumber
    }
    mutating func number() -> CGFloat {
        skipSep()
        var str = ""
        var seenDot = false, seenExp = false
        if i < s.count, s[i] == "+" || s[i] == "-" { str.append(s[i]); i += 1 }
        while i < s.count {
            let c = s[i]
            if c.isNumber { str.append(c); i += 1 }
            else if c == "." && !seenDot && !seenExp { seenDot = true; str.append(c); i += 1 }
            else if (c == "e" || c == "E") && !seenExp { seenExp = true; str.append(c); i += 1
                if i < s.count, s[i] == "+" || s[i] == "-" { str.append(s[i]); i += 1 } }
            else { break }
        }
        return CGFloat(Double(str) ?? 0)
    }
    mutating func flag() -> Bool {       // SVG arc flags are a single '0' or '1'
        skipSep()
        guard i < s.count else { return false }
        let c = s[i]; i += 1; return c == "1"
    }
    mutating func point() -> CGPoint { let x = number(); let y = number(); return CGPoint(x: x, y: y) }
}

/// SVG elliptical-arc → cubic Béziers (endpoint→center parameterization, ≤90° segments).
private enum SVGArc {
    static func append(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                       rx rxIn: CGFloat, ry ryIn: CGFloat, xAxisRotationDeg: CGFloat,
                       largeArc: Bool, sweep: Bool) {
        if rxIn == 0 || ryIn == 0 || p0 == p1 { path.addLine(to: p1); return }
        var rx = abs(rxIn), ry = abs(ryIn)
        let phi = xAxisRotationDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy, y1p = -sinP * dx + cosP * dy
        var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s; lambda = 1 }
        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p)
        let den = rx*rx*y1p*y1p + ry*ry*x1p*x1p
        let co = sign * sqrt(den == 0 ? 0 : num / den)
        let cxp = co * (rx * y1p / ry), cyp = co * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux*vx + uy*vy, len = sqrt((ux*ux+uy*uy)*(vx*vx+vy*vy))
            var a = acos(max(-1, min(1, dot / (len == 0 ? 1 : len))))
            if ux*vy - uy*vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp)/rx, (y1p - cyp)/ry)
        var dTheta = angle((x1p - cxp)/rx, (y1p - cyp)/ry, (-x1p - cxp)/rx, (-y1p - cyp)/ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
        let delta = dTheta / CGFloat(segs)
        let t = 4.0/3.0 * tan(delta/4)
        var ang = theta1
        for _ in 0..<segs {
            let cos1 = cos(ang), sin1 = sin(ang), cos2 = cos(ang + delta), sin2 = sin(ang + delta)
            func pt(_ c: CGFloat, _ s: CGFloat) -> CGPoint {
                CGPoint(x: cx + (rx * c * cosP - ry * s * sinP), y: cy + (rx * c * sinP + ry * s * cosP))
            }
            let e1 = pt(cos1, sin1), e2 = pt(cos2, sin2)
            let c1 = CGPoint(x: e1.x - t * (rx * sin1 * cosP + ry * cos1 * sinP),
                             y: e1.y - t * (rx * sin1 * sinP - ry * cos1 * cosP))
            let c2 = CGPoint(x: e2.x + t * (rx * sin2 * cosP + ry * cos2 * sinP),
                             y: e2.y + t * (rx * sin2 * sinP - ry * cos2 * cosP))
            path.addCurve(to: e2, control1: c1, control2: c2)
            ang += delta
        }
    }
}

/// A Shape that renders an icon's `d` string scaled from the 24-grid into its rect.
struct SVGShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        let base = Path(svgPath: d)
        let sx = rect.width / 24, sy = rect.height / 24
        return base.applying(CGAffineTransform(scaleX: sx, y: sy))
    }
}

/// The design's line icon. Strokes by default (round caps/joins, 1.85pt); `filled` fills instead.
struct Icon: View {
    let name: String
    var size: CGFloat = 22
    var color: Color = Palette.ink
    var lineWidth: CGFloat = 1.85
    var filled: Bool = false

    var body: some View {
        let shape = SVGShape(d: Icons.paths[name] ?? "")
        Group {
            if filled {
                shape.fill(color)
            } else {
                shape.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview("Icons") {
    let names = Array(Icons.paths.keys).sorted()
    return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
        ForEach(names, id: \.self) { Icon(name: $0, size: 26, color: Palette.ink) }
    }
    .padding()
    .background(Color.cream)
}
#endif
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/IconParserTests`
Expected: PASS — all four tests green (triangle bounds exact, relative/V/H advance, every core glyph parses bounded within the grid, arc produces a curve).

- [ ] **Step 6: Commit**

```bash
cd /Users/yangqi/Documents/github/Snapceipt
git add Snapceipt/DesignSystem/Icon.swift Snapceipt/DesignSystem/Icons.swift SnapceiptTests/IconParserTests.swift
git commit -m "feat(ios): icon system — SVG-path parser + Icon view + core glyph table

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```


---

### Task 6: primitives-a — `Card`, `IconCircle`, `Chip`, `ProgressBar`, `Segmented`

The first batch of reusable design-system primitives, matching the exact tokens in `extracted/screens.md`. They depend on `Palette`/`Radius`/`cardShadow()`/`AccentPalette` (Task 2), `Icon` (Task 5). To avoid a forward dependency on `Animations.swift` (Task 7), animations here use inline `timingCurve` values.

**Files**
- Create: `Snapceipt/DesignSystem/Primitives/Card.swift`
- Create: `Snapceipt/DesignSystem/Primitives/IconCircle.swift`
- Create: `Snapceipt/DesignSystem/Primitives/Chip.swift`
- Create: `Snapceipt/DesignSystem/Primitives/ProgressBar.swift`
- Create: `Snapceipt/DesignSystem/Primitives/Segmented.swift`
- Test: `SnapceiptTests/SegmentedTests.swift`

---

- [ ] **Step 1: Write the failing test `SnapceiptTests/SegmentedTests.swift`**

`Segmented`'s thumb position is driven by a pure index function — the one piece of real logic in this batch. Test it (the views themselves are verified by build + preview).

```swift
import Testing
@testable import Snapceipt

struct SegmentedTests {
    let opts = [SegmentOption(id: "expense", label: "Expense"),
                SegmentOption(id: "income", label: "Income")]

    @Test func indexOfSelection() {
        #expect(segmentIndex("expense", in: opts) == 0)
        #expect(segmentIndex("income", in: opts) == 1)
    }

    @Test func unknownSelectionFallsBackToZero() {
        #expect(segmentIndex("nope", in: opts) == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SegmentedTests`
Expected: FAIL — `SegmentOption` / `segmentIndex` undefined (suite does not compile).

- [ ] **Step 3: Implement `Card.swift`**

```swift
import SwiftUI

/// Paper card: 22pt radius, 1px line-2 border, sh-card shadow, default 16pt padding.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(padding)
            .background(Palette.paper)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line2, lineWidth: 1)
            )
            .cardShadow()
    }
}

#if DEBUG
#Preview("Card") {
    Card { Text("Net this month").font(.ui(15, .semibold)) }
        .padding().background(Color.cream)
}
#endif
```

- [ ] **Step 4: Implement `IconCircle.swift`**

```swift
import SwiftUI

/// Rounded-square tinted icon tile: soft background, 13pt radius, centered Icon (sw 1.9).
struct IconCircle: View {
    let name: String
    var tint: Color
    var soft: Color
    var size: CGFloat = 42
    var iconSize: CGFloat = 21
    var filled: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(soft)
            .frame(width: size, height: size)
            .overlay(Icon(name: name, size: iconSize, color: tint, lineWidth: 1.9, filled: filled))
    }
}

#if DEBUG
#Preview("IconCircle") {
    HStack(spacing: 12) {
        IconCircle(name: "cup", tint: Color(hex: 0xE8602C), soft: Color(hex: 0xFBEADF))
        IconCircle(name: "cart", tint: Color(hex: 0xC99A22), soft: Color(hex: 0xF6EECE))
    }.padding().background(Color.cream)
}
#endif
```

- [ ] **Step 5: Implement `Chip.swift`**

```swift
import SwiftUI

/// Pill chip toggle. Active = accent fill + white text (+ soft shadow); inactive = paper + ink-2 + line border.
struct Chip: View {
    let title: String
    var isActive: Bool
    var iconName: String? = nil
    var action: () -> Void = {}
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let iconName {
                    Icon(name: iconName, size: 15, color: isActive ? .white : Palette.ink2, lineWidth: 1.85)
                }
                Text(title).font(.ui(13.5, .semibold))
            }
            .padding(.vertical, 8).padding(.horizontal, 14)
            .foregroundStyle(isActive ? .white : Palette.ink2)
            .background(isActive ? accent.base : Palette.paper)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isActive ? accent.base : Palette.line, lineWidth: 1))
            .shadow(color: isActive ? Color.black.opacity(0.18) : .clear, radius: 6, x: 0, y: 4)
            .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.18), value: isActive)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Chip") {
    HStack { Chip(title: "All", isActive: true); Chip(title: "Expenses", isActive: false) }
        .padding().background(Color.cream).environment(\.accent, .personal)
}
#endif
```

- [ ] **Step 6: Implement `ProgressBar.swift`**

```swift
import SwiftUI

/// Rounded progress track (line) + tinted fill; height 8, animates width over .6s.
struct ProgressBar: View {
    var value: Double
    var max: Double = 1
    var tint: Color
    var height: CGFloat = 8
    private var fraction: Double { max <= 0 ? 0 : min(1, Swift.max(0, value / max)) }
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(tint).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: height)
        .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.6), value: fraction)
    }
}

#if DEBUG
#Preview("ProgressBar") {
    ProgressBar(value: 64.85, max: 600, tint: Color(hex: 0xE8602C))
        .frame(width: 240).padding().background(Color.cream)
}
#endif
```

- [ ] **Step 7: Implement `Segmented.swift`**

```swift
import SwiftUI

struct SegmentOption: Identifiable, Equatable {
    let id: String
    let label: String
}

/// Index of the selected option (fallback 0). Pure logic — unit tested.
func segmentIndex(_ selection: String, in options: [SegmentOption]) -> Int {
    options.firstIndex(where: { $0.id == selection }).map { Swift.max(0, $0) } ?? 0
}

/// Animated sliding segmented control: paper-2 track, paper thumb that slides .28s.
struct Segmented: View {
    let options: [SegmentOption]
    @Binding var selection: String

    var body: some View {
        GeometryReader { geo in
            let n = Swift.max(1, options.count)
            let pad: CGFloat = 4
            let thumbW = (geo.size.width - pad * 2) / CGFloat(n)
            let idx = segmentIndex(selection, in: options)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999, style: .continuous).fill(Palette.paper2)
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(Palette.paper)
                    .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 2)
                    .frame(width: thumbW, height: geo.size.height - pad * 2)
                    .offset(x: pad + thumbW * CGFloat(idx), y: 0)
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.28), value: selection)
                HStack(spacing: 0) {
                    ForEach(options) { opt in
                        Button { selection = opt.id } label: {
                            Text(opt.label)
                                .font(.ui(14, .semibold))
                                .foregroundStyle(opt.id == selection ? Palette.ink : Palette.ink3)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, pad)
            }
        }
        .frame(height: 38)
    }
}

#if DEBUG
private struct SegmentedDemo: View {
    @State var sel = "expense"
    var body: some View {
        Segmented(options: [SegmentOption(id: "expense", label: "Expense"),
                            SegmentOption(id: "income", label: "Income")], selection: $sel)
            .frame(width: 260).padding().background(Color.cream)
    }
}
#Preview("Segmented") { SegmentedDemo() }
#endif
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SegmentedTests`
Expected: PASS — both index tests green.

- [ ] **Step 9: Build to verify all five primitives compile + previews render**

Run: `xcodebuild build -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16"`
Expected: BUILD SUCCEEDED. Open `Card.swift`/`Chip.swift`/`Segmented.swift` in Xcode and confirm each `#Preview` renders.

- [ ] **Step 10: Commit**

```bash
cd /Users/yangqi/Documents/github/Snapceipt
git add Snapceipt/DesignSystem/Primitives SnapceiptTests/SegmentedTests.swift
git commit -m "feat(ios): primitives — Card, IconCircle, Chip, ProgressBar, Segmented

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```


---

### Task 7: primitives-b — Donut, BarPair, EmptyArt + Animations

Builds the data-viz primitives (`Donut` arc ring, `BarPair` income/expense bars, `EmptyArt` illustration) and the central `DesignSystem/Animations.swift` easing + named transitions. The Donut and BarPair geometry is extracted into pure, side-effect-free functions (`Donut.layout`, `BarPair.barHeights`) so it is unit-testable with Swift Testing; the SwiftUI views and animation transitions are verified via `#Preview` + a release `xcodebuild build`.

Ground truth (verbatim) from `design-ref/snapceipt/project/app/theme.jsx` (Donut/BarPair/EmptyArt) and `snapceipt.html` (`@keyframes`):
- Donut: `r = (size - thickness)/2`, `C = 2πr`, each segment dash `= max((value/total)*C − 3, 0)` (the 3 is the inter-segment gap in points), offset accumulates, ring starts at −90°, rounded caps, grey `Palette.line` track stroke = `thickness`.
- BarPair: two bars width 11, radius 5, gap 4; column area height = `height − 22` (label row); bar height = `(value/max) * (height − 22)`; income = `Palette.income`, expense = `accent.base`; height animates 0.6s.
- EmptyArt: 132×132 viewBox, accent-soft circle r60 centered at (66,66); white receipt rect 44×64 r6 rotated −6°, stroked accent 2.4; three accent text lines opacity .55; accent badge circle r17 at (92,92) with white plus.
- Easing: all named transitions use `cubic-bezier(.22,.61,.36,1)` → `Animation.timingCurve(0.22, 0.61, 0.36, 1)`. `sc-pop-in` uses the spring overshoot curve `cubic-bezier(.34,1.56,.64,1)`. `sc-check`: stroke-dashoffset 48→0. `sc-ring`: scale .6→1.5, opacity .55→0. `sc-confetti`: translateY 0→220, rotate 0→420°, opacity 1→0.

These types are owned by other tasks and are only consumed here (do NOT redefine): `Palette` + `Radius` (Task 4 `Theme.swift`), `AccentPalette` + `\.accent` environment key (Task 4 `AccentTheme.swift`), `Font.ui`/`Font.display` (Task 5 `Fonts.swift`).

**Files**
- Create: `Snapceipt/DesignSystem/Animations.swift`
- Create: `Snapceipt/DesignSystem/Primitives/Donut.swift`
- Create: `Snapceipt/DesignSystem/Primitives/BarPair.swift`
- Create: `Snapceipt/DesignSystem/Primitives/EmptyArt.swift`
- Test: `SnapceiptTests/DonutMathTests.swift`
- Test: `SnapceiptTests/BarPairMathTests.swift`
- Modify: `project.yml` is unchanged (these paths are already globbed under the `Snapceipt/` source group + `SnapceiptTests/` test group from Task 1); run `xcodegen generate` after creating files so Xcode picks them up.

---

- [ ] **Step 1: Create `Animations.swift` — central `Animation.snap` easing + named transitions/modifiers**

This file defines the shared easing curve and the reusable SwiftUI equivalents of the `sc-*` keyframes. No logic test (pure declarative SwiftUI/animation values); it is exercised by previews and the build verify. `ScCheckShape` is an animatable `Shape` whose `trimEnd` drives the checkmark draw (the SwiftUI analogue of `stroke-dashoffset`).

```swift
import SwiftUI

// MARK: - Central easing

extension Animation {
    /// The app-wide easing curve. Mirrors CSS cubic-bezier(.22,.61,.36,1).
    static let snap = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34)

    /// Same curve with a caller-chosen duration (sc-fade-up .42, Progress .6, Donut .7, etc.).
    static func snap(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.61, 0.36, 1, duration: duration)
    }

    /// sc-pop-in spring overshoot: cubic-bezier(.34,1.56,.64,1), ~.5s.
    static func scPopIn(_ duration: Double = 0.5) -> Animation {
        .timingCurve(0.34, 1.56, 0.64, 1, duration: duration)
    }
}

// MARK: - Named transitions

extension AnyTransition {
    /// sc-fade-up: opacity 0 + translateY(10) -> settle. Used by staggered list/section enters.
    static var scFadeUp: AnyTransition {
        .modifier(
            active: ScOffsetFade(y: 10, opacity: 0),
            identity: ScOffsetFade(y: 0, opacity: 1)
        )
    }

    /// sc-rise: opacity 0 + translateY(14) + scale .98 -> settle. Used by bottom sheets.
    static var scRise: AnyTransition {
        .modifier(
            active: ScRise(y: 14, scale: 0.98, opacity: 0),
            identity: ScRise(y: 0, scale: 1, opacity: 1)
        )
    }
}

private struct ScOffsetFade: ViewModifier {
    let y: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: y)
    }
}

private struct ScRise: ViewModifier {
    let y: CGFloat
    let scale: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.opacity(opacity).scaleEffect(scale).offset(y: y)
    }
}

// MARK: - sc-ring (success halo pulse): scale .6 -> 1.5, opacity .55 -> 0

struct ScRingModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 1.5 : 0.6)
            .opacity(active ? 0 : 0.55)
            .animation(.easeOut(duration: 1.1).delay(0.1), value: active)
    }
}

extension View {
    /// Drive the success-ring halo: flip `active` to true on appear.
    func scRing(active: Bool) -> some View { modifier(ScRingModifier(active: active)) }
}

// MARK: - sc-check: animatable checkmark draw (stroke-dashoffset 48 -> 0)

/// The d-string 'M5 12.5 10 17.5 19.5 7' from theme.jsx ICONS.check, on a 0..24 grid,
/// drawn by trimming from 0..trimEnd so it animates like the CSS stroke-dashoffset draw.
struct ScCheckShape: Shape {
    var trimEnd: CGFloat = 1
    var animatableData: CGFloat {
        get { trimEnd }
        set { trimEnd = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24, sy = rect.height / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var full = Path()
        full.move(to: p(5, 12.5))
        full.addLine(to: p(10, 17.5))
        full.addLine(to: p(19.5, 7))
        return full.trimmedPath(from: 0, to: trimEnd)
    }
}

// MARK: - sc-confetti piece: translateY 0 -> 220, rotate 0 -> 420deg, opacity 1 -> 0

struct ScConfettiPiece: View {
    let color: Color
    let index: Int
    @State private var animate = false
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 8, height: 12)
            .rotationEffect(.degrees(animate ? 420 : 0))
            .offset(y: animate ? 220 : 0)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(
                    .easeIn(duration: 1.0 + Double(index % 5) * 0.18)
                        .delay(Double(index % 4) * 0.06)
                ) { animate = true }
            }
    }
}

#Preview("Animations") {
    VStack(spacing: 28) {
        ScCheckShape()
            .stroke(Color(red: 0.122, green: 0.616, blue: 0.42),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            .frame(width: 50, height: 50)
        Circle()
            .fill(Color(red: 0.122, green: 0.616, blue: 0.42))
            .frame(width: 96, height: 96)
            .overlay(Circle().fill(Color(red: 0.122, green: 0.616, blue: 0.42)).scRing(active: true))
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                ScConfettiPiece(
                    color: [Color.orange, .green, .purple, .yellow, .blue][i % 5],
                    index: i
                )
                .offset(x: CGFloat(-44 + i * 6))
            }
        }
        .frame(height: 120)
    }
    .padding(40)
}
```

- [ ] **Step 2: Build-verify the Animations file compiles**

Run:
```bash
xcodegen generate && xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```
Expected: **PASS** (BUILD SUCCEEDED). `Animations.swift` compiles standalone — it imports only SwiftUI and references no other task's types.

- [ ] **Step 3: Write the failing `DonutMathTests` (TDD red)**

The pure geometry function `Donut.layout(segments:size:thickness:)` does not exist yet, so this test target fails to compile/run. It pins: radius, circumference, total normalisation, the 3pt gap subtraction, accumulating offsets, and the empty-input guard (`total` falls back to 1 so no NaN).

```swift
import Testing
import SwiftUI
@testable import Snapceipt

@Suite("Donut segment math")
struct DonutMathTests {

    @Test("radius and circumference match (size - thickness)/2")
    func radiusCircumference() {
        let layout = Donut.layout(segments: [], size: 160, thickness: 22)
        #expect(layout.radius == (160 - 22) / 2)        // 69
        #expect(abs(layout.circumference - 2 * .pi * 69) < 0.0001)
    }

    @Test("two equal segments split the ring in half, each minus the 3pt gap")
    func equalSegments() {
        let segs = [
            DonutSegment(id: "a", value: 50, tint: .red),
            DonutSegment(id: "b", value: 50, tint: .blue),
        ]
        let layout = Donut.layout(segments: segs, size: 160, thickness: 22)
        let half = layout.circumference / 2
        #expect(layout.arcs.count == 2)
        // dash length = (value/total)*C - 3
        #expect(abs(layout.arcs[0].dashLength - (half - 3)) < 0.0001)
        #expect(abs(layout.arcs[1].dashLength - (half - 3)) < 0.0001)
    }

    @Test("offsets accumulate by un-gapped segment length")
    func accumulatingOffsets() {
        let segs = [
            DonutSegment(id: "a", value: 25, tint: .red),
            DonutSegment(id: "b", value: 75, tint: .blue),
        ]
        let layout = Donut.layout(segments: segs, size: 160, thickness: 22)
        let C = layout.circumference
        #expect(abs(layout.arcs[0].dashOffset - 0) < 0.0001)
        // second arc starts after the first's full (un-gapped) length = 0.25*C
        #expect(abs(layout.arcs[1].dashOffset - (0.25 * C)) < 0.0001)
    }

    @Test("fractions sum to 1 over total")
    func fractionsSumToOne() {
        let segs = [
            DonutSegment(id: "a", value: 10, tint: .red),
            DonutSegment(id: "b", value: 30, tint: .blue),
            DonutSegment(id: "c", value: 60, tint: .green),
        ]
        let layout = Donut.layout(segments: segs, size: 140, thickness: 20)
        let sum = layout.arcs.reduce(0) { $0 + $1.fraction }
        #expect(abs(sum - 1) < 0.0001)
    }

    @Test("empty segments produce no arcs and no NaN")
    func emptyGuard() {
        let layout = Donut.layout(segments: [], size: 140, thickness: 20)
        #expect(layout.arcs.isEmpty)
        #expect(!layout.circumference.isNaN)
    }

    @Test("dash length never goes negative for tiny slices")
    func tinySliceClampsToZero() {
        let segs = [
            DonutSegment(id: "big", value: 1000, tint: .red),
            DonutSegment(id: "tiny", value: 1, tint: .blue),
        ]
        let layout = Donut.layout(segments: segs, size: 160, thickness: 22)
        #expect(layout.arcs[1].dashLength >= 0)
    }
}
```

- [ ] **Step 4: Run `DonutMathTests` and confirm RED**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/DonutMathTests
```
Expected: **FAIL** — compilation error: cannot find `Donut`, `DonutSegment`, or `Donut.layout` in scope (type does not exist yet).

- [ ] **Step 5: Implement `Donut.swift` (pure `layout` + Canvas/Path view) to go GREEN**

`Donut.layout` is `static` and free of SwiftUI side effects so the test can call it directly. The view renders the grey track + each accent arc via SwiftUI `Path` arcs starting at −90°, with rounded caps and an animatable trim driven by `appeared`.

```swift
import SwiftUI

/// One slice of the donut. `id` keeps SwiftUI/ForEach stable.
struct DonutSegment: Identifiable, Equatable {
    let id: String
    let value: Double
    let tint: Color
}

/// Pure geometry result for one arc (testable, no SwiftUI side effects).
struct DonutArcLayout: Equatable {
    let tint: Color
    let fraction: Double      // value / total
    let dashLength: CGFloat   // (fraction * C) - gap, clamped >= 0
    let dashOffset: CGFloat   // accumulated un-gapped length before this arc
}

struct DonutLayout: Equatable {
    let radius: CGFloat
    let circumference: CGFloat
    let arcs: [DonutArcLayout]
}

struct Donut<Center: View>: View {
    let segments: [DonutSegment]
    var size: CGFloat = 140
    var thickness: CGFloat = 20
    @ViewBuilder var center: () -> Center

    @State private var appeared = false

    /// 3pt gap between segments (matches theme.jsx `Math.max(len - 3, 0)`).
    static var gap: CGFloat { 3 }

    /// Pure, side-effect-free geometry. Unit-tested by DonutMathTests.
    static func layout(segments: [DonutSegment], size: CGFloat, thickness: CGFloat) -> DonutLayout {
        let r = (size - thickness) / 2
        let c = 2 * .pi * r
        let total = segments.reduce(0) { $0 + $1.value }
        let denom = total == 0 ? 1 : total
        var acc: CGFloat = 0
        var arcs: [DonutArcLayout] = []
        for s in segments {
            let fraction = s.value / denom
            let len = CGFloat(fraction) * c
            arcs.append(
                DonutArcLayout(
                    tint: s.tint,
                    fraction: fraction,
                    dashLength: max(len - gap, 0),
                    dashOffset: acc
                )
            )
            acc += len
        }
        return DonutLayout(radius: r, circumference: c, arcs: arcs)
    }

    private var layout: DonutLayout {
        Donut.layout(segments: segments, size: size, thickness: thickness)
    }

    var body: some View {
        ZStack {
            // Grey track ring.
            Circle()
                .stroke(Palette.line, lineWidth: thickness)
                .frame(width: layout.radius * 2, height: layout.radius * 2)

            // Accent arcs, -90deg start, rounded caps, animatable trim.
            ForEach(segments) { seg in
                if let arc = layout.arcs.first(where: { $0.tint == seg.tint }) {
                    Circle()
                        .trim(from: trimStart(arc), to: appeared ? trimEnd(arc) : trimStart(arc))
                        .stroke(
                            arc.tint,
                            style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                        )
                        .frame(width: layout.radius * 2, height: layout.radius * 2)
                        .rotationEffect(.degrees(-90))
                }
            }
            center()
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.snap(0.7)) { appeared = true } }
    }

    /// Trim fractions are 0..1 of the full circle; offset/length are in points along C.
    private func trimStart(_ arc: DonutArcLayout) -> CGFloat {
        layout.circumference == 0 ? 0 : arc.dashOffset / layout.circumference
    }
    private func trimEnd(_ arc: DonutArcLayout) -> CGFloat {
        layout.circumference == 0 ? 0 : (arc.dashOffset + arc.dashLength) / layout.circumference
    }
}

extension Donut where Center == EmptyView {
    init(segments: [DonutSegment], size: CGFloat = 140, thickness: CGFloat = 20) {
        self.init(segments: segments, size: size, thickness: thickness) { EmptyView() }
    }
}

#Preview("Donut") {
    Donut(
        segments: [
            DonutSegment(id: "meals", value: 320, tint: Color(red: 0.91, green: 0.376, blue: 0.173)),
            DonutSegment(id: "software", value: 240, tint: Color(red: 0.482, green: 0.357, blue: 0.839)),
            DonutSegment(id: "fuel", value: 140, tint: Color(red: 0.184, green: 0.435, blue: 0.69)),
            DonutSegment(id: "office", value: 90, tint: Color(red: 0.055, green: 0.486, blue: 0.447)),
        ],
        size: 140,
        thickness: 20
    ) {
        VStack(spacing: 2) {
            Text("$790").font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text("spent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
    .padding(40)
}
```

- [ ] **Step 6: Run `DonutMathTests` and confirm GREEN**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/DonutMathTests
```
Expected: **PASS** — all 6 tests pass (radius/circumference, equal split minus gap, accumulating offsets, fractions sum to 1, empty guard, tiny-slice clamp).

- [ ] **Step 7: Write the failing `BarPairMathTests` (TDD red)**

`BarPair.barHeights(data:height:)` is a pure function returning each column's `(incomeHeight, expenseHeight)` scaled to the column area (`height − 22`) against the global max. Test does not yet compile because `BarPair` / `BarPairDatum` don't exist.

```swift
import Testing
import SwiftUI
@testable import Snapceipt

@Suite("BarPair height math")
struct BarPairMathTests {

    @Test("tallest value fills the full column area (height - 22)")
    func tallestFillsArea() {
        let data = [
            BarPairDatum(label: "Jan", income: 100, expense: 50),
            BarPairDatum(label: "Feb", income: 60, expense: 40),
        ]
        let bars = BarPair.barHeights(data: data, height: 120)
        let area = 120 - 22.0
        #expect(abs(bars[0].income - area) < 0.0001)        // 100 is the max
        #expect(abs(bars[0].expense - area * 0.5) < 0.0001) // 50/100
    }

    @Test("scales proportionally to the global max across income+expense")
    func proportionalScaling() {
        let data = [BarPairDatum(label: "Mar", income: 25, expense: 75)]
        let bars = BarPair.barHeights(data: data, height: 122)
        let area = 122 - 22.0
        #expect(abs(bars[0].income - area * (25.0 / 75.0)) < 0.0001)
        #expect(abs(bars[0].expense - area) < 0.0001) // 75 is the global max
    }

    @Test("empty data yields empty heights (no divide-by-zero)")
    func emptyData() {
        let bars = BarPair.barHeights(data: [], height: 120)
        #expect(bars.isEmpty)
    }

    @Test("all-zero data clamps max to 1 so heights are zero, not NaN")
    func allZeroNoNaN() {
        let data = [BarPairDatum(label: "Z", income: 0, expense: 0)]
        let bars = BarPair.barHeights(data: data, height: 120)
        #expect(bars[0].income == 0)
        #expect(bars[0].expense == 0)
        #expect(!bars[0].income.isNaN)
    }
}
```

- [ ] **Step 8: Run `BarPairMathTests` and confirm RED**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BarPairMathTests
```
Expected: **FAIL** — compilation error: cannot find `BarPair` / `BarPairDatum` in scope.

- [ ] **Step 9: Implement `BarPair.swift` (pure `barHeights` + bars view) to go GREEN**

`Palette.income` for the income bar, `accent.base` from the environment for the expense bar (matches `--income` / `--accent` in `reports.jsx`). Width 11, radius 5, gap 4, 0.6s height animation.

```swift
import SwiftUI

/// One month's income vs expense pair.
struct BarPairDatum: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let income: Double
    let expense: Double
}

struct BarPair: View {
    let data: [BarPairDatum]
    var height: CGFloat = 120

    @Environment(\.accent) private var accent
    @State private var appeared = false

    /// Label row reserved at the bottom of each column (matches theme.jsx `height - 22`).
    static var labelRow: CGFloat { 22 }

    /// Pure, side-effect-free bar geometry. Unit-tested by BarPairMathTests.
    static func barHeights(data: [BarPairDatum], height: CGFloat) -> [(income: CGFloat, expense: CGFloat)] {
        guard !data.isEmpty else { return [] }
        let area = height - labelRow
        let maxVal = max(data.flatMap { [$0.income, $0.expense] }.max() ?? 1, 1)
        return data.map { d in
            (
                income: CGFloat(d.income / maxVal) * area,
                expense: CGFloat(d.expense / maxVal) * area
            )
        }
    }

    var body: some View {
        let heights = BarPair.barHeights(data: data, height: height)
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(Array(data.enumerated()), id: \.element.id) { idx, d in
                VStack(spacing: 7) {
                    HStack(alignment: .bottom, spacing: 4) {
                        bar(heights[idx].income, color: Palette.income)
                        bar(heights[idx].expense, color: accent.base)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height - BarPair.labelRow, alignment: .bottom)
                    Text(d.label)
                        .font(.ui(11, .semibold))
                        .foregroundStyle(Palette.ink3)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .padding(.horizontal, 2)
        .onAppear { withAnimation(.snap(0.6)) { appeared = true } }
    }

    private func bar(_ h: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .frame(width: 11, height: appeared ? h : 0)
    }
}

#Preview("BarPair") {
    BarPair(data: [
        BarPairDatum(label: "Jan", income: 4800, expense: 3100),
        BarPairDatum(label: "Feb", income: 5200, expense: 2700),
        BarPairDatum(label: "Mar", income: 4100, expense: 3600),
        BarPairDatum(label: "Apr", income: 6050, expense: 2900),
        BarPairDatum(label: "May", income: 5050, expense: 2480),
    ])
    .padding(40)
    .environment(\.accent, AccentPalette.personal)
}
```

- [ ] **Step 10: Run `BarPairMathTests` and confirm GREEN**

Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/BarPairMathTests
```
Expected: **PASS** — all 4 tests pass (tallest fills area, proportional scaling, empty data, all-zero no-NaN).

- [ ] **Step 11: Implement `EmptyArt.swift` (illustration primitive, pure UI)**

Direct SwiftUI translation of the `EmptyArt` SVG: accent-soft circle, white receipt card stroked accent and rotated −6°, three accent rule lines at opacity .55, and the accent plus badge. Reads `accent` from the environment. No logic test — verified by preview + build.

```swift
import SwiftUI

/// Variant hook for future empty states (only `.receipt` is shipped in foundation).
enum EmptyArtKind {
    case receipt
}

struct EmptyArt: View {
    var kind: EmptyArtKind = .receipt
    var size: CGFloat = 132

    @Environment(\.accent) private var accent

    var body: some View {
        // Work in the 132-unit SVG coordinate space, then scale to `size`.
        let s = size / 132
        ZStack {
            // Accent-soft backing circle, r60 centered at (66,66).
            Circle()
                .fill(accent.soft)
                .frame(width: 120 * s, height: 120 * s)

            // Receipt card: 44x64 r6, white fill, accent stroke 2.4, rotated -6deg.
            ZStack {
                RoundedRectangle(cornerRadius: 6 * s)
                    .fill(Color.white)
                RoundedRectangle(cornerRadius: 6 * s)
                    .stroke(accent.base, lineWidth: 2.4 * s)
                // Three rule lines (52->80, 52->80, 52->72) at y 48/58/68 on the 132 grid.
                Path { p in
                    p.move(to: CGPoint(x: 8 * s, y: 14 * s));  p.addLine(to: CGPoint(x: 36 * s, y: 14 * s))
                    p.move(to: CGPoint(x: 8 * s, y: 24 * s));  p.addLine(to: CGPoint(x: 36 * s, y: 24 * s))
                    p.move(to: CGPoint(x: 8 * s, y: 34 * s));  p.addLine(to: CGPoint(x: 28 * s, y: 34 * s))
                }
                .stroke(accent.base,
                        style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
                .opacity(0.55)
            }
            .frame(width: 44 * s, height: 64 * s)
            .rotationEffect(.degrees(-6))

            // Plus badge: accent circle r17 at (92,92), white plus.
            ZStack {
                Circle().fill(accent.base)
                Path { p in
                    p.move(to: CGPoint(x: 17 * s, y: 10 * s)); p.addLine(to: CGPoint(x: 17 * s, y: 24 * s))
                    p.move(to: CGPoint(x: 10 * s, y: 17 * s)); p.addLine(to: CGPoint(x: 24 * s, y: 17 * s))
                }
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: 2.8 * s, lineCap: .round))
            }
            .frame(width: 34 * s, height: 34 * s)
            // Badge center sits at (92,92); circle (66,66) is at the ZStack center, so offset = +26.
            .offset(x: 26 * s, y: 26 * s)
        }
        .frame(width: size, height: size)
    }
}

#Preview("EmptyArt") {
    VStack(spacing: 28) {
        EmptyArt().environment(\.accent, AccentPalette.personal)
        EmptyArt(size: 96).environment(\.accent, AccentPalette.business)
    }
    .padding(40)
    .background(Palette.cream)
}
```

- [ ] **Step 12: Full build + run the whole suite to confirm everything integrates**

Run:
```bash
xcodegen generate && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/DonutMathTests -only-testing:SnapceiptTests/BarPairMathTests
```
Expected: **PASS** (BUILD SUCCEEDED + both suites green). This compiles `Donut.swift`, `BarPair.swift`, `EmptyArt.swift`, and `Animations.swift` together against `Palette`, `Radius`, `AccentPalette`, `\.accent`, and `Font.ui` from Tasks 4/5, and runs the two math suites.

- [ ] **Step 13: Commit**

Run:
```bash
git add Snapceipt/DesignSystem/Animations.swift Snapceipt/DesignSystem/Primitives/Donut.swift Snapceipt/DesignSystem/Primitives/BarPair.swift Snapceipt/DesignSystem/Primitives/EmptyArt.swift SnapceiptTests/DonutMathTests.swift SnapceiptTests/BarPairMathTests.swift project.yml
git commit -m "$(cat <<'EOF'
feat(ios): add Donut/BarPair/EmptyArt primitives + Animations

Donut: -90deg arc ring with 3pt gaps, rounded caps, grey track, animatable
trim; pure Donut.layout geometry unit-tested. BarPair: income/expense rounded
bars (w11 r5) height-scaled to max with 0.6s grow; pure BarPair.barHeights
unit-tested. EmptyArt: accent-soft circle + receipt + plus-badge illustration.
Animations.swift: central Animation.snap timingCurve(0.22,0.61,0.36,1) plus
scFadeUp/scRise transitions, scRing/scPopIn helpers, ScCheckShape, ScConfettiPiece.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
Expected: **PASS** — commit created on the feature branch.

---

Notes for the integrating author:
- `Donut.layout` and `BarPair.barHeights` are the single source of truth for geometry; the views call them — never duplicate the math inline. Reports (later phase) feeds `DonutSegment(id: CategoryKey.rawValue, value:, tint: CategoryMeta.tint)` and `BarPairDatum` arrays.
- `Donut` requires the `Center` generic; use the `where Center == EmptyView` convenience init for a bare ring, or the trailing closure for the centered "$790 / spent" label.
- The `#Preview` blocks hardcode literal `Color(red:…)` / `AccentPalette.personal` so they render standalone without the live `ProfilesStore`; production call sites get `accent` from the environment via the active profile (Task owning `ProfilesStore`/`RootView`).
- This task assumes Task 4 exposes `Palette.line`, `Palette.income`, `Palette.ink3`, `Palette.cream`, and `AccentPalette.personal` / `.business`, and that `\.accent` defaults to terracotta — consistent with the canonical spine.


---

### Task 8: swiftdata-model

Build the local-first persistence layer: the `Syncable` protocol + the shared sync envelope fields, the `EntityType` enum (the 12 syncable types, camelCase, matching the backend), `ID.uuidv7()` / `Clock.nowMs()`, the `OutboxMutation` model, the eleven domain `@Model` classes (Profile, Transaction, LineItem, Category, Budget, LoyaltyCard, MileageTrip, WFHLog, Quote, QuoteLineItem, TaxSettings), and the `ModelContainer+Snapceipt` schema list + `makeSnapceiptContainer(inMemory:)` helper. Every `@Model` mirrors the D1 schema in `2026-05-30-backend-foundation.md` 1:1 and uses the **exact camelCase property names** the backend's `SYNCABLE_TABLES` / `rowToEntity` envelope produces (e.g. `catKey`, `amountCents`, `accent1/2/3`, `gstRegistered`, `lastEditedDeviceId`) so sync payloads round-trip without translation. TDD with an in-memory `ModelContainer`.

**Files**
- Create: `Snapceipt/Model/IDClock.swift`
- Create: `Snapceipt/Model/EntityType.swift`
- Create: `Snapceipt/Model/Syncable.swift`
- Create: `Snapceipt/Model/OutboxMutation.swift`
- Create: `Snapceipt/Model/Entities/Profile.swift`
- Create: `Snapceipt/Model/Entities/Transaction.swift`
- Create: `Snapceipt/Model/Entities/LineItem.swift`
- Create: `Snapceipt/Model/Entities/Category.swift`
- Create: `Snapceipt/Model/Entities/Budget.swift`
- Create: `Snapceipt/Model/Entities/LoyaltyCard.swift`
- Create: `Snapceipt/Model/Entities/MileageTrip.swift`
- Create: `Snapceipt/Model/Entities/WFHLog.swift`
- Create: `Snapceipt/Model/Entities/Quote.swift`
- Create: `Snapceipt/Model/Entities/QuoteLineItem.swift`
- Create: `Snapceipt/Model/Entities/TaxSettings.swift`
- Create: `Snapceipt/Model/ModelContainer+Snapceipt.swift`
- Modify: `project.yml` (no source-glob change needed if `Snapceipt/` is already globbed; this task adds files under existing folders)
- Test: `SnapceiptTests/EntityTypeTests.swift`
- Test: `SnapceiptTests/IDClockTests.swift`
- Test: `SnapceiptTests/SwiftDataModelTests.swift`

> Depends on prior tasks for: the XcodeGen `project.yml` + `Snapceipt`/`SnapceiptTests` targets (Task scaffold), `CategoryKey` (`Model/Categories.swift`) — only referenced in a doc comment here, not imported into models — and `Palette`/`AccentPalette` (`DesignSystem/`), which other tasks own. This task does **not** redefine those. It defines only the model layer.

---

- [ ] **Step 1: Create `Snapceipt/Model/IDClock.swift` — `ID.uuidv7()` + `Clock.nowMs()`**

  UUIDv7 (RFC 9562): 48-bit big-endian Unix-ms timestamp, version 7, variant 10xx, random low bits. Lexicographically sortable in generation order so ids double as an offline-safe ordering key. `Clock.nowMs()` is epoch milliseconds (the LWW / `updatedAt` unit used everywhere).

```swift
import Foundation

/// Client-generated identifiers. UUIDv7 (RFC 9562) is time-ordered + sortable,
/// so ids are offline-safe and stable across the sync round-trip.
enum ID {
    /// Generates an RFC 9562 UUIDv7 string (lowercase, hyphenated).
    static func uuidv7() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit big-endian Unix epoch milliseconds in bytes[0..5].
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        bytes[0] = UInt8((ms >> 40) & 0xFF)
        bytes[1] = UInt8((ms >> 32) & 0xFF)
        bytes[2] = UInt8((ms >> 24) & 0xFF)
        bytes[3] = UInt8((ms >> 16) & 0xFF)
        bytes[4] = UInt8((ms >> 8) & 0xFF)
        bytes[5] = UInt8(ms & 0xFF)

        // 10 random bytes for rand_a (bytes[6..7]) + rand_b (bytes[8..15]).
        var rand = [UInt8](repeating: 0, count: 10)
        for i in rand.indices { rand[i] = UInt8.random(in: 0...255) }

        // bytes[6]: version 7 (0111) in the high nibble + 4 random bits.
        bytes[6] = 0x70 | (rand[0] & 0x0F)
        bytes[7] = rand[1]
        // bytes[8]: variant 10xx + 6 random bits.
        bytes[8] = 0x80 | (rand[2] & 0x3F)
        bytes[9] = rand[3]
        bytes[10] = rand[4]
        bytes[11] = rand[5]
        bytes[12] = rand[6]
        bytes[13] = rand[7]
        bytes[14] = rand[8]
        bytes[15] = rand[9]

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return String(s[0..<8]) + "-"
            + String(s[8..<12]) + "-"
            + String(s[12..<16]) + "-"
            + String(s[16..<20]) + "-"
            + String(s[20..<32])
    }
}

/// Epoch-millisecond clock. All `createdAt`/`updatedAt`/`deletedAt` timestamps
/// (the LWW + cursor key) are integer ms in UTC.
enum Clock {
    /// Current time as integer epoch milliseconds.
    static func nowMs() -> Int {
        Int((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
```

- [ ] **Step 2 (TDD — write failing test): `SnapceiptTests/IDClockTests.swift`**

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("IDClock")
struct IDClockTests {
    @Test("uuidv7 is RFC-shaped: version 7 + variant 10xx")
    func shape() {
        let id = ID.uuidv7()
        // 8-4-4-4-12, version nibble = 7, variant nibble in 8/9/a/b.
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        #expect(id.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("uuidv7 is unique across a large batch")
    func unique() {
        var seen = Set<String>()
        for _ in 0..<5000 { seen.insert(ID.uuidv7()) }
        #expect(seen.count == 5000)
    }

    @Test("uuidv7 is time-ordered: ids generated later sort >= earlier")
    func ordered() throws {
        let first = ID.uuidv7()
        // Force a later millisecond so the 48-bit prefix advances.
        Thread.sleep(forTimeInterval: 0.003)
        let second = ID.uuidv7()
        #expect(second > first)
    }

    @Test("nowMs returns integer ms close to wall clock")
    func nowMs() {
        let t = Clock.nowMs()
        let wall = Int((Date().timeIntervalSince1970 * 1000).rounded())
        #expect(abs(t - wall) < 1000)
    }
}
```

  Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/IDClock
```
  Expected (FAIL → then PASS): If `IDClock.swift` is not yet added to the target the build fails with `cannot find 'ID' in scope` / `cannot find 'Clock' in scope`. After Step 1's file is regenerated into the project (`xcodegen generate`) and built, all 4 cases PASS.

- [ ] **Step 3: Regenerate the Xcode project so the new files are picked up**

  XcodeGen globs the `Snapceipt/` and `SnapceiptTests/` folders, so newly added files are included on regenerate. Run after creating files in each step group.

```bash
xcodegen generate --project /Users/yangqi/Documents/github/Snapceipt
```
  Expected: prints `Created project at .../Snapceipt.xcodeproj` (or `Loaded ... Generated project`) and exits 0. Re-run this whenever you add a new `.swift` file before invoking `xcodebuild`.

- [ ] **Step 4: Create `Snapceipt/Model/EntityType.swift` — the 12 syncable types (camelCase, matching the backend)**

  Order + spelling match the backend `SYNCABLE_TABLES` keys exactly: `transaction, lineItem, profile, category, smartRule, budget, loyaltyCard, quote, quoteLineItem, mileageTrip, wfhLog, taxSettings`.

```swift
import Foundation

/// The 12 syncable entity types. Raw values are the camelCase strings the
/// backend `SYNCABLE_TABLES` keys + `PushMutation.entityType` use verbatim.
enum EntityType: String, CaseIterable, Codable, Sendable {
    case transaction
    case lineItem
    case profile
    case category
    case smartRule
    case budget
    case loyaltyCard
    case quote
    case quoteLineItem
    case mileageTrip
    case wfhLog
    case taxSettings
}
```

- [ ] **Step 5 (TDD — write failing test): `SnapceiptTests/EntityTypeTests.swift`**

```swift
import Testing
@testable import Snapceipt

@Suite("EntityType")
struct EntityTypeTests {
    @Test("has exactly the 12 syncable cases")
    func count() {
        #expect(EntityType.allCases.count == 12)
    }

    @Test("raw values match the backend camelCase contract")
    func rawValues() {
        let expected = [
            "transaction", "lineItem", "profile", "category", "smartRule",
            "budget", "loyaltyCard", "quote", "quoteLineItem",
            "mileageTrip", "wfhLog", "taxSettings",
        ]
        #expect(EntityType.allCases.map(\.rawValue) == expected)
    }

    @Test("round-trips through its raw string")
    func roundTrip() throws {
        let t = try #require(EntityType(rawValue: "loyaltyCard"))
        #expect(t == .loyaltyCard)
        #expect(EntityType(rawValue: "nope") == nil)
    }
}
```

  Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/EntityType
```
  Expected (FAIL → then PASS): Before Step 4 + `xcodegen generate`, the build fails (`cannot find type 'EntityType' in scope`). After adding the enum + regenerating, all 3 cases PASS.

- [ ] **Step 6: Create `Snapceipt/Model/Syncable.swift` — the shared sync-envelope protocol**

  SwiftData `@Model` classes cannot share stored properties through a protocol, so every model declares the eight envelope fields identically; this protocol lets generic sync code read them. Property names match the backend `rowToEntity` envelope: `id, userId, profileId?, createdAt, updatedAt, deletedAt?, rev, lastEditedDeviceId?`.

```swift
import Foundation

/// The shared sync envelope. Every syncable `@Model` declares these eight stored
/// properties identically (SwiftData cannot synthesize stored protocol props), and
/// conforms to `Syncable` so generic push/pull code can read them uniformly.
/// Names mirror the backend `rowToEntity` camelCase envelope 1:1.
protocol Syncable {
    /// Client-generated UUIDv7 primary key.
    var id: String { get }
    /// Tenant boundary — the owning user's id.
    var userId: String { get }
    /// UI sub-scope; nil on types that aren't profile-scoped (profile, lineItem, quoteLineItem).
    var profileId: String? { get }
    /// Epoch-ms creation time.
    var createdAt: Int { get }
    /// Epoch-ms last-write time — the LWW key + pull cursor component.
    var updatedAt: Int { get }
    /// Soft-delete tombstone (epoch ms) or nil when live.
    var deletedAt: Int? { get }
    /// Server-stamped revision; bumped on each accepted write.
    var rev: Int { get }
    /// Device that produced the last edit (for conflict diagnostics).
    var lastEditedDeviceId: String? { get }

    /// The entity type used for sync routing (constant per concrete model).
    var entityType: EntityType { get }
}
```

- [ ] **Step 7: Create `Snapceipt/Model/OutboxMutation.swift` — the offline mutation queue row**

```swift
import Foundation
import SwiftData

/// One queued local mutation awaiting push. The SyncEngine drains these; the
/// `mutationId` is the server idempotency key. `payloadJSON` holds the full
/// camelCase entity snapshot for an upsert, or just the id for a delete.
@Model
final class OutboxMutation {
    /// Stable idempotency key (UUIDv7) sent as PushMutation.mutationId.
    @Attribute(.unique) var mutationId: String
    /// EntityType raw value (e.g. "transaction").
    var entityType: String
    /// The target entity's id.
    var entityId: String
    /// "upsert" | "delete".
    var op: String
    /// JSON snapshot of the entity (upsert) or `{ "id": ... }` (delete).
    var payloadJSON: String
    /// The local rev the edit was based on (for server LWW tie-breaking); nil if new.
    var baseRev: Int?
    /// Epoch-ms enqueue time (drain order).
    var createdAt: Int
    /// Retry counter for backoff.
    var attemptCount: Int
    /// "pending" | "inflight" | "acked" | "failed".
    var status: String

    init(
        mutationId: String = ID.uuidv7(),
        entityType: String,
        entityId: String,
        op: String,
        payloadJSON: String,
        baseRev: Int? = nil,
        createdAt: Int = Clock.nowMs(),
        attemptCount: Int = 0,
        status: String = "pending"
    ) {
        self.mutationId = mutationId
        self.entityType = entityType
        self.entityId = entityId
        self.op = op
        self.payloadJSON = payloadJSON
        self.baseRev = baseRev
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.status = status
    }
}
```

- [ ] **Step 8: Create `Snapceipt/Model/Entities/Profile.swift`**

  Mirrors the D1 `profiles` table + the `profile` `SYNCABLE_TABLES.columns` map: `name, type, initials?, accent1/2/3, abn?, gstRegistered, sortOrder, isDefault`. `profileId` is `nil` (profiles aren't profile-scoped). `type` is "personal" | "business"; accents are hex strings (e.g. `#0E7C72`).

```swift
import Foundation
import SwiftData

/// A switchable persona (Personal / Business). Drives the active accent palette.
/// Mirrors D1 `profiles`. `accent1/2/3` are the base/soft/deep hex strings.
@Model
final class Profile: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (a profile is not profile-scoped)

    var name: String
    var type: String                 // "personal" | "business"
    var initials: String?
    var accent1: String              // base hex, e.g. "#0E7C72"
    var accent2: String              // soft hex
    var accent3: String              // deep hex
    var abn: String?
    var gstRegistered: Bool
    var sortOrder: Int
    var isDefault: Bool

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .profile }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        name: String,
        type: String,
        initials: String? = nil,
        accent1: String,
        accent2: String,
        accent3: String,
        abn: String? = nil,
        gstRegistered: Bool = false,
        sortOrder: Int = 0,
        isDefault: Bool = false,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.name = name
        self.type = type
        self.initials = initials
        self.accent1 = accent1
        self.accent2 = accent2
        self.accent3 = accent3
        self.abn = abn
        self.gstRegistered = gstRegistered
        self.sortOrder = sortOrder
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 9: Create `Snapceipt/Model/Entities/Transaction.swift`**

  Mirrors D1 `transactions` + the `transaction` columns map: `merchant, catKey, amountCents, currency, txnDate, mode, taxLabel?, deductiblePct?, paymentMethod?, isAi, note?, gstCents?, source, extractionStatus?` (+ `categoryId?`, `logbookLink?`, `mileageTripId?` from the schema). `catKey` is the raw category-key string (one of the 9 + "custom"); `amountCents` is signed Int cents.

```swift
import Foundation
import SwiftData

/// A ledger entry (expense negative, income positive). Mirrors D1 `transactions`.
/// `catKey` stores a `CategoryKey` raw value (or "custom"); `amountCents` is signed cents.
@Model
final class Transaction: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var merchant: String
    var categoryId: String?
    var catKey: String               // CategoryKey raw value or "custom"
    var amountCents: Int             // signed: expense < 0, income > 0
    var currency: String
    var txnDate: String              // "YYYY-MM-DD"
    var mode: String                 // "business" | "personal"
    var taxLabel: String?
    var deductiblePct: Int?
    var paymentMethod: String?
    var isAi: Bool
    var note: String?
    var gstCents: Int?
    var logbookLink: String?         // "vehicle" | "wfh" | nil
    var mileageTripId: String?
    var source: String               // "manual" | "scan" | "email_in" | "import"
    var extractionStatus: String?    // "pending" | "done" | "failed" | nil

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .transaction }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        merchant: String = "",
        categoryId: String? = nil,
        catKey: String,
        amountCents: Int,
        currency: String = "AUD",
        txnDate: String,
        mode: String = "personal",
        taxLabel: String? = nil,
        deductiblePct: Int? = nil,
        paymentMethod: String? = nil,
        isAi: Bool = false,
        note: String? = nil,
        gstCents: Int? = nil,
        logbookLink: String? = nil,
        mileageTripId: String? = nil,
        source: String = "manual",
        extractionStatus: String? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.merchant = merchant
        self.categoryId = categoryId
        self.catKey = catKey
        self.amountCents = amountCents
        self.currency = currency
        self.txnDate = txnDate
        self.mode = mode
        self.taxLabel = taxLabel
        self.deductiblePct = deductiblePct
        self.paymentMethod = paymentMethod
        self.isAi = isAi
        self.note = note
        self.gstCents = gstCents
        self.logbookLink = logbookLink
        self.mileageTripId = mileageTripId
        self.source = source
        self.extractionStatus = extractionStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 10: Create `Snapceipt/Model/Entities/LineItem.swift`**

  Mirrors D1 `line_items` + the `lineItem` columns: `transactionId, name, priceCents, quantity, sortOrder`. `profileId` is nil (children are parent-owned).

```swift
import Foundation
import SwiftData

/// A line on a receipt, owned by its parent Transaction. Mirrors D1 `line_items`.
@Model
final class LineItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of a transaction)

    var transactionId: String
    var name: String
    var priceCents: Int
    var quantity: Int
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .lineItem }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        transactionId: String,
        name: String,
        priceCents: Int,
        quantity: Int = 1,
        sortOrder: Int = 0,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.transactionId = transactionId
        self.name = name
        self.priceCents = priceCents
        self.quantity = quantity
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 11: Create `Snapceipt/Model/Entities/Category.swift`**

  Mirrors D1 `categories` + the `category` columns: `key, label, icon, tint, soft, defaultDeductiblePct?, isIncome, sortOrder`. Profile-scoped (`profileId?`).

```swift
import Foundation
import SwiftData

/// A spend category. Mirrors D1 `categories`. `key` is a `CategoryKey` raw value
/// or "custom"; `tint`/`soft` are hex strings.
@Model
final class Category: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var key: String                  // CategoryKey raw value or "custom"
    var label: String
    var icon: String
    var tint: String                 // hex
    var soft: String                 // hex
    var defaultDeductiblePct: Int?
    var isIncome: Bool
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .category }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String? = nil,
        key: String,
        label: String,
        icon: String,
        tint: String,
        soft: String,
        defaultDeductiblePct: Int? = nil,
        isIncome: Bool = false,
        sortOrder: Int = 0,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.key = key
        self.label = label
        self.icon = icon
        self.tint = tint
        self.soft = soft
        self.defaultDeductiblePct = defaultDeductiblePct
        self.isIncome = isIncome
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 12: Create `Snapceipt/Model/Entities/Budget.swift`**

  Mirrors D1 `budgets` + the `budget` columns: `categoryId?, catKey?, label, period, monthKey?, capCents, currency, alertThresholdPct, alertSentAt?`. Profile-scoped.

```swift
import Foundation
import SwiftData

/// A per-category / per-profile spend cap. Mirrors D1 `budgets`. Spent is computed
/// from transactions, never stored.
@Model
final class Budget: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var categoryId: String?
    var catKey: String?
    var label: String
    var period: String               // "monthly"
    var monthKey: String?            // "YYYY-MM"
    var capCents: Int
    var currency: String
    var alertThresholdPct: Int
    var alertSentAt: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .budget }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        categoryId: String? = nil,
        catKey: String? = nil,
        label: String,
        period: String = "monthly",
        monthKey: String? = nil,
        capCents: Int,
        currency: String = "AUD",
        alertThresholdPct: Int = 90,
        alertSentAt: Int? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.categoryId = categoryId
        self.catKey = catKey
        self.label = label
        self.period = period
        self.monthKey = monthKey
        self.capCents = capCents
        self.currency = currency
        self.alertThresholdPct = alertThresholdPct
        self.alertSentAt = alertSentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 13: Create `Snapceipt/Model/Entities/LoyaltyCard.swift`**

  Mirrors D1 `loyalty_cards` + the `loyaltyCard` columns: `brand, subBrand?, number, barcodeFormat?, pointsLabel?, color1, color2, sortOrder`. Profile-scoped.

```swift
import Foundation
import SwiftData

/// A loyalty card with a scannable barcode. Mirrors D1 `loyalty_cards`.
@Model
final class LoyaltyCard: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var brand: String
    var subBrand: String?
    var number: String
    var barcodeFormat: String?       // "code128" | "ean13" | "qr" | "aztec" | "pdf417" | nil
    var pointsLabel: String?
    var color1: String               // hex
    var color2: String               // hex
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .loyaltyCard }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String? = nil,
        brand: String,
        subBrand: String? = nil,
        number: String,
        barcodeFormat: String? = nil,
        pointsLabel: String? = nil,
        color1: String,
        color2: String,
        sortOrder: Int = 0,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.brand = brand
        self.subBrand = subBrand
        self.number = number
        self.barcodeFormat = barcodeFormat
        self.pointsLabel = pointsLabel
        self.color1 = color1
        self.color2 = color2
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 14: Create `Snapceipt/Model/Entities/MileageTrip.swift`**

  Mirrors D1 `mileage_trips` + the `mileageTrip` columns: `tripDate, fromLabel?, toLabel?, purpose?, distanceM, isBusiness, rateCentsPerKm?, claimCents?, autoTracked`. Profile-scoped.

```swift
import Foundation
import SwiftData

/// A logged vehicle trip (manual; GPS auto-track is placeholder in v1).
/// Mirrors D1 `mileage_trips`. `distanceM` is metres.
@Model
final class MileageTrip: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var tripDate: String             // "YYYY-MM-DD"
    var fromLabel: String?
    var toLabel: String?
    var purpose: String?
    var distanceM: Int               // metres
    var isBusiness: Bool
    var rateCentsPerKm: Int?
    var claimCents: Int?
    var autoTracked: Bool

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .mileageTrip }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        tripDate: String,
        fromLabel: String? = nil,
        toLabel: String? = nil,
        purpose: String? = nil,
        distanceM: Int,
        isBusiness: Bool = true,
        rateCentsPerKm: Int? = nil,
        claimCents: Int? = nil,
        autoTracked: Bool = false,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.tripDate = tripDate
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.purpose = purpose
        self.distanceM = distanceM
        self.isBusiness = isBusiness
        self.rateCentsPerKm = rateCentsPerKm
        self.claimCents = claimCents
        self.autoTracked = autoTracked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 15: Create `Snapceipt/Model/Entities/WFHLog.swift`**

  Mirrors D1 `wfh_logs` + the `wfhLog` columns: `logDate, minutes, note?, rateCentsPerHour?, claimCents?`. Profile-scoped.

```swift
import Foundation
import SwiftData

/// A work-from-home day entry (fixed 67c/hr method). Mirrors D1 `wfh_logs`.
@Model
final class WFHLog: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var logDate: String              // "YYYY-MM-DD"
    var minutes: Int
    var note: String?
    var rateCentsPerHour: Int?
    var claimCents: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .wfhLog }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        logDate: String,
        minutes: Int,
        note: String? = nil,
        rateCentsPerHour: Int? = nil,
        claimCents: Int? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.logDate = logDate
        self.minutes = minutes
        self.note = note
        self.rateCentsPerHour = rateCentsPerHour
        self.claimCents = claimCents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 16: Create `Snapceipt/Model/Entities/Quote.swift`**

  Mirrors D1 `quotes` + the `quote` columns: `number?, clientName?, clientEmail?, gstEnabled, subtotalCents, gstCents, totalCents, currency, status, validUntil?, sentAt?`. Profile-scoped.

```swift
import Foundation
import SwiftData

/// A client quote (Business). Totals are server-recomputed on save. Mirrors D1 `quotes`.
@Model
final class Quote: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var number: String?
    var clientName: String?
    var clientEmail: String?
    var gstEnabled: Bool
    var subtotalCents: Int
    var gstCents: Int
    var totalCents: Int
    var currency: String
    var status: String               // "draft" | "sent" | "accepted" | "declined" | "expired" | "invoiced"
    var validUntil: String?          // "YYYY-MM-DD"
    var sentAt: Int?

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .quote }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        number: String? = nil,
        clientName: String? = nil,
        clientEmail: String? = nil,
        gstEnabled: Bool = true,
        subtotalCents: Int = 0,
        gstCents: Int = 0,
        totalCents: Int = 0,
        currency: String = "AUD",
        status: String = "draft",
        validUntil: String? = nil,
        sentAt: Int? = nil,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.number = number
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.gstEnabled = gstEnabled
        self.subtotalCents = subtotalCents
        self.gstCents = gstCents
        self.totalCents = totalCents
        self.currency = currency
        self.status = status
        self.validUntil = validUntil
        self.sentAt = sentAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 17: Create `Snapceipt/Model/Entities/QuoteLineItem.swift`**

  Mirrors D1 `quote_line_items` + the `quoteLineItem` columns: `quoteId, description, quantity, unitPriceCents, sortOrder`. `lineTotalCents` is a server-generated column, so it is **not** a writable sync field — exposed as a computed convenience only. `profileId` is nil (child of a quote).

```swift
import Foundation
import SwiftData

/// A line on a quote, owned by its parent Quote. Mirrors D1 `quote_line_items`.
/// `lineTotalCents` is server-generated (quantity * unitPriceCents) — computed locally,
/// not a synced/stored field.
@Model
final class QuoteLineItem: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?           // always nil (child of a quote)

    var quoteId: String
    var itemDescription: String      // maps to backend "description"
    var quantity: Int
    var unitPriceCents: Int
    var sortOrder: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .quoteLineItem }

    /// Server-generated `line_total_cents` mirror; never persisted as a sync field.
    var lineTotalCents: Int { quantity * unitPriceCents }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        quoteId: String,
        itemDescription: String,
        quantity: Int = 1,
        unitPriceCents: Int,
        sortOrder: Int = 0,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = nil
        self.quoteId = quoteId
        self.itemDescription = itemDescription
        self.quantity = quantity
        self.unitPriceCents = unitPriceCents
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

> Note: the backend `quoteLineItem` column key is `description`, but `description` collides with Swift's `CustomStringConvertible`. We store it as `itemDescription` and the Sync task (DTO mapping) maps `itemDescription ↔ "description"` when building the push payload.

- [ ] **Step 18: Create `Snapceipt/Model/Entities/TaxSettings.swift`**

  Mirrors D1 `tax_settings` + the `taxSettings` columns: `gstRateBps, financialYearStartMonth, mealsDeductiblePct, wfhRateCentsPerHour, mileageRateCentsPerKm`. Profile-scoped (one per profile).

```swift
import Foundation
import SwiftData

/// Per-profile AU tax configuration. Mirrors D1 `tax_settings`.
@Model
final class TaxSettings: Syncable {
    @Attribute(.unique) var id: String
    var userId: String
    var profileId: String?

    var gstRateBps: Int              // 1000 = 10%
    var financialYearStartMonth: Int // 7 = July (AU FY)
    var mealsDeductiblePct: Int
    var wfhRateCentsPerHour: Int
    var mileageRateCentsPerKm: Int

    var createdAt: Int
    var updatedAt: Int
    var deletedAt: Int?
    var rev: Int
    var lastEditedDeviceId: String?

    var entityType: EntityType { .taxSettings }

    init(
        id: String = ID.uuidv7(),
        userId: String,
        profileId: String?,
        gstRateBps: Int = 1000,
        financialYearStartMonth: Int = 7,
        mealsDeductiblePct: Int = 50,
        wfhRateCentsPerHour: Int = 67,
        mileageRateCentsPerKm: Int = 88,
        createdAt: Int = Clock.nowMs(),
        updatedAt: Int = Clock.nowMs(),
        deletedAt: Int? = nil,
        rev: Int = 0,
        lastEditedDeviceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.profileId = profileId
        self.gstRateBps = gstRateBps
        self.financialYearStartMonth = financialYearStartMonth
        self.mealsDeductiblePct = mealsDeductiblePct
        self.wfhRateCentsPerHour = wfhRateCentsPerHour
        self.mileageRateCentsPerKm = mileageRateCentsPerKm
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
        self.lastEditedDeviceId = lastEditedDeviceId
    }
}
```

- [ ] **Step 19: Create `Snapceipt/Model/ModelContainer+Snapceipt.swift` — the schema list + `makeSnapceiptContainer(inMemory:)`**

  Lists all 12 syncable models + `OutboxMutation`. `makeSnapceiptContainer(inMemory:)` is reused by `SnapceiptApp` (persistent) and every test (in-memory). It is non-throwing at call sites that pass `inMemory: true` by `try`-wrapping; we expose a throwing factory and let callers handle.

```swift
import Foundation
import SwiftData

/// The full Snapceipt SwiftData schema: the 12 syncable domain models + the
/// offline OutboxMutation queue.
enum SnapceiptSchema {
    static let models: [any PersistentModel.Type] = [
        Profile.self,
        Transaction.self,
        LineItem.self,
        Category.self,
        Budget.self,
        LoyaltyCard.self,
        MileageTrip.self,
        WFHLog.self,
        Quote.self,
        QuoteLineItem.self,
        TaxSettings.self,
        OutboxMutation.self,
    ]

    static let schema = Schema(models)
}

extension ModelContainer {
    /// Builds the app's ModelContainer. Pass `inMemory: true` for tests/previews
    /// (ephemeral store) and `false` for the on-disk app store.
    static func makeSnapceiptContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: SnapceiptSchema.schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(for: SnapceiptSchema.schema, configurations: [config])
    }
}
```

- [ ] **Step 20: Regenerate the project for all the new model files**

```bash
xcodegen generate --project /Users/yangqi/Documents/github/Snapceipt
```
  Expected: exits 0; all 16 new model files are now members of the `Snapceipt` target.

- [ ] **Step 21 (TDD — write failing test): `SnapceiptTests/SwiftDataModelTests.swift`**

  Uses an in-memory container. Inserts a Profile + Transaction, fetches the transaction by `profileId` (filtered by a captured String to satisfy `#Predicate` rules), asserts the sync envelope fields persist; round-trips an `OutboxMutation`; and re-asserts the 12-case `EntityType` count.

```swift
import Testing
import SwiftData
@testable import Snapceipt

@Suite("SwiftDataModel")
struct SwiftDataModelTests {

    /// A fresh, isolated in-memory context per test.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        return ModelContext(container)
    }

    @Test("inserts a Profile + Transaction and fetches by profileId with sync fields intact")
    func insertFetchProfileScoped() throws {
        let ctx = try makeContext()

        let profile = Profile(
            userId: "u1",
            name: "Studio North",
            type: "business",
            initials: "SN",
            accent1: "#0E7C72",
            accent2: "#DCF0ED",
            accent3: "#0A5950",
            abn: "12 345 678 901",
            gstRegistered: true,
            sortOrder: 1,
            isDefault: true,
            lastEditedDeviceId: "dev-1"
        )
        ctx.insert(profile)

        let pid = profile.id
        let txn = Transaction(
            userId: "u1",
            profileId: pid,
            merchant: "The Grounds",
            catKey: "meals",
            amountCents: -4250,
            txnDate: "2026-05-28",
            mode: "business",
            deductiblePct: 50,
            gstCents: 386,
            source: "scan",
            rev: 3,
            lastEditedDeviceId: "dev-1"
        )
        ctx.insert(txn)
        try ctx.save()

        // Fetch the transaction filtered by its profile (capture a String, not the
        // optional column directly, to keep the #Predicate simple + valid).
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.profileId == pid }
        )
        descriptor.sortBy = [SortDescriptor(\.updatedAt)]
        let found = try ctx.fetch(descriptor)

        let one = try #require(found.first)
        #expect(found.count == 1)
        #expect(one.merchant == "The Grounds")
        #expect(one.catKey == "meals")
        #expect(one.amountCents == -4250)        // signed Int cents
        #expect(one.currency == "AUD")           // default applied
        #expect(one.gstCents == 386)
        #expect(one.deductiblePct == 50)
        #expect(one.source == "scan")
        // Sync envelope persisted:
        #expect(one.userId == "u1")
        #expect(one.profileId == pid)
        #expect(one.rev == 3)
        #expect(one.deletedAt == nil)
        #expect(one.lastEditedDeviceId == "dev-1")
        #expect(one.entityType == .transaction)

        // The profile persisted its business fields + accent palette.
        let profiles = try ctx.fetch(FetchDescriptor<Profile>())
        let p = try #require(profiles.first)
        #expect(p.type == "business")
        #expect(p.accent1 == "#0E7C72")
        #expect(p.gstRegistered == true)
        #expect(p.isDefault == true)
        #expect(p.profileId == nil)              // a profile is not profile-scoped
        #expect(p.entityType == .profile)
    }

    @Test("a soft-delete tombstone persists on a syncable row")
    func tombstone() throws {
        let ctx = try makeContext()
        let card = LoyaltyCard(
            userId: "u1",
            brand: "Flybuys",
            number: "6008900000000000",
            barcodeFormat: "code128",
            color1: "#0E7C72",
            color2: "#0A5950",
            deletedAt: 1_900_000_000_000
        )
        ctx.insert(card)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<LoyaltyCard>())
        let c = try #require(rows.first)
        #expect(c.deletedAt == 1_900_000_000_000)
        #expect(c.barcodeFormat == "code128")
        #expect(c.entityType == .loyaltyCard)
    }

    @Test("OutboxMutation round-trips through the store")
    func outboxRoundTrip() throws {
        let ctx = try makeContext()
        let m = OutboxMutation(
            entityType: EntityType.transaction.rawValue,
            entityId: "t1",
            op: "upsert",
            payloadJSON: #"{"id":"t1","amountCents":-4250}"#,
            baseRev: 2,
            attemptCount: 0,
            status: "pending"
        )
        ctx.insert(m)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<OutboxMutation>())
        let got = try #require(rows.first)
        #expect(got.entityType == "transaction")
        #expect(got.entityId == "t1")
        #expect(got.op == "upsert")
        #expect(got.baseRev == 2)
        #expect(got.status == "pending")
        #expect(got.payloadJSON.contains("-4250"))
        #expect(!got.mutationId.isEmpty)
    }

    @Test("EntityType still has exactly the 12 syncable cases")
    func entityTypeCount() {
        #expect(EntityType.allCases.count == 12)
    }

    @Test("the full schema builds an in-memory container without throwing")
    func schemaBuilds() throws {
        let container = try ModelContainer.makeSnapceiptContainer(inMemory: true)
        #expect(container.schema.entities.isEmpty == false)
    }
}
```

  Run:
```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SwiftDataModel
```
  Expected (FAIL → then PASS): Before Steps 6-19's files exist + `xcodegen generate`, the build fails (`cannot find type 'Profile' / 'Transaction' / 'OutboxMutation' / 'ModelContainer.makeSnapceiptContainer'`). After all model files are added and the project regenerated, all 5 cases PASS (the container builds, the profile-scoped fetch returns exactly the one transaction with its sync envelope intact, the tombstone persists, and the OutboxMutation round-trips).

- [ ] **Step 22: Full model-layer test sweep (all three suites green)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/IDClock -only-testing:SnapceiptTests/EntityType -only-testing:SnapceiptTests/SwiftDataModel
```
  Expected: PASS — `Test Suite 'IDClock'`, `'EntityType'`, and `'SwiftDataModel'` all report `passed`; the overall result is `** TEST SUCCEEDED **`. This confirms the model layer compiles, the schema is valid, sync fields persist, and the 12-case contract holds.

- [ ] **Step 23: Commit the model layer**

```bash
git add Snapceipt/Model SnapceiptTests/IDClockTests.swift SnapceiptTests/EntityTypeTests.swift SnapceiptTests/SwiftDataModelTests.swift project.yml
git commit -m "$(cat <<'EOF'
feat(ios): SwiftData model layer + sync envelope + outbox

Add ID.uuidv7()/Clock.nowMs(), the EntityType enum (12 syncable types,
camelCase matching the backend), the Syncable protocol + shared envelope,
the OutboxMutation queue model, the 11 domain @Model classes (Profile,
Transaction, LineItem, Category, Budget, LoyaltyCard, MileageTrip, WFHLog,
Quote, QuoteLineItem, TaxSettings) mirroring the D1 schema 1:1 with the
backend's exact camelCase field names, and ModelContainer.makeSnapceiptContainer
(inMemory:) over the full schema. Covered by in-memory SwiftData tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```
  Expected: a single commit containing the 16 model files, the 3 test files, and `project.yml`.

---

**Notes for downstream tasks (Sync):**
- The `@Model` property names are the backend camelCase contract verbatim (`catKey`, `amountCents`, `accent1/2/3`, `gstRegistered`, `lastEditedDeviceId`, etc.) so the DTO/`PushMutation.payload` mapping is a direct key copy — **except** `QuoteLineItem.itemDescription`, which maps to/from the backend key `"description"` (renamed to avoid clashing with `CustomStringConvertible`).
- `lineTotalCents` (QuoteLineItem) and `month_key` (Transaction) are **server-generated** columns: the model exposes `lineTotalCents` as a computed property and omits `monthKey` from Transaction entirely (derive `txnDate` prefix in queries) — neither is a writable sync field.
- `Syncable.entityType` gives the SyncEngine the per-row `EntityType` for routing without a type switch.


---

### Task 9: keychain-authstore

Implements the on-device secret store and the authentication state holder the whole sync stack depends on. `Sync/Keychain.swift` wraps the Security framework (`kSecClassGenericPassword`, service `"app.snapceipt"`, `kSecAttrAccessibleAfterFirstUnlock`) behind a tiny typed `KeychainKey` API. `Sync/AuthStore.swift` is the `@Observable` holder that owns the access + refresh tokens, exposes a `bearer()` header, persists a stable `deviceId` (UUIDv7) on first access, and maps the backend `SessionResponse` into a local `SessionState`.

The backend contract (from `/Users/yangqi/Documents/github/Snapceipt/docs/superpowers/plans/2026-05-30-backend-foundation.md`) is authoritative: a session body is `{ accessToken, refreshToken, expiresIn, user: { id, email, displayName } }` where `email` and `displayName` may be `null`. The deviceId is sent to the backend as the `X-Device-Id` header (registered on magic-link verify / apple sign-in). `expiresIn` is seconds (the backend returns `900`).

> Depends on: `ID.uuidv7()` (from `Snapceipt/Model/Syncable.swift`, the IDs/time task) and the `SessionResponse` / `SessionUser` DTOs (from `Snapceipt/Sync/DTOs.swift`, the DTO task). This task does NOT redefine either — it imports/consumes them. To keep this task independently buildable and testable when the DTO task lands later, Step 1 adds a guarded shim: if `Sync/DTOs.swift` does not yet exist, create it with ONLY the two `SessionResponse`/`SessionUser` structs (the DTO task fleshes the rest out around them); if it already exists, leave it untouched. The canonical `SessionResponse` field set is fixed by the SPINE.

**Files**
- Create: `Snapceipt/Sync/Keychain.swift`
- Create: `Snapceipt/Sync/AuthStore.swift`
- Create (only if absent — DTO shim): `Snapceipt/Sync/DTOs.swift`
- Modify: `project.yml` (no change needed if `Snapceipt/Sync/**` is already a source path; verify in Step 7)
- Test: `SnapceiptTests/KeychainTests.swift`
- Test: `SnapceiptTests/AuthStoreTests.swift`

---

- [ ] **Step 1: Ensure the `SessionResponse`/`SessionUser` DTOs exist (idempotent shim).**

Run this guard. It creates `Snapceipt/Sync/DTOs.swift` with ONLY the session structs if the file is missing, and prints a skip message if it already exists (so the DTO task's richer file is never clobbered).

```bash
DTO=/Users/yangqi/Documents/github/Snapceipt/Snapceipt/Sync/DTOs.swift
mkdir -p /Users/yangqi/Documents/github/Snapceipt/Snapceipt/Sync
if [ -f "$DTO" ]; then
  echo "DTOs.swift exists — leaving it to the DTO task."
else
  cat > "$DTO" <<'SWIFT'
import Foundation

/// Subset of the backend auth/session DTOs owned by this task as a shim.
/// The DTO task expands this file (push/pull/me) around these two types.
/// Contract (backend-foundation plan): a session body is
/// { accessToken, refreshToken, expiresIn, user: { id, email, displayName } }
/// where `email` and `displayName` may be null; `expiresIn` is seconds.

/// The signed-in user as returned by the backend.
struct SessionUser: Codable, Equatable, Sendable {
    let id: String
    let email: String?
    let displayName: String?
}

/// Response body of /auth/apple, /auth/magic-link/verify and /auth/refresh.
struct SessionResponse: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SessionUser
}
SWIFT
  echo "Created DTOs.swift shim."
fi
```

  Expected: prints either "Created DTOs.swift shim." or "DTOs.swift exists — leaving it to the DTO task." Either outcome is fine; this task only needs `SessionResponse` + `SessionUser` to be in the target.

- [ ] **Step 2: Write the FAILING Keychain test `SnapceiptTests/KeychainTests.swift`.**

This drives a real Keychain on the simulator: set/get/delete round-trip, overwrite (update path), missing-key returns nil, and isolation between keys. Each test uses a unique service so concurrent suites never collide, and cleans up after itself.

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("Keychain")
struct KeychainTests {
    /// A fresh, uniquely-namespaced Keychain per test so suites never collide,
    /// with all canonical keys cleared on entry.
    private func freshKeychain() -> Keychain {
        let kc = Keychain(service: "app.snapceipt.tests." + UUID().uuidString)
        for key in KeychainKey.allCases { kc.delete(key) }
        return kc
    }

    @Test("set then string round-trips the exact value")
    func setGetRoundTrip() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        #expect(kc.string(.accessToken) == nil)
        kc.set("acc-123", .accessToken)
        #expect(kc.string(.accessToken) == "acc-123")
    }

    @Test("set on an existing key overwrites (update path)")
    func setOverwrites() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("first", .refreshToken)
        kc.set("second", .refreshToken)
        #expect(kc.string(.refreshToken) == "second")
    }

    @Test("delete removes the value")
    func deleteRemoves() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("temp", .deviceId)
        #expect(kc.string(.deviceId) == "temp")
        kc.delete(.deviceId)
        #expect(kc.string(.deviceId) == nil)
    }

    @Test("delete on a missing key is a no-op (no crash)")
    func deleteMissingIsNoop() throws {
        let kc = freshKeychain()
        kc.delete(.accessToken)
        #expect(kc.string(.accessToken) == nil)
    }

    @Test("keys are isolated from one another")
    func keysAreIsolated() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("A", .accessToken)
        kc.set("B", .refreshToken)
        #expect(kc.string(.accessToken) == "A")
        #expect(kc.string(.refreshToken) == "B")
        #expect(kc.string(.deviceId) == nil)
    }

    @Test("values survive within the same store instance (read-after-write)")
    func persistsWithinStore() throws {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        kc.set("persisted-value", .refreshToken)
        let again = Keychain(service: kc.service) // a new wrapper over the same service
        #expect(again.string(.refreshToken) == "persisted-value")
    }
}
```

- [ ] **Step 3: Run the Keychain test — expect FAIL.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Keychain
```

  Expected (FAIL): compilation fails — `Keychain`, `KeychainKey`, and the `service`/`string`/`set`/`delete` members do not exist yet (errors like `cannot find 'Keychain' in scope`, `cannot find 'KeychainKey' in scope`). This proves the test exercises the not-yet-written API.

- [ ] **Step 4: Implement `Snapceipt/Sync/Keychain.swift`.**

Generic-password items keyed by `(kSecAttrService, kSecAttrAccount)`. `set` tries `SecItemAdd` and, on `errSecDuplicateItem`, falls back to `SecItemUpdate` so it is an upsert. All items use `kSecAttrAccessibleAfterFirstUnlock` (works for background sync). The default service is `"app.snapceipt"`; tests inject a unique one.

```swift
import Foundation
import Security

/// The three secrets Snapceipt persists in the iOS Keychain.
/// `rawValue` is the `kSecAttrAccount` for each generic-password item.
enum KeychainKey: String, CaseIterable, Sendable {
    case accessToken
    case refreshToken
    case deviceId
}

/// Thin, typed wrapper over the Security framework's generic-password items.
/// Items use service "app.snapceipt" and kSecAttrAccessibleAfterFirstUnlock so
/// the app can read tokens during background sync after the first unlock.
struct Keychain: Sendable {
    /// kSecAttrService for all items. Default is the app's bundle-style id;
    /// tests inject a unique value to stay isolated.
    let service: String

    init(service: String = "app.snapceipt") {
        self.service = service
    }

    /// Read a stored UTF-8 string for `key`, or nil if absent / unreadable.
    func string(_ key: KeychainKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Upsert a UTF-8 string under `key` (add, or update if it already exists).
    func set(_ value: String, _ key: KeychainKey) {
        let data = Data(value.utf8)

        var addQuery = baseQuery(key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Item exists — update just its data.
            let update: [String: Any] = [kSecValueData as String: data]
            SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        }
    }

    /// Remove the value under `key`. Missing item is treated as success (no-op).
    func delete(_ key: KeychainKey) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    /// The class/service/account selector shared by every operation.
    private func baseQuery(_ key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
```

- [ ] **Step 5: Run the Keychain test — expect PASS.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Keychain
```

  Expected (PASS): the `Keychain` suite is green — all 6 tests pass (`** TEST SUCCEEDED **`). Set/get round-trips, overwrite updates in place, delete clears, missing-key reads are nil, keys are isolated, and a second wrapper over the same service reads the persisted value.

- [ ] **Step 6: Write the FAILING AuthStore test `SnapceiptTests/AuthStoreTests.swift`.**

Covers: `bearer()` is nil before save; `save(_:)` persists access+refresh into the Keychain and `bearer()` returns `"Bearer <access>"`; `session` reflects the user (incl. nullable email/displayName); `clear()` empties tokens + session; and the deviceId is generated once (UUIDv7-shaped) and is stable across `AuthStore` instances that share a Keychain.

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("AuthStore")
struct AuthStoreTests {
    /// A Keychain on a unique service with all keys cleared.
    private func freshKeychain() -> Keychain {
        let kc = Keychain(service: "app.snapceipt.tests." + UUID().uuidString)
        for key in KeychainKey.allCases { kc.delete(key) }
        return kc
    }

    private func session(access: String = "acc-tok", refresh: String = "ref-tok",
                         email: String? = "maya@example.com",
                         name: String? = "Maya Reyes") -> SessionResponse {
        SessionResponse(
            accessToken: access,
            refreshToken: refresh,
            expiresIn: 900,
            user: SessionUser(id: "u1", email: email, displayName: name)
        )
    }

    @Test("bearer() is nil before any session is saved")
    func bearerNilWhenSignedOut() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        #expect(store.bearer() == nil)
        #expect(store.session == nil)
    }

    @Test("save persists tokens to Keychain and exposes the session")
    func savePersistsTokensAndSession() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        store.save(session())

        #expect(store.bearer() == "Bearer acc-tok")
        #expect(kc.string(.accessToken) == "acc-tok")
        #expect(kc.string(.refreshToken) == "ref-tok")
        #expect(store.session?.userId == "u1")
        #expect(store.session?.email == "maya@example.com")
        #expect(store.session?.displayName == "Maya Reyes")
        #expect(store.session?.refreshToken == "ref-tok")
    }

    @Test("save tolerates null email and displayName")
    func saveWithNullProfileFields() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        store.save(session(email: nil, name: nil))
        #expect(store.session?.userId == "u1")
        #expect(store.session?.email == nil)
        #expect(store.session?.displayName == nil)
        #expect(store.bearer() == "Bearer acc-tok")
    }

    @Test("a new AuthStore over the same Keychain restores the session at init")
    func restoresSessionOnInit() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        AuthStore(keychain: kc).save(session(access: "live-acc", refresh: "live-ref"))

        let restored = AuthStore(keychain: kc)
        #expect(restored.bearer() == "Bearer live-acc")
        #expect(restored.session?.refreshToken == "live-ref")
        #expect(restored.session?.userId == "u1")
    }

    @Test("clear empties tokens, session and Keychain")
    func clearEmptiesEverything() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        store.save(session())

        store.clear()

        #expect(store.session == nil)
        #expect(store.bearer() == nil)
        #expect(kc.string(.accessToken) == nil)
        #expect(kc.string(.refreshToken) == nil)
    }

    @Test("clear preserves the deviceId (only the session is revoked locally)")
    func clearKeepsDeviceId() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)
        let device = store.deviceId
        store.save(session())

        store.clear()
        #expect(store.deviceId == device)
        #expect(kc.string(.deviceId) == device)
    }

    @Test("deviceId is generated once and is a UUIDv7-shaped string")
    func deviceIdShapeAndStability() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }
        let store = AuthStore(keychain: kc)

        let id = store.deviceId
        // RFC 9562 v7: version nibble 7, variant nibble 8/9/a/b.
        #expect(id.range(
            of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            options: [.regularExpression, .caseInsensitive]
        ) != nil)
        // Stable across repeated access on the same instance.
        #expect(store.deviceId == id)
    }

    @Test("deviceId is stable across AuthStore instances sharing a Keychain")
    func deviceIdStableAcrossInstances() {
        let kc = freshKeychain()
        defer { for k in KeychainKey.allCases { kc.delete(k) } }

        let first = AuthStore(keychain: kc).deviceId
        let second = AuthStore(keychain: kc).deviceId
        #expect(first == second)
        #expect(kc.string(.deviceId) == first)
    }
}
```

- [ ] **Step 7: Run the AuthStore test — expect FAIL (verify Sync sources are in the target first).**

First confirm `project.yml` includes `Snapceipt/Sync` in the app target's sources (the SPINE layout puts everything under `Snapceipt/` in the `Snapceipt` target). If your `project.yml` lists sources as the single path `Snapceipt`, no edit is needed. If it enumerates subfolders, ensure `Snapceipt/Sync` is present, then regenerate:

```bash
xcodegen generate --spec /Users/yangqi/Documents/github/Snapceipt/project.yml
```

  Then run:

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AuthStore
```

  Expected (FAIL): compilation fails — `AuthStore`, its `init(keychain:)`, `bearer()`, `save(_:)`, `clear()`, `session`, `deviceId`, and `SessionState` (`userId`/`email`/`displayName`/`refreshToken`) do not exist yet (`cannot find 'AuthStore' in scope`).

- [ ] **Step 8: Implement `Snapceipt/Sync/AuthStore.swift`.**

`SessionState` is the local, observable projection of a `SessionResponse` (it keeps the refresh token in memory for the refresh flow; the canonical copy lives in the Keychain). `deviceId` is lazily generated once via `ID.uuidv7()` and written to the Keychain on first access, so it is stable for the install's lifetime (and survives sign-out — only the session is cleared). On `init`, if both tokens + a cached user blob exist in the Keychain, the session is restored.

```swift
import Foundation
import Observation

/// Local, observable projection of the backend session. The access token is the
/// Bearer credential; the refresh token is kept here (and in the Keychain) for the
/// refresh-rotation flow. `email`/`displayName` may be nil (backend contract).
struct SessionState: Equatable, Sendable {
    var userId: String
    var email: String?
    var displayName: String?
    var accessToken: String
    var refreshToken: String
    /// Absolute expiry of the access token (epoch seconds), derived from expiresIn.
    var accessExpiresAt: TimeInterval
}

/// Owns auth state for the app: the active session, the stable per-install deviceId,
/// and the Keychain-backed persistence of access + refresh tokens. `@Observable` so
/// SwiftUI re-renders on sign-in/out. Injected into APIClient (Bearer) and SyncEngine.
@Observable
final class AuthStore {
    /// nil when signed out.
    private(set) var session: SessionState?

    @ObservationIgnored private let keychain: Keychain
    /// Backing store for the lazily-materialised deviceId.
    @ObservationIgnored private var cachedDeviceId: String?
    /// Account key under which the user identity blob is cached (alongside tokens),
    /// so the session can be restored on cold launch.
    @ObservationIgnored private let userBlobKey: KeychainKey = .accessToken

    init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
        restore()
    }

    /// Stable identifier for this install, generated once (UUIDv7) and persisted in
    /// the Keychain. Sent to the backend as the `X-Device-Id` header. Survives sign-out.
    var deviceId: String {
        if let cached = cachedDeviceId { return cached }
        if let existing = keychain.string(.deviceId) {
            cachedDeviceId = existing
            return existing
        }
        let fresh = ID.uuidv7()
        keychain.set(fresh, .deviceId)
        cachedDeviceId = fresh
        return fresh
    }

    /// The Authorization header value, or nil when signed out.
    func bearer() -> String? {
        guard let token = session?.accessToken else { return nil }
        return "Bearer \(token)"
    }

    /// Persist a fresh session from the backend: store tokens + a user blob in the
    /// Keychain and publish the in-memory `SessionState`.
    func save(_ s: SessionResponse) {
        let expiresAt = Date().timeIntervalSince1970 + TimeInterval(s.expiresIn)
        let state = SessionState(
            userId: s.user.id,
            email: s.user.email,
            displayName: s.user.displayName,
            accessToken: s.accessToken,
            refreshToken: s.refreshToken,
            accessExpiresAt: expiresAt
        )

        keychain.set(s.accessToken, .accessToken)
        keychain.set(s.refreshToken, .refreshToken)
        UserDefaults.standard.set(encodeUser(s.user), forKey: Self.userDefaultsUserKey)

        session = state
    }

    /// Sign out locally: drop the session and clear tokens. Keeps the deviceId so the
    /// same install re-registers as the same device on the next sign-in.
    func clear() {
        keychain.delete(.accessToken)
        keychain.delete(.refreshToken)
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsUserKey)
        session = nil
    }

    /// Rebuild `session` from the Keychain + cached user blob at launch, if present.
    private func restore() {
        guard let access = keychain.string(.accessToken),
              let refresh = keychain.string(.refreshToken),
              let user = decodeUser(UserDefaults.standard.string(forKey: Self.userDefaultsUserKey)) else {
            return
        }
        session = SessionState(
            userId: user.id,
            email: user.email,
            displayName: user.displayName,
            accessToken: access,
            refreshToken: refresh,
            // Unknown on cold restore; treat as already-expired so the next call refreshes.
            accessExpiresAt: 0
        )
    }

    // MARK: - User blob (de)serialization

    private static let userDefaultsUserKey = "sc.sessionUser"

    private func encodeUser(_ user: SessionUser) -> String {
        guard let data = try? JSONEncoder().encode(user) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeUser(_ raw: String?) -> SessionUser? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionUser.self, from: data)
    }
}
```

- [ ] **Step 9: Run the AuthStore test — expect PASS.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AuthStore
```

  Expected (PASS): the `AuthStore` suite is green (`** TEST SUCCEEDED **`). `bearer()` is nil signed-out and `"Bearer acc-tok"` after `save`; tokens land in the Keychain; the session restores on a new instance over the same Keychain; null email/displayName are tolerated; `clear()` empties tokens + session but keeps the deviceId; and the deviceId is a UUIDv7-shaped string that is stable across instances.

- [ ] **Step 10: Run both suites together to confirm no cross-suite interference.**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/Keychain -only-testing:SnapceiptTests/AuthStore
```

  Expected (PASS): both suites pass in one run (each uses a unique Keychain service, so they are isolated). Output ends with `** TEST SUCCEEDED **`.

- [ ] **Step 11: Commit the Keychain + AuthStore (and DTO shim if created).**

```bash
git -C /Users/yangqi/Documents/github/Snapceipt add Snapceipt/Sync/Keychain.swift Snapceipt/Sync/AuthStore.swift Snapceipt/Sync/DTOs.swift SnapceiptTests/KeychainTests.swift SnapceiptTests/AuthStoreTests.swift project.yml
git -C /Users/yangqi/Documents/github/Snapceipt commit -m "$(cat <<'EOF'
feat(ios): Keychain wrapper + observable AuthStore

Add Sync/Keychain.swift (typed KeychainKey + upsert/read/delete over
kSecClassGenericPassword, service "app.snapceipt",
kSecAttrAccessibleAfterFirstUnlock) and Sync/AuthStore.swift (@Observable
session state, save(SessionResponse) persisting access+refresh tokens,
bearer() -> "Bearer <access>", clear(), and a UUIDv7 deviceId generated
once and persisted in the Keychain, stable across instances and sign-out).
Seed the SessionResponse/SessionUser DTO shim if absent. Covered by
KeychainTests and AuthStoreTests on the iPhone 16 simulator.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

  Expected: a single `ios`-scoped commit with the two implementation files, the two test files, and (if newly created) the DTO shim + any `project.yml` change.


---

### Task 10: apiclient — Sync/DTOs.swift + Sync/APIClient.swift (LiveAPIClient over URLSession, error envelope, 401 auto-refresh)

Builds the network boundary the `SyncEngine` and `AuthViewModel` call. Defines the Codable DTOs that match the backend-foundation JSON contract **byte-for-byte** (`/auth/*` + `/sync/*`), the `APIClient` protocol (canonical signatures), and `LiveAPIClient` (URLSession + baseURL + `AuthStore` bearer, decoding the `{ error: { code, message, requestId } }` envelope into `APIError`, and transparently refreshing the access token once on a 401). TDD with a `URLProtocol` mock that returns canned JSON.

Contract facts pinned from `docs/superpowers/plans/2026-05-30-backend-foundation.md` (authoritative over the spec's `/v1/` prose): routes are mounted at root — `POST /auth/apple`, `POST /auth/magic-link/request` (→202), `POST /auth/magic-link/verify`, `POST /auth/refresh`, `POST /auth/signout`, `GET /auth/me`, `POST /sync/push`, `GET /sync/pull?cursor&limit`. Session bodies are `{ accessToken, refreshToken, expiresIn: 900, user: { id, email, displayName } }` (`email`/`displayName` nullable). `/auth/me` → `{ user, devices: [{ id, ... }] }`. The install/device id is sent as the `X-Device-Id` header. Push request `{ deviceId, mutations: [...] }`; push result `{ mutationId, status, reason?, entity? }` + `serverTime`. Pull response `{ changes: [envelope], nextCursor, hasMore, serverTime }`. Entity payloads/envelopes mix camelCase sync columns with snake_case domain columns, so payloads are carried as opaque JSON (no fixed `CodingKeys` strategy).

**Files**
- Create: `Snapceipt/Sync/DTOs.swift`
- Create: `Snapceipt/Sync/APIClient.swift`
- Test: `SnapceiptTests/APIClientTests.swift`
- Test: `SnapceiptTests/MockURLProtocol.swift`

> Depends on prior foundation tasks: `Snapceipt/Sync/Keychain.swift` (`Keychain`, `KeychainKey`), `Snapceipt/Sync/AuthStore.swift` (`@Observable AuthStore` with `func bearer() -> String?`, `var deviceId: String`, `func save(_:)`, `func clear()`), `Snapceipt/Model/Syncable.swift` (`EntityType`), and `Snapceipt/Model/ModelContainer+Snapceipt.swift` helpers (`ID.uuidv7()`, `Clock.nowMs()`). This task does NOT redefine those.

---

- [ ] **Step 1: Create the `URLProtocol` stub test helper `SnapceiptTests/MockURLProtocol.swift`**

  This is a test-only intercept registered on an ephemeral `URLSessionConfiguration` so `LiveAPIClient` makes no real network calls. A per-test closure (`requestHandler`) returns the canned `(HTTPURLResponse, Data)` for each request, and `lastRequest` captures the outgoing request (so we can assert the `Authorization` / `X-Device-Id` headers). Access to the statics is funnelled through a lock so it is safe even if the suite is not serialized.

```swift
import Foundation

/// Test-only URLProtocol that returns canned responses and captures the last request.
/// Register it on a URLSessionConfiguration via `protocolClasses = [MockURLProtocol.self]`.
final class MockURLProtocol: URLProtocol {
    /// Per-test handler: given the outgoing request, return the status + headers + body to reply with.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (Int, [String: String], Data))?
    /// The most recent intercepted request (read its headers/body/url in assertions).
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private static let lock = NSLock()

    /// Install a handler + clear the captured request. Call at the top of each test.
    static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) {
        lock.lock(); defer { lock.unlock() }
        requestHandler = handler
        lastRequest = nil
    }

    /// Build a URLSession whose only protocol is this mock.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.lastRequest = request
        let handler = MockURLProtocol.requestHandler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test `SnapceiptTests/APIClientTests.swift`**

  The suite is `.serialized` because `MockURLProtocol` uses static state. Each test installs a fresh handler. `LiveAPIClient` is constructed with the injected mock session + a real `AuthStore` backed by the real Keychain (on the simulator). Covers: `magicLinkVerify` decodes a `SessionResponse`; a 401 error body decodes into `APIError` with `code`; `syncPull` decodes `changes` + `nextCursor`; the `Authorization` bearer + `X-Device-Id` headers are attached.

```swift
import Foundation
import Testing
@testable import Snapceipt

@Suite(.serialized)
struct APIClientTests {
    /// A fresh AuthStore + LiveAPIClient over the mock session, with a known seeded session.
    private func makeClient(seedBearer: String? = "seed-access-token") -> (LiveAPIClient, AuthStore) {
        let auth = AuthStore()
        auth.clear()
        if let seedBearer {
            auth.save(SessionResponse(
                accessToken: seedBearer,
                refreshToken: "seed-refresh-token",
                expiresIn: 900,
                user: SessionUser(id: "u1", email: "a@b.com", displayName: "Ada")
            ))
        }
        let client = LiveAPIClient(
            baseURL: URL(string: "https://api.test")!,
            auth: auth,
            session: MockURLProtocol.makeSession()
        )
        return (client, auth)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    @Test("magicLinkVerify decodes a SessionResponse")
    func magicLinkVerifyDecodes() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, ["Content-Type": "application/json"], self.json("""
            {"accessToken":"acc.jwt.tok","refreshToken":"refresh-0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u1","email":"a@b.com","displayName":"Ada"}}
            """))
        }
        let session = try await client.magicLinkVerify(token: "magic-token")
        #expect(session.accessToken == "acc.jwt.tok")
        #expect(session.expiresIn == 900)
        #expect(session.user.id == "u1")
        #expect(session.user.email == "a@b.com")
        #expect(session.user.displayName == "Ada")
        // verify hit the right path/method
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/magic-link/verify")
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test("SessionResponse tolerates null email/displayName")
    func sessionNullableUser() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"accessToken":"a","refreshToken":"r0123456789abcdef0123456789abcdef","expiresIn":900,
             "user":{"id":"u9","email":null,"displayName":null}}
            """))
        }
        let session = try await client.magicLinkVerify(token: "t")
        #expect(session.user.email == nil)
        #expect(session.user.displayName == nil)
    }

    @Test("an error body decodes into APIError with the backend code + status")
    func errorEnvelopeDecodes() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (404, [:], self.json("""
            {"error":{"code":"NOT_FOUND","message":"missing","requestId":"req-123"}}
            """))
        }
        await #expect(throws: APIError.self) {
            _ = try await client.me()
        }
        do {
            _ = try await client.me()
            Issue.record("expected APIError")
        } catch let e as APIError {
            #expect(e.code == "NOT_FOUND")
            #expect(e.message == "missing")
            #expect(e.status == 404)
        }
    }

    @Test("syncPull decodes changes + nextCursor + hasMore + serverTime")
    func syncPullDecodes() async throws {
        let (client, _) = makeClient()
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"changes":[
               {"type":"transaction","id":"t1","userId":"u1","profileId":"p1","createdAt":10,"updatedAt":20,
                "deletedAt":null,"rev":1,"lastEditedDeviceId":"d1","merchant":"The Grounds","amount_cents":-1250},
               {"type":"profile","id":"p1","userId":"u1","createdAt":1,"updatedAt":2,
                "deletedAt":null,"rev":1,"lastEditedDeviceId":null,"name":"Personal"}
             ],
             "nextCursor":"eyJ0cyI6MjAsImlkIjoidDEifQ","hasMore":false,"serverTime":99999}
            """))
        }
        let pull = try await client.syncPull(cursor: nil, limit: 500)
        #expect(pull.changes.count == 2)
        #expect(pull.nextCursor == "eyJ0cyI6MjAsImlkIjoidDEifQ")
        #expect(pull.hasMore == false)
        #expect(pull.serverTime == 99999)
        // the raw envelope keeps both camelCase + snake_case fields accessible
        #expect(pull.changes[0].type == "transaction")
        #expect(pull.changes[0].id == "t1")
        #expect(pull.changes[0].updatedAt == 20)
        #expect(pull.changes[0].deletedAt == nil)
        #expect(pull.changes[0].string("merchant") == "The Grounds")
        #expect(pull.changes[0].int("amount_cents") == -1250)
        // query string carries the limit
        let q = MockURLProtocol.lastRequest?.url?.query ?? ""
        #expect(q.contains("limit=500"))
    }

    @Test("authenticated requests attach the Bearer + X-Device-Id headers")
    func attachesAuthHeaders() async throws {
        let (client, auth) = makeClient(seedBearer: "the-access-token")
        MockURLProtocol.setHandler { _ in
            (200, [:], self.json("""
            {"user":{"id":"u1","email":"a@b.com","displayName":"Ada"},"devices":[{"id":"d1"}]}
            """))
        }
        let me = try await client.me()
        #expect(me.user.id == "u1")
        #expect(me.devices.count == 1)
        #expect(me.devices.first?.id == "d1")
        let req = MockURLProtocol.lastRequest
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer the-access-token")
        #expect(req?.value(forHTTPHeaderField: "X-Device-Id") == auth.deviceId)
    }

    @Test("a 401 triggers a single refresh then a retry with the new token")
    func autoRefreshOn401() async throws {
        let (client, auth) = makeClient(seedBearer: "stale-token")
        var phase = 0
        MockURLProtocol.setHandler { req in
            switch phase {
            case 0:
                // first /auth/me with the stale token -> 401
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token")
                phase = 1
                return (401, [:], self.json("""
                {"error":{"code":"AUTH_INVALID_TOKEN","message":"expired","requestId":"r1"}}
                """))
            case 1:
                // refresh call -> new session
                #expect(req.url?.path == "/auth/refresh")
                phase = 2
                return (200, [:], self.json("""
                {"accessToken":"fresh-token","refreshToken":"fresh-refresh-0123456789abcdef0123456789ab","expiresIn":900,
                 "user":{"id":"u1","email":"a@b.com","displayName":"Ada"}}
                """))
            default:
                // retried /auth/me with the refreshed token -> 200
                #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
                return (200, [:], self.json("""
                {"user":{"id":"u1","email":"a@b.com","displayName":"Ada"},"devices":[]}
                """))
            }
        }
        let me = try await client.me()
        #expect(me.user.id == "u1")
        #expect(auth.bearer() == "fresh-token")
        #expect(phase == 2)
    }

    @Test("magicLinkRequest sends the email and returns on 202")
    func magicLinkRequestSucceeds() async throws {
        let (client, _) = makeClient(seedBearer: nil)
        MockURLProtocol.setHandler { _ in (202, [:], Data()) }
        try await client.magicLinkRequest(email: "user@example.com")
        #expect(MockURLProtocol.lastRequest?.url?.path == "/auth/magic-link/request")
        let body = MockURLProtocol.lastRequest?.httpBodyData() ?? Data()
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(obj?["email"] as? String == "user@example.com")
    }
}

/// Test helper: URLProtocol strips httpBody into a stream, so read it back for assertions.
private extension URLRequest {
    func httpBodyData() -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

- [ ] **Step 3: Run the test and watch it FAIL (DTOs + LiveAPIClient do not exist yet)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/APIClientTests
```

  Expected (FAIL): the test target fails to **compile** — `Sync/DTOs.swift` and `Sync/APIClient.swift` are not yet created, so `SessionResponse`, `SessionUser`, `APIError`, `LiveAPIClient`, `MeResponse`, and the `.string(_:)`/`.int(_:)` accessors on a pull change are all unresolved. (Compile failure is the genuine red state.)

- [ ] **Step 4: Create `Snapceipt/Sync/DTOs.swift` — the Codable DTOs matching the backend JSON exactly**

  Entity payloads/envelopes carry a mix of camelCase sync columns and snake_case domain columns, so they are modelled as a `JSONValue`-backed wrapper (`PullChange`) that exposes the fixed sync fields plus typed accessors for arbitrary keys, instead of a brittle fixed struct. `AnyEncodable` lets `PushMutation.payload` carry an opaque already-encoded entity snapshot.

```swift
import Foundation

// MARK: - Error envelope

/// Decoded form of the backend error envelope: { error: { code, message, requestId } }.
struct ApiErrorEnvelope: Decodable {
    let error: ApiErrorBody
}

struct ApiErrorBody: Decodable {
    let code: String
    let message: String
    let requestId: String?
}

/// Thrown by `LiveAPIClient` for any non-2xx response (or a transport failure).
struct APIError: Error, Equatable {
    /// Backend error code, e.g. "AUTH_INVALID_TOKEN", "VALIDATION_FAILED", "NOT_FOUND".
    let code: String
    let message: String
    /// HTTP status (0 for a transport-level failure with no response).
    let status: Int

    static let transport = APIError(code: "TRANSPORT", message: "Network request failed", status: 0)
    static let decoding = APIError(code: "DECODING", message: "Could not decode the server response", status: 0)
}

// MARK: - Auth request bodies

/// POST /auth/apple — client-collected identity proof. `fullName`/`email` only on first auth.
struct AppleAuthBody: Encodable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    var fullName: String?
    var email: String?
}

/// POST /auth/magic-link/request
struct MagicLinkRequestBody: Encodable {
    let email: String
}

/// POST /auth/magic-link/verify
struct MagicLinkVerifyBody: Encodable {
    let token: String
}

/// POST /auth/refresh
struct RefreshBody: Encodable {
    let refreshToken: String
}

// MARK: - Auth responses

/// Returned by /auth/apple, /auth/magic-link/verify, /auth/refresh.
/// { accessToken, refreshToken, expiresIn, user }
struct SessionResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SessionUser
}

/// The authed user; `email` and `displayName` are nullable in the backend.
struct SessionUser: Decodable {
    let id: String
    let email: String?
    let displayName: String?
}

/// GET /auth/me -> { user, devices }
struct MeResponse: Decodable {
    let user: SessionUser
    let devices: [DeviceDTO]
}

/// A registered device row (only `id` is contractually guaranteed this phase).
struct DeviceDTO: Decodable {
    let id: String
}

// MARK: - Sync push

/// One mutation in a /sync/push batch.
/// { mutationId, entityType, entityId, op, baseRev?, updatedAt, payload }
struct PushMutation: Encodable {
    let mutationId: String
    let entityType: String
    let entityId: String
    let op: String            // "upsert" | "delete"
    var baseRev: Int?
    let updatedAt: Int
    let payload: AnyEncodable // full entity snapshot (upsert) — opaque JSON
}

/// POST /sync/push body: { deviceId, mutations }.
struct PushBody: Encodable {
    let deviceId: String
    let mutations: [PushMutation]
}

/// One per-mutation result. { mutationId, status, reason?, entity? }
struct PushResult: Decodable {
    let mutationId: String
    let status: String        // "applied" | "conflict" | "duplicate" | "rejected"
    let reason: String?
    /// Server-canonical entity envelope (present on applied/conflict/duplicate).
    let entity: PullChange?
}

/// POST /sync/push response: { results, serverTime }.
struct PushResponse: Decodable {
    let results: [PushResult]
    let serverTime: Int
}

// MARK: - Sync pull

/// GET /sync/pull response: { changes, nextCursor, hasMore, serverTime }.
struct PullResponse: Decodable {
    let changes: [PullChange]
    let nextCursor: String?
    let hasMore: Bool
    let serverTime: Int
}

/// A single pulled entity envelope. Carries the fixed SPINE sync columns (camelCase)
/// plus arbitrary domain columns (snake_case + camelCase), kept as raw JSON so the
/// SyncEngine can map per entity type without a fixed struct per table.
struct PullChange: Decodable {
    let type: String
    let id: String
    let userId: String
    let profileId: String?
    let createdAt: Int
    let updatedAt: Int
    let deletedAt: Int?
    let rev: Int
    let lastEditedDeviceId: String?
    /// Every field of the envelope, including the fixed ones above + all domain columns.
    let raw: [String: JSONValue]

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var dict: [String: JSONValue] = [:]
        for key in c.allKeys {
            dict[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        raw = dict
        type = dict["type"]?.stringValue ?? ""
        id = dict["id"]?.stringValue ?? ""
        userId = dict["userId"]?.stringValue ?? ""
        profileId = dict["profileId"]?.stringValue
        createdAt = dict["createdAt"]?.intValue ?? 0
        updatedAt = dict["updatedAt"]?.intValue ?? 0
        deletedAt = dict["deletedAt"]?.intValue
        rev = dict["rev"]?.intValue ?? 0
        lastEditedDeviceId = dict["lastEditedDeviceId"]?.stringValue
    }

    /// Typed accessor for an arbitrary domain column (string).
    func string(_ key: String) -> String? { raw[key]?.stringValue }
    /// Typed accessor for an arbitrary domain column (int).
    func int(_ key: String) -> Int? { raw[key]?.intValue }
    /// Typed accessor for an arbitrary domain column (double).
    func double(_ key: String) -> Double? { raw[key]?.doubleValue }
    /// Typed accessor for an arbitrary domain column (bool).
    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }
}

// MARK: - JSON helpers

/// A minimal JSON value used to carry heterogeneous entity payloads losslessly.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .null
    }

    var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    var doubleValue: Double? { if case let .number(n) = self { return n }; return nil }
    var intValue: Int? {
        if case let .number(n) = self { return Int(n) }
        return nil
    }
    var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
}

/// Type-erased Encodable so a PushMutation can carry an already-built entity snapshot.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) { encodeFn = wrapped.encode }
    /// Wrap a JSON-object dictionary (the usual case for an entity snapshot).
    init(_ dict: [String: AnyEncodable]) { encodeFn = { enc in try dict.encode(to: enc) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
```

- [ ] **Step 5: Create `Snapceipt/Sync/APIClient.swift` — the `APIClient` protocol + `LiveAPIClient`**

  `LiveAPIClient` uses an injectable `URLSession` (defaults to `.shared`; tests inject the mock), the `baseURL`, and the `AuthStore` for the bearer. A private `request` helper builds the URLRequest (JSON body, `Authorization`, `X-Device-Id`), decodes 2xx into the expected type, decodes the error envelope into `APIError` otherwise, and — for protected calls — auto-refreshes once on a 401 then retries.

```swift
import Foundation

/// Network boundary the SyncEngine + auth view-models depend on.
/// All methods are async-throwing; non-2xx responses surface as `APIError`.
protocol APIClient {
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse
    func magicLinkRequest(email: String) async throws
    func magicLinkVerify(token: String) async throws -> SessionResponse
    func refresh(refreshToken: String) async throws -> SessionResponse
    func signOut() async throws
    func me() async throws -> MeResponse
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse
}

/// URLSession-backed APIClient. Attaches the bearer + device id, decodes the backend
/// error envelope into `APIError`, and refreshes the access token once on a 401.
final class LiveAPIClient: APIClient {
    private let baseURL: URL
    private let auth: AuthStore
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL, auth: AuthStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: APIClient

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse {
        try await send("POST", "/auth/apple", body: body, authenticated: false)
    }

    func magicLinkRequest(email: String) async throws {
        try await sendNoContent("POST", "/auth/magic-link/request",
                                body: MagicLinkRequestBody(email: email), authenticated: false)
    }

    func magicLinkVerify(token: String) async throws -> SessionResponse {
        try await send("POST", "/auth/magic-link/verify",
                       body: MagicLinkVerifyBody(token: token), authenticated: false)
    }

    func refresh(refreshToken: String) async throws -> SessionResponse {
        try await send("POST", "/auth/refresh",
                       body: RefreshBody(refreshToken: refreshToken), authenticated: false)
    }

    func signOut() async throws {
        try await sendNoContent("POST", "/auth/signout", body: Optional<String>.none, authenticated: true)
    }

    func me() async throws -> MeResponse {
        try await send("GET", "/auth/me", body: Optional<String>.none, authenticated: true)
    }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        try await send("POST", "/sync/push",
                       body: PushBody(deviceId: deviceId, mutations: mutations), authenticated: true)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send("GET", "/sync/pull", query: items,
                              body: Optional<String>.none, authenticated: true)
    }

    // MARK: - Request plumbing

    /// Send a request and decode a JSON body into `T`.
    private func send<T: Decodable, B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: B?,
        authenticated: Bool
    ) async throws -> T {
        let data = try await perform(method, path, query: query, body: body,
                                     authenticated: authenticated, allowRefresh: authenticated)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    /// Send a request that has no useful response body (202/200 with empty/ignored body).
    private func sendNoContent<B: Encodable>(
        _ method: String,
        _ path: String,
        body: B?,
        authenticated: Bool
    ) async throws {
        _ = try await perform(method, path, query: [], body: body,
                              authenticated: authenticated, allowRefresh: authenticated)
    }

    /// Build + execute the request; on a 401 (when allowed) refresh once and retry.
    private func perform<B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: B?,
        authenticated: Bool,
        allowRefresh: Bool
    ) async throws -> Data {
        let request = try makeRequest(method, path, query: query, body: body, authenticated: authenticated)
        let (data, response) = try await dataResponse(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.transport }

        if http.statusCode == 401, allowRefresh, try await tryRefresh() {
            // Rebuild with the fresh bearer and retry exactly once.
            let retry = try makeRequest(method, path, query: query, body: body, authenticated: authenticated)
            let (data2, response2) = try await dataResponse(for: retry)
            guard let http2 = response2 as? HTTPURLResponse else { throw APIError.transport }
            return try validate(data2, http2)
        }
        return try validate(data, http)
    }

    /// Map a response to its body (2xx) or throw a decoded `APIError`.
    private func validate(_ data: Data, _ http: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(http.statusCode) { return data }
        if let envelope = try? decoder.decode(ApiErrorEnvelope.self, from: data) {
            throw APIError(code: envelope.error.code,
                           message: envelope.error.message,
                           status: http.statusCode)
        }
        throw APIError(code: "HTTP_\(http.statusCode)",
                       message: "Request failed",
                       status: http.statusCode)
    }

    /// Refresh the access token using the stored refresh token. Returns true if a new
    /// session was saved. Refresh failures (no token / 401) clear the session.
    private func tryRefresh() async -> Bool {
        guard let refreshToken = auth.session?.refreshToken else { return false }
        do {
            let req = try makeRequest("POST", "/auth/refresh", query: [],
                                      body: RefreshBody(refreshToken: refreshToken),
                                      authenticated: false)
            let (data, response) = try await dataResponse(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                auth.clear()
                return false
            }
            let session = try decoder.decode(SessionResponse.self, from: data)
            auth.save(session)
            return true
        } catch {
            auth.clear()
            return false
        }
    }

    /// Construct a URLRequest with JSON body + auth/device headers.
    private func makeRequest<B: Encodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: B?,
        authenticated: Bool
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.transport }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(auth.deviceId, forHTTPHeaderField: "X-Device-Id")
        if authenticated, let bearer = auth.bearer() {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body, !(body is _NoBody) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    /// `URLSession.data(for:)` shim — explicit so tests using a mock URLProtocol work.
    private func dataResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw APIError.transport
        }
    }
}

/// Sentinel for "no body" so `Optional<String>.none` does not serialize a JSON `null`.
private protocol _NoBody {}
extension Optional: _NoBody where Wrapped == String {}
```

- [ ] **Step 6: Run the test and watch it PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/APIClientTests
```

  Expected (PASS): all `APIClientTests` cases pass — `magicLinkVerify`/null-user decode a `SessionResponse`; the 404 body decodes into `APIError(code: "NOT_FOUND", status: 404)`; `syncPull` decodes `changes`/`nextCursor`/`hasMore`/`serverTime` and the per-row `string`/`int` accessors read domain columns; `me()` attaches `Authorization: Bearer ...` + `X-Device-Id`; the 401 path refreshes once and retries with `fresh-token`; `magicLinkRequest` posts `{ "email": ... }` and returns on 202. (`** TEST SUCCEEDED **`.)

- [ ] **Step 7: Whole-target build verify (ensures DTOs/APIClient compile into the app target, not just tests)**

```bash
xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

  Expected: `** BUILD SUCCEEDED **` — `Sync/DTOs.swift` + `Sync/APIClient.swift` compile against the existing `AuthStore`/`Keychain` types with no errors.

- [ ] **Step 8: Commit the test + implementation together**

```bash
git add Snapceipt/Sync/DTOs.swift Snapceipt/Sync/APIClient.swift SnapceiptTests/APIClientTests.swift SnapceiptTests/MockURLProtocol.swift && git commit -m "$(cat <<'EOF'
feat(ios): add Sync DTOs + LiveAPIClient (auth/sync over URLSession)

Add Codable DTOs matching the backend-foundation JSON contract exactly
(AppleAuthBody, SessionResponse/SessionUser, MeResponse/DeviceDTO,
PushMutation/PushBody/PushResponse, PullResponse/PullChange, the
{error:{code,message,requestId}} envelope) plus the APIClient protocol
and LiveAPIClient: URLSession + baseURL + AuthStore bearer, X-Device-Id
header, error-envelope -> APIError decoding, and single auto-refresh on
401. Covered by APIClientTests via a URLProtocol stub (canned JSON):
magic-link verify decode, 401 envelope -> APIError, sync pull decode,
auth header attach, and the refresh-and-retry path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

  Expected: a single commit containing the two `Sync/` files and the two test files.

**Notes / contract anchors**
- Endpoint paths are taken from the backend-foundation plan's actually-mounted routes (root-mounted, e.g. `/auth/magic-link/verify`, `/sync/pull`), which is authoritative over the spec §5.1 `/v1/` prose. If a later API-gateway task adds a `/v1` base path on the Worker, change only `baseURL` (e.g. `https://api.snapceipt.app/v1`) — no DTO/route-string changes needed.
- `signOut()` posts to `/auth/signout` (matching the backend's `POST /auth/signout`).
- `PullChange.raw` preserves the full envelope (camelCase sync columns + snake_case domain columns) so the `SyncEngine` (separate task) can map each `EntityType` without a per-table Decodable; `string/int/double/bool` are the typed accessors it uses.
- `PushMutation.payload: AnyEncodable` lets the `SyncEngine` build an entity snapshot dictionary at enqueue/push time without this task owning the per-entity encoding.
- The 401 auto-refresh is guarded by `allowRefresh` (only authenticated calls) and runs at most once per request; on refresh failure the `AuthStore` session is cleared so the app routes back to Sign-in.



---

### Task 11: SyncEngine + Reachability (offline outbox drain, LWW pull, conflict overwrite)

Builds the local-first sync brain: `Sync/Reachability.swift` (an `@Observable` `NWPathMonitor` wrapper exposing `isOnline`, updated on the MainActor) and `Sync/SyncEngine.swift` (the `@Observable` engine that owns `status`, `enqueue(op:entityType:entity:)`, `push()`, `pull()`, `sync()`). `push()` drains `pending` `OutboxMutation` rows via `api.syncPush` in batches (≤200) and, per server result, deletes the outbox row + writes back the server `rev`/`updatedAt` on `applied`/`duplicate`, overwrites local + toasts "Updated on another device" on `conflict`, and marks `failed` on `rejected`. `pull()` loops `api.syncPull` from the persisted cursor (`UserDefaults` key `sc.syncCursor`), applies each change with LWW (newer `updatedAt` wins, but keep-local when a `pending`/`inflight` outbox row exists for that id), deletes locally on a tombstone (`deletedAt != nil`), and persists `nextCursor` after each page. `sync()` = `push()` then `pull()`. A `SyncEntityRegistry` maps each `EntityType` to upsert/tombstone/stamp closures over its `@Model` row so the engine stays generic. Matches the backend `/sync/push|pull` JSON contract verbatim (`results[].{mutationId,status,reason?,entity}` + `{changes,nextCursor,hasMore,serverTime}`).

This task **consumes** types owned by earlier tasks and does not redefine them: `APIClient` + the DTOs (`PushMutation`, `PushResponse`/`PushResult`, `PullResponse`/`PullChange`, `PullChange`) from `Sync/APIClient.swift` + `Sync/DTOs.swift`; `OutboxMutation`, `Syncable`, `EntityType`, `ID`, `Clock` from `Model/`; `AuthStore` from `Sync/AuthStore.swift`; `ToastCenter`/`ToastKind` from `Shared/Toast.swift`; the in-memory container helper from `Model/ModelContainer+Snapceipt.swift`; and the `Transaction`/`Profile` `@Model` types from `Model/Entities/`.

> Backend contract (verbatim, from `/Users/yangqi/Documents/github/Snapceipt/docs/superpowers/plans/2026-05-30-backend-foundation.md`):
> `POST /sync/push` → `{ results: [{ mutationId, status: "applied"|"conflict"|"duplicate"|"rejected", reason?, entity }], serverTime }`. The echoed `entity` is the camelCase envelope `{ type, id, userId, rev, createdAt, updatedAt, deletedAt, lastEditedDeviceId, profileId?, ... }`.
> `GET /sync/pull?cursor&limit=500` → `{ changes: [envelope], nextCursor, hasMore, serverTime }`, envelopes globally ordered by `(updatedAt, id)`, tombstones included.

**Files**
- Create: `Snapceipt/Sync/Reachability.swift`
- Create: `Snapceipt/Sync/SyncEngine.swift`
- Test: `SnapceiptTests/SyncEngineTests.swift`

---

- [ ] **Step 1: Create `Sync/Reachability.swift` (NWPathMonitor → `@Observable isOnline`, MainActor-safe)**

`pathUpdateHandler` fires on a background queue, so the `@Observable` mutation is hopped onto the MainActor. `start()` is idempotent; the default init starts monitoring immediately so views can read `isOnline` right away.

```swift
import Foundation
import Network
import Observation

/// Observes the device's network path and publishes a single `isOnline` flag.
/// `NWPathMonitor` delivers updates on a background queue; we marshal each change
/// onto the MainActor so SwiftUI/`@Observable` consumers (OfflineBanner, SyncEngine)
/// observe it on the main thread.
@Observable
@MainActor
final class Reachability {
    /// True when the current path is `.satisfied`. Optimistically true until the
    /// first path update arrives, so first-launch sync is attempted.
    private(set) var isOnline: Bool = true

    @ObservationIgnored private let monitor: NWPathMonitor
    @ObservationIgnored private let queue = DispatchQueue(label: "sc.reachability")
    @ObservationIgnored private var started = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        start()
    }

    /// Begin monitoring. Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring (e.g. on teardown).
    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
```

- [ ] **Step 2: Write the FAILING test `SnapceiptTests/SyncEngineTests.swift` (MockAPIClient + in-memory ModelContext)**

Drives every SyncEngine behavior against an in-memory `ModelContainer` and a `MockAPIClient` (conforms to `APIClient`). It will FAIL because `SyncEngine` / `SyncStatus` do not exist yet (and `enqueue/push/pull` are unresolved). The mock returns scripted `PushResponse`/`PullResponse` values built from the canonical DTOs.

```swift
import Foundation
import SwiftData
import Testing
@testable import Snapceipt

// MARK: - Test doubles

/// In-memory APIClient stub. Auth calls are unused by SyncEngine tests, so they
/// throw; only syncPush/syncPull are scripted per test.
@MainActor
final class MockAPIClient: APIClient {
    var pushHandler: (([PushMutation]) -> PushResponse)?
    var pullPages: [PullResponse] = []
    private(set) var pushCalls: [[PushMutation]] = []
    private(set) var pullCursors: [String?] = []

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse { throw CancellationError() }
    func magicLinkRequest(email: String) async throws { throw CancellationError() }
    func magicLinkVerify(token: String) async throws -> SessionResponse { throw CancellationError() }
    func refresh(refreshToken: String) async throws -> SessionResponse { throw CancellationError() }
    func signOut() async throws {}
    func me() async throws -> MeResponse { throw CancellationError() }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        pushCalls.append(mutations)
        guard let h = pushHandler else { return PushResponse(results: [], serverTime: 0) }
        return h(mutations)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        pullCursors.append(cursor)
        guard !pullPages.isEmpty else {
            return PullResponse(changes: [], nextCursor: cursor ?? "", hasMore: false, serverTime: 0)
        }
        return pullPages.removeFirst()
    }
}

// MARK: - Helpers

@MainActor
private func makeEngine() throws -> (SyncEngine, ModelContext, MockAPIClient, AuthStore, ToastCenter) {
    let container = try ModelContainer.inMemory()
    let context = ModelContext(container)
    let api = MockAPIClient()
    let auth = AuthStore()                       // device id auto-generated in Keychain
    let toast = ToastCenter()
    let engine = SyncEngine(api: api, context: context, auth: auth, toast: toast)
    UserDefaults.standard.removeObject(forKey: "sc.syncCursor")
    return (engine, context, api, auth, toast)
}

private func envelope(
    type: String, id: String, userId: String = "u1",
    rev: Int, updatedAt: Int, deletedAt: Int? = nil,
    extra: [String: AnyCodable] = [:]
) -> PullChange {
    var fields: [String: AnyCodable] = [
        "type": AnyCodable(type),
        "id": AnyCodable(id),
        "userId": AnyCodable(userId),
        "rev": AnyCodable(rev),
        "createdAt": AnyCodable(updatedAt),
        "updatedAt": AnyCodable(updatedAt),
        "deletedAt": deletedAt.map(AnyCodable.init) ?? AnyCodable(Optional<Int>.none),
        "lastEditedDeviceId": AnyCodable(Optional<String>.none),
    ]
    for (k, v) in extra { fields[k] = v }
    return PullChange(fields: fields)
}

// MARK: - Tests

@MainActor
@Suite struct SyncEngineTests {

    @Test func enqueueCreatesPendingOutboxRowWithPayload() throws {
        let (engine, context, _, auth, _) = try makeEngine()
        let txn = Transaction(userId: auth.deviceId == "" ? "u1" : "u1")
        txn.merchant = "The Grounds"
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "pending")
        #expect(outbox[0].op == "upsert")
        #expect(outbox[0].entityType == EntityType.transaction.rawValue)
        #expect(outbox[0].entityId == txn.id)
        #expect(outbox[0].payloadJSON.contains("The Grounds"))
    }

    @Test func pushAppliedRemovesOutboxAndBumpsRev() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = Transaction(userId: "u1")
        txn.rev = 0
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            let entity = envelope(type: "transaction", id: muts[0].entityId, rev: 1, updatedAt: 9999)
            return PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "applied", reason: nil, entity: entity)],
                serverTime: 9999
            )
        }
        await engine.push()

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(txn.rev == 1)
        #expect(txn.updatedAt == 9999)
    }

    @Test func pushConflictOverwritesLocalAndToasts() async throws {
        let (engine, context, api, _, toast) = try makeEngine()
        let txn = Transaction(userId: "u1")
        txn.merchant = "Mine"
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            let entity = envelope(
                type: "transaction", id: muts[0].entityId, rev: 5, updatedAt: 8888,
                extra: ["merchant": AnyCodable("Server Wins")]
            )
            return PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "conflict", reason: nil, entity: entity)],
                serverTime: 8888
            )
        }
        await engine.push()

        #expect(txn.merchant == "Server Wins")
        #expect(txn.rev == 5)
        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.isEmpty)
        #expect(toast.lastMessage == "Updated on another device")
    }

    @Test func pushRejectedMarksOutboxFailed() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = Transaction(userId: "u1")
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn)
        try context.save()

        api.pushHandler = { muts in
            PushResponse(
                results: [PushResult(mutationId: muts[0].mutationId, status: "rejected", reason: "FORBIDDEN", entity: nil)],
                serverTime: 1
            )
        }
        await engine.push()

        let outbox = try context.fetch(FetchDescriptor<OutboxMutation>())
        #expect(outbox.count == 1)
        #expect(outbox[0].status == "failed")
    }

    @Test func pullUpsertsNewEntity() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let id = ID.uuidv7()
        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 3, updatedAt: 7000,
                                   extra: ["merchant": AnyCodable("Pulled In")])],
                nextCursor: "CUR1", hasMore: false, serverTime: 7000
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].merchant == "Pulled In")
        #expect(rows[0].rev == 3)
        #expect(UserDefaults.standard.string(forKey: "sc.syncCursor") == "CUR1")
    }

    @Test func pullTombstoneDeletesLocal() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = Transaction(userId: "u1")
        txn.updatedAt = 100
        context.insert(txn)
        try context.save()
        let id = txn.id

        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 2, updatedAt: 200, deletedAt: 200)],
                nextCursor: "CUR2", hasMore: false, serverTime: 200
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.isEmpty)
    }

    @Test func pullKeepsLocalWhenPendingOutboxExists() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let txn = Transaction(userId: "u1")
        txn.merchant = "Local Edit"
        txn.updatedAt = 500
        context.insert(txn)
        engine.enqueue(op: "upsert", entityType: .transaction, entity: txn) // pending outbox row
        try context.save()
        let id = txn.id

        api.pullPages = [
            PullResponse(
                changes: [envelope(type: "transaction", id: id, rev: 9, updatedAt: 9000,
                                   extra: ["merchant": AnyCodable("Server Newer")])],
                nextCursor: "CUR3", hasMore: false, serverTime: 9000
            )
        ]
        await engine.pull()

        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id }))
        #expect(rows.count == 1)
        #expect(rows[0].merchant == "Local Edit") // kept local despite newer server change
    }

    @Test func pullLoopsPagesUntilHasMoreFalseAndPersistsLastCursor() async throws {
        let (engine, context, api, _, _) = try makeEngine()
        let idA = ID.uuidv7(), idB = ID.uuidv7()
        api.pullPages = [
            PullResponse(changes: [envelope(type: "transaction", id: idA, rev: 1, updatedAt: 1000)],
                         nextCursor: "P1", hasMore: true, serverTime: 1000),
            PullResponse(changes: [envelope(type: "transaction", id: idB, rev: 1, updatedAt: 2000)],
                         nextCursor: "P2", hasMore: false, serverTime: 2000),
        ]
        await engine.pull()

        #expect(api.pullCursors == [nil, "P1"]) // second page sent the first page's cursor
        #expect(UserDefaults.standard.string(forKey: "sc.syncCursor") == "P2")
        let rows = try context.fetch(FetchDescriptor<Transaction>())
        #expect(rows.count == 2)
    }
}
```

- [ ] **Step 3: Run the test and watch it FAIL (SyncEngine/SyncStatus do not exist)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SyncEngineTests
```

Expected (FAIL): compilation fails — `cannot find 'SyncEngine' in scope`, `cannot find type 'SyncStatus'`, and the unresolved `engine.enqueue/push/pull` calls. (`MockAPIClient`, the DTOs, `Transaction`, `OutboxMutation`, `ID`, `AuthStore`, `ToastCenter`, and `ModelContainer.inMemory()` already exist from earlier tasks, so those references resolve.)

- [ ] **Step 4: Implement `Sync/SyncEngine.swift` — `SyncStatus`, the entity registry, and the engine**

The registry maps each `EntityType` to closures that (a) find-or-create the `@Model` row by id, (b) apply a pulled `PullChange` onto it, (c) stamp server `rev`/`updatedAt`, (d) read `updatedAt`, and (e) delete it. The engine is `@MainActor` (same actor as `ModelContext` use in tests). Cursor lives in `UserDefaults("sc.syncCursor")`.

```swift
import Foundation
import SwiftData
import Observation

/// Coarse sync state surfaced to `SyncStatusView` / `OfflineBanner`.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case offline
    case error(String)
}

/// Per-entity-type glue so the generic engine can apply pulled envelopes and
/// stamp server revisions onto strongly-typed `@Model` rows.
struct SyncEntityHandler {
    /// Apply a pulled envelope: find-or-create the row by id, copy domain fields.
    let applyPulled: (_ context: ModelContext, _ env: PullChange) -> Void
    /// Local `updatedAt` for the row id, or nil if no local row exists.
    let localUpdatedAt: (_ context: ModelContext, _ id: String) -> Int?
    /// Delete the local row for the id (tombstone handling).
    let deleteLocal: (_ context: ModelContext, _ id: String) -> Void
    /// Overwrite the local row from a server entity (push conflict).
    let overwriteLocal: (_ context: ModelContext, _ env: PullChange) -> Void
    /// Stamp server rev + updatedAt onto the local row (push applied/duplicate).
    let stampServer: (_ context: ModelContext, _ id: String, _ rev: Int, _ updatedAt: Int) -> Void
}

/// Drains the offline outbox to the backend and reconciles server deltas into
/// the local SwiftData store, local-first and last-write-wins.
@Observable
@MainActor
final class SyncEngine {
    private(set) var status: SyncStatus = .idle

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let auth: AuthStore
    @ObservationIgnored private let toast: ToastCenter
    @ObservationIgnored private let registry = SyncEntityRegistry.shared

    @ObservationIgnored private let cursorKey = "sc.syncCursor"
    @ObservationIgnored private let pushBatchSize = 200
    @ObservationIgnored private let pullLimit = 500

    init(api: APIClient, context: ModelContext, auth: AuthStore, toast: ToastCenter) {
        self.api = api
        self.context = context
        self.auth = auth
        self.toast = toast
    }

    // MARK: enqueue

    /// Append an outbox mutation snapshotting `entity` (full payload for upsert,
    /// id-only semantics still carry the snapshot for delete) and mark it pending.
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        let payload = registry.encodePayload(entityType: entityType, entity: entity)
        let mutation = OutboxMutation(
            mutationId: ID.uuidv7(),
            entityType: entityType.rawValue,
            entityId: entity.id,
            op: op,
            payloadJSON: payload,
            baseRev: entity.rev,
            createdAt: Clock.nowMs(),
            attemptCount: 0,
            status: "pending"
        )
        context.insert(mutation)
        try? context.save()
    }

    // MARK: push

    /// Drain pending outbox rows in batches (≤200) and reconcile each result.
    func push() async {
        let pending = pendingOutbox()
        guard !pending.isEmpty else { return }
        status = .syncing
        let deviceId = auth.deviceId

        for batch in pending.chunked(into: pushBatchSize) {
            // Mark in-flight so a concurrent pull treats these ids as "keep local".
            for m in batch { m.status = "inflight"; m.attemptCount += 1 }
            try? context.save()

            let wire = batch.map { m in
                PushMutation(
                    mutationId: m.mutationId,
                    entityType: m.entityType,
                    entityId: m.entityId,
                    op: m.op,
                    baseRev: m.baseRev,
                    updatedAt: localUpdatedAt(for: m) ?? m.createdAt,
                    payload: registry.decodePayload(m.payloadJSON)
                )
            }

            do {
                let resp = try await api.syncPush(deviceId: deviceId, mutations: wire)
                applyPushResults(resp.results, batch: batch)
                try? context.save()
            } catch {
                // Network/transport failure: roll in-flight back to pending and stop.
                for m in batch where m.status == "inflight" { m.status = "pending" }
                try? context.save()
                status = .offline
                return
            }
        }
        status = .idle
    }

    private func applyPushResults(_ results: [PushResult], batch: [OutboxMutation]) {
        let byId = Dictionary(uniqueKeysWithValues: batch.map { ($0.mutationId, $0) })
        for r in results {
            guard let m = byId[r.mutationId] else { continue }
            guard let entityType = EntityType(rawValue: m.entityType),
                  let handler = registry.handler(for: entityType) else {
                context.delete(m); continue
            }
            switch r.status {
            case "applied", "duplicate":
                if let env = r.entity, let rev = env.intValue("rev"), let upd = env.intValue("updatedAt") {
                    handler.stampServer(context, m.entityId, rev, upd)
                }
                context.delete(m)
            case "conflict":
                if let env = r.entity {
                    handler.overwriteLocal(context, env)
                }
                context.delete(m)
                toast.show("Updated on another device", kind: .info)
            default: // "rejected" or unknown
                m.status = "failed"
            }
        }
    }

    // MARK: pull

    /// Loop `syncPull` from the persisted cursor until `hasMore == false`,
    /// applying LWW per change and persisting `nextCursor` after each page.
    func pull() async {
        status = .syncing
        var cursor = UserDefaults.standard.string(forKey: cursorKey)

        while true {
            let resp: PullResponse
            do {
                resp = try await api.syncPull(cursor: cursor, limit: pullLimit)
            } catch {
                status = .offline
                return
            }

            for change in resp.changes {
                applyPulled(change)
            }
            try? context.save()

            // Persist only after the page committed (crash-safe).
            UserDefaults.standard.set(resp.nextCursor, forKey: cursorKey)
            cursor = resp.nextCursor

            if !resp.hasMore { break }
        }
        status = .idle
    }

    private func applyPulled(_ env: PullChange) {
        guard let typeRaw = env.stringValue("type"),
              let entityType = EntityType(rawValue: typeRaw),
              let handler = registry.handler(for: entityType),
              let id = env.stringValue("id"),
              let incomingUpdatedAt = env.intValue("updatedAt") else { return }

        // Keep local if an unsynced (pending/inflight) outbox edit exists for this id.
        if hasUnsyncedOutbox(entityId: id) { return }

        // LWW: newer updatedAt wins over the local row.
        if let localUpd = handler.localUpdatedAt(context, id), localUpd >= incomingUpdatedAt {
            return
        }

        if env.intValue("deletedAt") != nil {
            handler.deleteLocal(context, id)
        } else {
            handler.applyPulled(context, env)
        }
    }

    // MARK: sync

    /// Full cycle: push local changes, then pull server deltas.
    func sync() async {
        await push()
        await pull()
    }

    // MARK: outbox queries

    private func pendingOutbox() -> [OutboxMutation] {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate { $0.status == "pending" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func hasUnsyncedOutbox(entityId: String) -> Bool {
        let descriptor = FetchDescriptor<OutboxMutation>(
            predicate: #Predicate {
                $0.entityId == entityId && ($0.status == "pending" || $0.status == "inflight")
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func localUpdatedAt(for m: OutboxMutation) -> Int? {
        guard let entityType = EntityType(rawValue: m.entityType),
              let handler = registry.handler(for: entityType) else { return nil }
        return handler.localUpdatedAt(context, m.entityId)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
```

- [ ] **Step 5: Add `SyncEntityRegistry` (entity-type → handler + payload codec) to `Sync/SyncEngine.swift`**

Appended to the same file. It owns one `SyncEntityHandler` per syncable `EntityType` and the payload encode/decode used by `enqueue`/`push`. Foundation entities exercised this phase are `transaction` and `profile`; the remaining 10 types are wired with the same generic envelope helpers so later phases extend the row-mapping closures rather than the engine. `applyDomainFields` copies the camelCase envelope fields onto a `Transaction`/`Profile` row.

```swift
import Foundation
import SwiftData

/// Single source of truth mapping `EntityType` → row glue + payload codec.
final class SyncEntityRegistry {
    static let shared = SyncEntityRegistry()

    private var handlers: [EntityType: SyncEntityHandler] = [:]

    private init() {
        register(.transaction, TransactionSyncMapper())
        register(.profile, ProfileSyncMapper())
        // Other syncable types (lineItem, category, smartRule, budget, loyaltyCard,
        // quote, quoteLineItem, mileageTrip, wfhLog, taxSettings) are wired as their
        // @Model rows land in later phases, reusing the same SyncEntityHandler shape.
    }

    private func register<M: SyncRowMapper>(_ type: EntityType, _ mapper: M) {
        handlers[type] = SyncEntityHandler(
            applyPulled: { ctx, env in mapper.upsert(ctx, env) },
            localUpdatedAt: { ctx, id in mapper.localUpdatedAt(ctx, id) },
            deleteLocal: { ctx, id in mapper.delete(ctx, id) },
            overwriteLocal: { ctx, env in mapper.upsert(ctx, env) },
            stampServer: { ctx, id, rev, upd in mapper.stamp(ctx, id, rev: rev, updatedAt: upd) }
        )
    }

    func handler(for type: EntityType) -> SyncEntityHandler? { handlers[type] }

    /// Snapshot a Syncable entity to a JSON payload string for the outbox.
    func encodePayload(entityType: EntityType, entity: any Syncable) -> String {
        let env = PullChange.from(type: entityType.rawValue, entity: entity)
        return env.jsonString()
    }

    /// Decode an outbox payload back into the wire `PullChange` for push.
    func decodePayload(_ json: String) -> PullChange {
        PullChange.fromJSON(json) ?? PullChange(fields: [:])
    }
}

/// Strongly-typed mapping between a syncable @Model row and the wire envelope.
protocol SyncRowMapper {
    func upsert(_ context: ModelContext, _ env: PullChange)
    func localUpdatedAt(_ context: ModelContext, _ id: String) -> Int?
    func delete(_ context: ModelContext, _ id: String)
    func stamp(_ context: ModelContext, _ id: String, rev: Int, updatedAt: Int)
}

// MARK: - Transaction mapper

private struct TransactionSyncMapper: SyncRowMapper {
    private func fetch(_ context: ModelContext, _ id: String) -> Transaction? {
        try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })).first
    }

    func upsert(_ context: ModelContext, _ env: PullChange) {
        guard let id = env.stringValue("id") else { return }
        let row = fetch(context, id) ?? {
            let t = Transaction(userId: env.stringValue("userId") ?? "")
            t.id = id
            context.insert(t)
            return t
        }()
        row.userId = env.stringValue("userId") ?? row.userId
        row.profileId = env.stringValue("profileId")
        row.rev = env.intValue("rev") ?? row.rev
        row.createdAt = env.intValue("createdAt") ?? row.createdAt
        row.updatedAt = env.intValue("updatedAt") ?? row.updatedAt
        row.deletedAt = env.intValue("deletedAt")
        row.lastEditedDeviceId = env.stringValue("lastEditedDeviceId")
        if let m = env.stringValue("merchant") { row.merchant = m }
        if let a = env.intValue("amountCents") { row.amountCents = a }
        if let d = env.stringValue("txnDate") { row.txnDate = d }
        if let c = env.stringValue("catKey") { row.catKey = c }
        if let mode = env.stringValue("mode") { row.mode = mode }
    }

    func localUpdatedAt(_ context: ModelContext, _ id: String) -> Int? { fetch(context, id)?.updatedAt }

    func delete(_ context: ModelContext, _ id: String) {
        if let row = fetch(context, id) { context.delete(row) }
    }

    func stamp(_ context: ModelContext, _ id: String, rev: Int, updatedAt: Int) {
        guard let row = fetch(context, id) else { return }
        row.rev = rev
        row.updatedAt = updatedAt
    }
}

// MARK: - Profile mapper

private struct ProfileSyncMapper: SyncRowMapper {
    private func fetch(_ context: ModelContext, _ id: String) -> Profile? {
        try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.id == id })).first
    }

    func upsert(_ context: ModelContext, _ env: PullChange) {
        guard let id = env.stringValue("id") else { return }
        let row = fetch(context, id) ?? {
            let p = Profile(userId: env.stringValue("userId") ?? "", name: env.stringValue("name") ?? "", type: env.stringValue("type") ?? "personal")
            p.id = id
            context.insert(p)
            return p
        }()
        row.userId = env.stringValue("userId") ?? row.userId
        row.rev = env.intValue("rev") ?? row.rev
        row.createdAt = env.intValue("createdAt") ?? row.createdAt
        row.updatedAt = env.intValue("updatedAt") ?? row.updatedAt
        row.deletedAt = env.intValue("deletedAt")
        row.lastEditedDeviceId = env.stringValue("lastEditedDeviceId")
        if let n = env.stringValue("name") { row.name = n }
        if let t = env.stringValue("type") { row.type = t }
    }

    func localUpdatedAt(_ context: ModelContext, _ id: String) -> Int? { fetch(context, id)?.updatedAt }

    func delete(_ context: ModelContext, _ id: String) {
        if let row = fetch(context, id) { context.delete(row) }
    }

    func stamp(_ context: ModelContext, _ id: String, rev: Int, updatedAt: Int) {
        guard let row = fetch(context, id) else { return }
        row.rev = rev
        row.updatedAt = updatedAt
    }
}
```

- [ ] **Step 6: Add the `PullChange` snapshot helpers used by the registry to `Sync/SyncEngine.swift`**

The canonical `PullChange` (a typed `Codable` wrapper over the camelCase wire fields) and `AnyCodable` are defined in `Sync/DTOs.swift` (earlier task). This step adds only the engine-side convenience accessors/constructors as an extension so the registry stays readable; if `DTOs.swift` already provides any of these members, delete the duplicate here and keep the DTO version (the names below are the canonical ones).

```swift
import Foundation

extension PullChange {
    /// String field accessor (nil if absent or not a string).
    func stringValue(_ key: String) -> String? { fields[key]?.value as? String }

    /// Int field accessor; tolerates JSON numbers decoded as Double.
    func intValue(_ key: String) -> Int? {
        switch fields[key]?.value {
        case let i as Int: return i
        case let d as Double: return Int(d)
        default: return nil
        }
    }

    /// Build a wire envelope from a local Syncable snapshot (camelCase keys).
    static func from(type: String, entity: any Syncable) -> PullChange {
        var fields: [String: AnyCodable] = [
            "type": AnyCodable(type),
            "id": AnyCodable(entity.id),
            "userId": AnyCodable(entity.userId),
            "rev": AnyCodable(entity.rev),
            "createdAt": AnyCodable(entity.createdAt),
            "updatedAt": AnyCodable(entity.updatedAt),
            "deletedAt": entity.deletedAt.map(AnyCodable.init) ?? AnyCodable(Optional<Int>.none),
            "lastEditedDeviceId": entity.lastEditedDeviceId.map(AnyCodable.init) ?? AnyCodable(Optional<String>.none),
        ]
        if let pid = entity.profileId { fields["profileId"] = AnyCodable(pid) }
        // Domain-specific fields are merged by the row mapper for richer payloads;
        // the sync columns above are sufficient for LWW + tombstone reconciliation.
        return PullChange(fields: fields)
    }

    /// Encode to a JSON string for the outbox payloadJSON column.
    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode from an outbox payloadJSON string.
    static func fromJSON(_ json: String) -> PullChange? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PullChange.self, from: data)
    }
}
```

- [ ] **Step 7: Run the SyncEngine test suite and watch it PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/SyncEngineTests
```

Expected (PASS): all 8 tests green — `enqueueCreatesPendingOutboxRowWithPayload`, `pushAppliedRemovesOutboxAndBumpsRev`, `pushConflictOverwritesLocalAndToasts`, `pushRejectedMarksOutboxFailed`, `pullUpsertsNewEntity`, `pullTombstoneDeletesLocal`, `pullKeepsLocalWhenPendingOutboxExists`, `pullLoopsPagesUntilHasMoreFalseAndPersistsLastCursor`. Output shows `Test Suite 'SyncEngineTests' passed` with `Executed 8 tests, with 0 failures`.

> If `PullChange.stringValue/intValue/from/jsonString/fromJSON` or `AnyCodable.init(_:)` collide with definitions already in `Sync/DTOs.swift`, the build will report "invalid redeclaration" — delete the duplicate from Step 6 (keep the DTO-owned canonical version) and re-run. Likewise if `PushResult.entity` / `PullChange` differ in name from the test's usage, align the test to the DTO names (this task consumes them; it does not own them).

- [ ] **Step 8: Regenerate the Xcode project so the two new files are in the target, then build**

The new files live under existing `Snapceipt/Sync/`, already globbed by `project.yml`; regenerate to pick them up, then do a full build to confirm nothing else regressed.

```bash
xcodegen generate --project /Users/yangqi/Documents/github/Snapceipt && xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

Expected (PASS): `Loaded project.yml`, `Created project at Snapceipt.xcodeproj`, then `** BUILD SUCCEEDED **`.

- [ ] **Step 9: Commit the engine, reachability, and tests**

```bash
git -C /Users/yangqi/Documents/github/Snapceipt add Snapceipt/Sync/Reachability.swift Snapceipt/Sync/SyncEngine.swift SnapceiptTests/SyncEngineTests.swift Snapceipt.xcodeproj
git -C /Users/yangqi/Documents/github/Snapceipt commit -m "$(cat <<'EOF'
feat(ios): SyncEngine + Reachability (offline outbox drain, LWW pull)

Add Reachability (NWPathMonitor -> @Observable isOnline, MainActor) and
SyncEngine: enqueue snapshots a pending OutboxMutation; push() drains
pending rows in <=200 batches via api.syncPush, on applied/duplicate
deletes the outbox row + writes back server rev/updatedAt, on conflict
overwrites local + toasts "Updated on another device", on rejected marks
failed; pull() loops api.syncPull from the persisted sc.syncCursor with
LWW (newer updatedAt wins, keep-local when a pending/inflight outbox row
exists), deletes locally on tombstones, persists nextCursor per page;
sync() = push then pull. SyncEntityRegistry maps EntityType -> row glue.
Covered by SnapceiptTests/SyncEngineTests (8 tests).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: a single `ios`-scoped commit containing `Sync/Reachability.swift`, `Sync/SyncEngine.swift`, `SyncEngineTests.swift`, and the regenerated `Snapceipt.xcodeproj`.

**Defines:** `Reachability`, `SyncStatus`, `SyncEngine`, `SyncEntityRegistry`, `SyncEntityHandler`, `SyncRowMapper` (+ private `TransactionSyncMapper`/`ProfileSyncMapper`).
**Consumes (owned by other tasks — import/extend, do not redefine):** `APIClient`, `PushMutation`, `PushResponse`, `PushResult`, `PullResponse`, `PullChange`, `AnyCodable`, `MeResponse`, `SessionResponse`, `AppleAuthBody` (`Sync/`); `OutboxMutation`, `Syncable`, `EntityType`, `ID`, `Clock` (`Model/`); `AuthStore` (`Sync/AuthStore.swift`); `ToastCenter`/`ToastKind` (`Shared/Toast.swift`); `ModelContainer.inMemory()` (`Model/ModelContainer+Snapceipt.swift`); `Transaction`, `Profile` (`Model/Entities/`).


---

### Task 12: auth-ui — AuthViewModel + Sign-in / Magic-link / Onboarding screens, deep-link wiring

Builds the first-run authentication surface on top of the already-landed `APIClient`, `AuthStore` (Task: sync-auth-store), `Router`, `ProfilesStore` + `AddProfileView`/`AddProfileViewModel` (Task: profiles), the `ToastCenter` (Task: shared), and the design system (Task: design-system). It adds:

- `Features/Auth/AuthViewModel.swift` — an `@Observable` state machine (`signedOut → requestingLink → awaitingLink → verifying → signedIn` / `.error`) that drives Sign in with Apple (`ASAuthorizationController` + cryptographic nonce → `api.authApple` → `AuthStore.save`), email magic-link request, magic-link token verification, deep-link parsing (`snapceipt://auth/verify?token=` and the Universal Link `https://snapceipt.app/auth/verify?token=`), resend, and sign-out.
- `Features/Auth/SignInView.swift` — Sign in with Apple button + "Continue with email" field → request.
- `Features/Auth/MagicLinkWaitView.swift` — "Check your email" + resend + expired/invalid error.
- `Features/Onboarding/OnboardingView.swift` + `Features/Onboarding/PermissionPrimingView.swift` — create the first profile (reuses `AddProfileView`), then prime Camera + Notifications with rationale and the real system permission requests.
- Modifies `App/SnapceiptApp.swift` + `App/RootView.swift` so the app routes: **no session → `SignInView`**; **session but no profile → `OnboardingView`**; **else → the tab shell** — and so the `onOpenURL` deep link reaches `AuthViewModel.handleDeepLink`.

Backend contract this matches EXACTLY (Task: backend-foundation): `POST /auth/apple { identityToken, authorizationCode, rawNonce, fullName?, email? }` and `POST /auth/magic-link/request { email }` (always 202) / `POST /auth/magic-link/verify { token }` → `SessionResponse { accessToken, refreshToken, expiresIn:900, user:{ id, email, displayName } }`. Spec §9 / §13: token model + same-device magic-link + persist Apple name/email on first authorization + Universal Link `https://snapceipt.app/auth/verify?token=…`.

> Web-verified (May 2026): Apple's `ASAuthorizationAppleIDProvider().createRequest()` takes `request.nonce = sha256(rawNonce)` while the **raw** nonce is sent to the server (server compares `sha256(rawNonce)` to the token's `nonce` claim); use `CryptoKit.SHA256` for the hex digest and `SecRandomCopyBytes` for the random nonce. Swift Testing uses `import Testing` + `@Suite`/`@Test` + `#expect`/`#require`; async tests are awaited automatically; SwiftData in-memory via `ModelContainer(for:…, configurations: ModelConfiguration(isStoredInMemoryOnly: true))`.

**Files**
- Create: `Snapceipt/Features/Auth/AuthViewModel.swift`
- Create: `Snapceipt/Features/Auth/SignInView.swift`
- Create: `Snapceipt/Features/Auth/MagicLinkWaitView.swift`
- Create: `Snapceipt/Features/Onboarding/OnboardingView.swift`
- Create: `Snapceipt/Features/Onboarding/PermissionPrimingView.swift`
- Modify: `Snapceipt/App/SnapceiptApp.swift` (inject `AuthViewModel`; `onOpenURL` → `handleDeepLink`)
- Modify: `Snapceipt/App/RootView.swift` (route signedOut → SignInView, no-profile → Onboarding, else shell)
- Test: `SnapceiptTests/AuthViewModelTests.swift`
- Test: `SnapceiptTests/MagicLinkParserTests.swift`
- Test: `SnapceiptTests/AppleNonceTests.swift`

---

- [ ] **Step 1: Write the FAILING deep-link parser test (`SnapceiptTests/MagicLinkParserTests.swift`)**

This is the smallest pure-logic unit. `MagicLinkParser.token(from:)` must extract the `token` query item from BOTH the custom-scheme deep link and the Universal Link, and return `nil` for anything that isn't an auth-verify URL.

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("MagicLinkParser")
struct MagicLinkParserTests {
    @Test("extracts token from the custom-scheme deep link")
    func customScheme() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token=abc123"))
        #expect(MagicLinkParser.token(from: url) == "abc123")
    }

    @Test("extracts token from the universal link path /auth/verify")
    func universalLink() throws {
        let url = try #require(URL(string: "https://snapceipt.app/auth/verify?token=xyz-789_QQ"))
        #expect(MagicLinkParser.token(from: url) == "xyz-789_QQ")
    }

    @Test("also accepts the backend /auth/magic universal-link path")
    func magicPath() throws {
        let url = try #require(URL(string: "https://snapceipt.app/auth/magic?token=tok42"))
        #expect(MagicLinkParser.token(from: url) == "tok42")
    }

    @Test("percent-decodes the token value")
    func percentDecoded() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token=a%2Bb%3Dc"))
        #expect(MagicLinkParser.token(from: url) == "a+b=c")
    }

    @Test("returns nil for an unrelated path")
    func unrelatedPath() throws {
        let url = try #require(URL(string: "https://snapceipt.app/blog?token=nope"))
        #expect(MagicLinkParser.token(from: url) == nil)
    }

    @Test("returns nil when the token query item is missing")
    func missingToken() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify"))
        #expect(MagicLinkParser.token(from: url) == nil)
    }

    @Test("returns nil for an empty token")
    func emptyToken() throws {
        let url = try #require(URL(string: "snapceipt://auth/verify?token="))
        #expect(MagicLinkParser.token(from: url) == nil)
    }
}
```

- [ ] **Step 2: Run the parser test — expect FAIL (symbol not found)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/MagicLinkParserTests
```

Expected: **FAIL** — compilation error `cannot find 'MagicLinkParser' in scope` (the type does not exist yet). This proves the test exercises real code.

- [ ] **Step 3: Write the FAILING Apple-nonce test (`SnapceiptTests/AppleNonceTests.swift`)**

```swift
import Testing
import Foundation
@testable import Snapceipt

@Suite("AppleNonce")
struct AppleNonceTests {
    @Test("make() returns a 32-char raw nonce from the allowed charset")
    func rawNonceShape() {
        let raw = AppleNonce.make()
        #expect(raw.count == 32)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        #expect(raw.allSatisfy { allowed.contains($0) })
    }

    @Test("make() returns unique values across calls")
    func rawNonceUnique() {
        var seen = Set<String>()
        for _ in 0..<500 { seen.insert(AppleNonce.make()) }
        #expect(seen.count == 500)
    }

    @Test("sha256 produces a stable 64-char lowercase hex digest")
    func sha256Stable() {
        // SHA-256 of the ASCII string "abc" is a well-known fixed vector.
        let digest = AppleNonce.sha256("abc")
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(digest.count == 64)
    }
}
```

- [ ] **Step 4: Run the nonce test — expect FAIL**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AppleNonceTests
```

Expected: **FAIL** — `cannot find 'AppleNonce' in scope`.

- [ ] **Step 5: Write the FAILING `AuthViewModel` state-machine test (`SnapceiptTests/AuthViewModelTests.swift`)**

Drives the magic-link flow + deep-link extraction against a `MockAPIClient` and a real `AuthStore`. The mock conforms to the canonical `APIClient` protocol (Task: sync) so the VM is exercised exactly as in production.

```swift
import Testing
import Foundation
@testable import Snapceipt

// In-memory mock of the canonical APIClient protocol (Task: sync).
@MainActor
final class MockAPIClient: APIClient {
    var requestedEmails: [String] = []
    var verifiedTokens: [String] = []
    var appleBodies: [AppleAuthBody] = []
    var verifyShouldFail = false
    var stubSession = SessionResponse(
        accessToken: "header.payload.sig",
        refreshToken: "refresh-token-value-0123456789abcdef",
        expiresIn: 900,
        user: .init(id: "u1", email: "maya@example.com", displayName: "Maya Reyes")
    )

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse {
        appleBodies.append(body)
        return stubSession
    }
    func magicLinkRequest(email: String) async throws {
        requestedEmails.append(email)
    }
    func magicLinkVerify(token: String) async throws -> SessionResponse {
        verifiedTokens.append(token)
        if verifyShouldFail {
            throw APIError(code: "AUTH_INVALID_TOKEN", message: "Invalid or expired magic link", status: 401)
        }
        return stubSession
    }
    func refresh(refreshToken: String) async throws -> SessionResponse { stubSession }
    func signOut() async throws {}
    func me() async throws -> MeResponse {
        MeResponse(user: .init(id: "u1", email: "maya@example.com", displayName: "Maya Reyes"), devices: [])
    }
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        PushResponse(results: [], serverTime: Clock.nowMs())
    }
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: Clock.nowMs())
    }
}

@MainActor
@Suite("AuthViewModel")
struct AuthViewModelTests {
    private func makeStore() -> AuthStore {
        // A throwaway Keychain service keeps test runs isolated from the real app keychain.
        let store = AuthStore(keychain: Keychain(service: "sc.test.\(UUID().uuidString)"))
        store.clear()
        return store
    }

    @Test("requestMagicLink moves to awaitingLink and calls the API once")
    func requestMovesToAwaiting() async {
        let api = MockAPIClient()
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)

        await vm.requestMagicLink(email: "  Maya@Example.com ")

        #expect(api.requestedEmails == ["maya@example.com"])  // normalized
        #expect(vm.state == .awaitingLink(email: "maya@example.com"))
        #expect(vm.pendingEmail == "maya@example.com")
    }

    @Test("requestMagicLink with an invalid email errors without calling the API")
    func requestInvalidEmail() async {
        let api = MockAPIClient()
        let vm = AuthViewModel(api: api, auth: makeStore())

        await vm.requestMagicLink(email: "not-an-email")

        #expect(api.requestedEmails.isEmpty)
        if case .error = vm.state { } else { Issue.record("expected .error, got \(vm.state)") }
    }

    @Test("verifyMagicLink success → signedIn and persists the session")
    func verifySuccess() async {
        let api = MockAPIClient()
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)

        await vm.verifyMagicLink(token: "good-token")

        #expect(api.verifiedTokens == ["good-token"])
        #expect(vm.state == .signedIn)
        #expect(store.session != nil)
        #expect(store.bearer() == "header.payload.sig")
    }

    @Test("verifyMagicLink 401 → error state, no session saved")
    func verifyExpired() async {
        let api = MockAPIClient()
        api.verifyShouldFail = true
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)

        await vm.verifyMagicLink(token: "expired")

        #expect(store.session == nil)
        if case .error(let msg) = vm.state {
            #expect(msg.isEmpty == false)
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    @Test("handleDeepLink extracts the token, drives verify, and signs in")
    func deepLinkVerifies() async throws {
        let api = MockAPIClient()
        let vm = AuthViewModel(api: api, auth: makeStore())
        let url = try #require(URL(string: "https://snapceipt.app/auth/verify?token=deep-tok"))

        await vm.handleDeepLink(url)

        #expect(api.verifiedTokens == ["deep-tok"])
        #expect(vm.state == .signedIn)
    }

    @Test("handleDeepLink ignores a non-auth URL")
    func deepLinkIgnored() async throws {
        let api = MockAPIClient()
        let vm = AuthViewModel(api: api, auth: makeStore())
        let url = try #require(URL(string: "https://snapceipt.app/help"))

        await vm.handleDeepLink(url)

        #expect(api.verifiedTokens.isEmpty)
        #expect(vm.state == .signedOut)
    }

    @Test("resendMagicLink re-requests the pending email")
    func resend() async {
        let api = MockAPIClient()
        let vm = AuthViewModel(api: api, auth: makeStore())
        await vm.requestMagicLink(email: "maya@example.com")

        await vm.resendMagicLink()

        #expect(api.requestedEmails == ["maya@example.com", "maya@example.com"])
        #expect(vm.state == .awaitingLink(email: "maya@example.com"))
    }

    @Test("signOut clears the session and returns to signedOut")
    func signOut() async {
        let api = MockAPIClient()
        let store = makeStore()
        let vm = AuthViewModel(api: api, auth: store)
        await vm.verifyMagicLink(token: "good-token")
        #expect(store.session != nil)

        await vm.signOut()

        #expect(store.session == nil)
        #expect(vm.state == .signedOut)
    }
}
```

- [ ] **Step 6: Run the AuthViewModel test — expect FAIL**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AuthViewModelTests
```

Expected: **FAIL** — `cannot find 'AuthViewModel' in scope` (and `MagicLinkParser`/`AppleNonce` if Steps 7–8 are not yet saved).

- [ ] **Step 7: Implement `Snapceipt/Features/Auth/AuthViewModel.swift`**

`AppleNonce` + `MagicLinkParser` are small dependency-free helpers (kept in this file so the whole auth flow is one unit). `AppleSignInCoordinator` bridges `ASAuthorizationController` delegate callbacks to an `async` result. Email normalization mirrors the backend's `normalizeEmail` (trim + lowercase). `verifyMagicLink` / `authApple` map `APIError` (or any failure) to a friendly `.error` message and never persist a partial session.

```swift
import Foundation
import Observation
import AuthenticationServices
import CryptoKit

// MARK: - Deep-link parsing

/// Extracts the magic-link `token` from a sign-in URL.
/// Accepts the custom scheme `snapceipt://auth/verify?token=…`, the canonical
/// Universal Link `https://snapceipt.app/auth/verify?token=…` (spec §9), and the
/// backend-emitted `https://snapceipt.app/auth/magic?token=…` link.
enum MagicLinkParser {
    static func token(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // The verify path is the last two path segments: ".../auth/verify" or ".../auth/magic".
        // For custom-scheme URLs ("snapceipt://auth/verify") the host is "auth" and path is "/verify".
        let segments = ([comps.host] + comps.path.split(separator: "/").map(String.init))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let tail = segments.suffix(2).map { $0.lowercased() }
        let isVerify = tail == ["auth", "verify"] || tail == ["auth", "magic"]
        guard isVerify else { return nil }

        guard let raw = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !raw.isEmpty else { return nil }
        return raw
    }
}

// MARK: - Sign in with Apple nonce

/// Cryptographic nonce for Sign in with Apple. The *raw* nonce is sent to the
/// server (which compares `sha256(rawNonce)` to the identity-token `nonce` claim);
/// the *hashed* nonce is set on the `ASAuthorizationAppleIDRequest`.
enum AppleNonce {
    static func make(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Apple authorization coordinator

/// Result handed back from the system Sign in with Apple sheet.
struct AppleSignInResult {
    let identityToken: String
    let authorizationCode: String
    let fullName: String?
    let email: String?
}

/// Bridges the delegate-based `ASAuthorizationController` API to async/await.
@MainActor
final class AppleSignInCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<AppleSignInResult, Error>?

    /// Presents the system sheet for the given hashed nonce and resumes with the
    /// identity token + authorization code (and name/email on first authorization).
    func start(hashedNonce: String) async throws -> AppleSignInResult {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = hashedNonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        defer { continuation = nil }
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8),
            let codeData = credential.authorizationCode,
            let authorizationCode = String(data: codeData, encoding: .utf8)
        else {
            continuation?.resume(throwing: AuthError.appleMissingToken)
            return
        }
        var fullName: String?
        if let name = credential.fullName {
            let parts = [name.givenName, name.familyName].compactMap { $0 }
            if !parts.isEmpty { fullName = parts.joined(separator: " ") }
        }
        continuation?.resume(returning: AppleSignInResult(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            fullName: fullName,
            email: credential.email
        ))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
        if let window = scenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        return ASPresentationAnchor()
    }
}

enum AuthError: Error { case appleMissingToken, appleCancelled }

// MARK: - AuthViewModel

@MainActor
@Observable
final class AuthViewModel {
    /// First-run / sign-in state machine.
    enum AuthState: Equatable {
        case signedOut
        case requestingLink
        case awaitingLink(email: String)
        case verifying
        case signedIn
        case error(String)
    }

    private(set) var state: AuthState = .signedOut
    /// The email a magic link was last sent to (drives resend + the wait screen).
    private(set) var pendingEmail: String?

    private let api: APIClient
    private let auth: AuthStore
    private let apple: AppleSignInCoordinator

    init(api: APIClient, auth: AuthStore, apple: AppleSignInCoordinator = AppleSignInCoordinator()) {
        self.api = api
        self.auth = auth
        self.apple = apple
        // If a session was restored from the Keychain, start already signed in.
        if auth.session != nil { state = .signedIn }
    }

    // MARK: Sign in with Apple

    func signInWithApple() async {
        state = .verifying
        let rawNonce = AppleNonce.make()
        let hashedNonce = AppleNonce.sha256(rawNonce)
        do {
            let result = try await apple.start(hashedNonce: hashedNonce)
            let body = AppleAuthBody(
                identityToken: result.identityToken,
                authorizationCode: result.authorizationCode,
                rawNonce: rawNonce,
                fullName: result.fullName,
                email: result.email
            )
            let session = try await api.authApple(body)
            auth.save(session)
            state = .signedIn
        } catch is AuthError {
            state = .signedOut  // user cancelled / no token — silently return to sign-in
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                state = .signedOut
            } else {
                state = .error("Couldn't sign in with Apple. Please try again.")
            }
        }
    }

    // MARK: Magic link

    func requestMagicLink(email: String) async {
        let normalized = Self.normalize(email)
        guard Self.isValidEmail(normalized) else {
            state = .error("Enter a valid email address.")
            return
        }
        state = .requestingLink
        pendingEmail = normalized
        do {
            try await api.magicLinkRequest(email: normalized)
            state = .awaitingLink(email: normalized)
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("Couldn't send the link. Check your connection and try again.")
        }
    }

    func resendMagicLink() async {
        guard let email = pendingEmail else { return }
        await requestMagicLink(email: email)
    }

    func verifyMagicLink(token: String) async {
        state = .verifying
        do {
            let session = try await api.magicLinkVerify(token: token)
            auth.save(session)
            state = .signedIn
        } catch let e as APIError {
            state = .error(Self.message(for: e))
        } catch {
            state = .error("This link is invalid or has expired. Request a new one.")
        }
    }

    // MARK: Deep link

    func handleDeepLink(_ url: URL) async {
        guard let token = MagicLinkParser.token(from: url) else { return }
        await verifyMagicLink(token: token)
    }

    // MARK: Sign out

    func signOut() async {
        try? await api.signOut()
        auth.clear()
        pendingEmail = nil
        state = .signedOut
    }

    /// Re-evaluates the state after an external session restore (used at launch).
    func refreshAuthState() {
        state = auth.session != nil ? .signedIn : .signedOut
    }

    // MARK: Helpers

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValidEmail(_ email: String) -> Bool {
        // Minimal RFC-ish check; the server is the real validator.
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
        let domain = email[email.index(after: at)...]
        return domain.contains(".") && !domain.hasSuffix(".") && !email.contains(" ")
    }

    private static func message(for error: APIError) -> String {
        switch error.code {
        case "AUTH_INVALID_TOKEN", "AUTH_SESSION_REVOKED":
            return "This link is invalid or has expired. Request a new one."
        case "RATE_LIMITED":
            return "Too many attempts. Please wait a moment and try again."
        case "VALIDATION_FAILED":
            return "That email didn't look right. Please check it and try again."
        default:
            return error.message.isEmpty ? "Something went wrong. Please try again." : error.message
        }
    }
}
```

- [ ] **Step 8: Run all three logic tests — expect PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/MagicLinkParserTests -only-testing:SnapceiptTests/AppleNonceTests -only-testing:SnapceiptTests/AuthViewModelTests
```

Expected: **PASS** — all of `MagicLinkParserTests` (7), `AppleNonceTests` (3), and `AuthViewModelTests` (9) green. The magic-link request normalizes + validates the email and moves to `.awaitingLink`; verify success saves the session and reaches `.signedIn`; a 401 maps to `.error` with no session; `handleDeepLink` extracts the token and signs in; resend re-requests the pending email; sign-out clears the Keychain.

- [ ] **Step 9: Commit the logic layer (TDD step)**

```bash
git add Snapceipt/Features/Auth/AuthViewModel.swift SnapceiptTests/AuthViewModelTests.swift SnapceiptTests/MagicLinkParserTests.swift SnapceiptTests/AppleNonceTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): AuthViewModel state machine + magic-link/deep-link parsing

Add the @Observable AuthViewModel (signedOut/requestingLink/awaitingLink/
verifying/signedIn/error), Sign in with Apple via ASAuthorizationController
+ CryptoKit nonce, magic-link request/verify against the backend /auth
contract, MagicLinkParser for snapceipt://auth/verify + the universal link,
and sign-out. Covered by AuthViewModel/MagicLinkParser/AppleNonce tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: one commit with the VM + its three test files.

- [ ] **Step 10: Implement `Snapceipt/Features/Auth/SignInView.swift`** (pure UI — verified by build + `#Preview`)

Uses design tokens (`Palette`, `Radius`, `Font.display`/`Font.ui`) and the active `accent` from the environment. The native `SignInWithAppleButton` triggers `vm.signInWithApple()`; "Continue with email" expands an email field that calls `vm.requestMagicLink`.

```swift
import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    @State private var email = ""
    @State private var showEmailField = false
    @FocusState private var emailFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Brand lockup
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(colors: [accent.base, accent.deep],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 78, height: 78)
                        .shadow(color: accent.base.opacity(0.45), radius: 18, x: 0, y: 10)
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Snapceipt")
                    .font(.display(30, .bold))
                    .foregroundStyle(Palette.ink)
                Text("Snap receipts. Sort your tax. Done.")
                    .font(.ui(15))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 44)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)         // visual; tap handled by the overlay button
                    .overlay(
                        Button { Task { await vm.signInWithApple() } } label: {
                            Color.clear
                        }
                        .accessibilityLabel("Sign in with Apple")
                    )

                if showEmailField {
                    emailEntry
                } else {
                    Button {
                        withAnimation { showEmailField = true }
                        emailFocused = true
                    } label: {
                        Text("Continue with email")
                            .font(.ui(16, .semibold))
                            .foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Palette.line, lineWidth: 1)
                            )
                    }
                }

                if case .error(let message) = vm.state {
                    Text(message)
                        .font(.ui(13))
                        .foregroundStyle(Palette.alert)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)

            Text("By continuing you agree to our Terms & Privacy Policy.")
                .font(.ui(11.5))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
    }

    private var emailEntry: some View {
        HStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                .font(.ui(16))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($emailFocused)
                .onSubmit { send() }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Palette.line, lineWidth: 1)
                )

            Button(action: send) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(email.isEmpty)
            .opacity(email.isEmpty ? 0.5 : 1)
        }
    }

    private func send() {
        let value = email
        Task { await vm.requestMagicLink(email: value) }
    }
}

#Preview {
    SignInView()
        .environment(AuthViewModel(
            api: PreviewAPIClient(),
            auth: AuthStore(keychain: Keychain(service: "sc.preview"))
        ))
        .environment(\.accent, AccentPalette(
            base: Color(hex: 0xE8602C), soft: Color(hex: 0xFDEBE0), deep: Color(hex: 0xC2461A)
        ))
}
```

- [ ] **Step 11: Add a shared `PreviewAPIClient` for previews — append to the bottom of `SignInView.swift`**

A no-op `APIClient` so all auth/onboarding `#Preview`s compile without the live network stack. Gated behind `#if DEBUG` so it never ships.

```swift
#if DEBUG
/// No-op APIClient used only by SwiftUI previews in this module.
@MainActor
final class PreviewAPIClient: APIClient {
    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse { stub }
    func magicLinkRequest(email: String) async throws {}
    func magicLinkVerify(token: String) async throws -> SessionResponse { stub }
    func refresh(refreshToken: String) async throws -> SessionResponse { stub }
    func signOut() async throws {}
    func me() async throws -> MeResponse {
        MeResponse(user: .init(id: "u", email: "you@example.com", displayName: "You"), devices: [])
    }
    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        PushResponse(results: [], serverTime: Clock.nowMs())
    }
    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        PullResponse(changes: [], nextCursor: nil, hasMore: false, serverTime: Clock.nowMs())
    }
    private var stub: SessionResponse {
        SessionResponse(accessToken: "a.b.c", refreshToken: "r",
                        expiresIn: 900,
                        user: .init(id: "u", email: "you@example.com", displayName: "You"))
    }
}
#endif
```

- [ ] **Step 12: Implement `Snapceipt/Features/Auth/MagicLinkWaitView.swift`** (pure UI — build + `#Preview`)

"Check your email" with the destination email, a resend button (re-requests via `vm.resendMagicLink()`), a "use a different email" escape back to `.signedOut`, and the expired/invalid `.error` branch with retry.

```swift
import SwiftUI

struct MagicLinkWaitView: View {
    @Environment(AuthViewModel.self) private var vm
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(accent.soft)
                    .frame(width: 96, height: 96)
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "envelope.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(isError ? Palette.alert : accent.base)
            }
            .padding(.bottom, 22)

            Text(isError ? "Link expired" : "Check your email")
                .font(.display(24, .bold))
                .foregroundStyle(Palette.ink)
                .padding(.bottom, 8)

            Text(subtitle)
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button { Task { await vm.resendMagicLink() } } label: {
                    Text(isError ? "Send a new link" : "Resend email")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                Button { Task { await vm.signOut() } } label: {
                    Text("Use a different email")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
    }

    private var isError: Bool {
        if case .error = vm.state { return true }
        return false
    }

    private var subtitle: String {
        if case .error(let message) = vm.state { return message }
        let email = vm.pendingEmail ?? "your inbox"
        return "We sent a sign-in link to \(email). Tap it on this device to continue."
    }
}

#Preview("Waiting") {
    let vm = AuthViewModel(api: PreviewAPIClient(),
                           auth: AuthStore(keychain: Keychain(service: "sc.preview")))
    return MagicLinkWaitView()
        .environment(vm)
        .environment(\.accent, AccentPalette(
            base: Color(hex: 0xE8602C), soft: Color(hex: 0xFDEBE0), deep: Color(hex: 0xC2461A)
        ))
        .task { await vm.requestMagicLink(email: "maya@example.com") }
}
```

- [ ] **Step 13: Implement `Snapceipt/Features/Onboarding/PermissionPrimingView.swift`** (pure UI + a tiny injectable requester)

`PermissionRequesting` abstracts the system calls so the view stays testable/buildable; `LivePermissionRequester` performs the real `AVCaptureDevice` + `UNUserNotificationCenter` requests. The view shows rationale and an "Allow" CTA that calls the requester, then advances via `onContinue`.

```swift
import SwiftUI
import AVFoundation
import UserNotifications

enum PermissionKind {
    case camera, notifications

    var title: String {
        switch self {
        case .camera: return "Snap receipts in a tap"
        case .notifications: return "Stay on top of your budgets"
        }
    }
    var rationale: String {
        switch self {
        case .camera:
            return "Snapceipt uses your camera to capture receipts and read the total, GST and category for you. Photos stay on your device until you save."
        case .notifications:
            return "Get a heads-up when a budget is close to its cap or your BAS is due. You can fine-tune these later in Settings."
        }
    }
    var systemImage: String {
        switch self {
        case .camera: return "camera.fill"
        case .notifications: return "bell.badge.fill"
        }
    }
    var allowTitle: String {
        switch self {
        case .camera: return "Allow camera access"
        case .notifications: return "Turn on notifications"
        }
    }
}

/// Abstraction over the system permission prompts so the UI is injectable + buildable in previews.
protocol PermissionRequesting {
    func request(_ kind: PermissionKind) async
}

struct LivePermissionRequester: PermissionRequesting {
    func request(_ kind: PermissionKind) async {
        switch kind {
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .notifications:
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        }
    }
}

struct PermissionPrimingView: View {
    let kind: PermissionKind
    let requester: PermissionRequesting
    let onContinue: () -> Void

    @Environment(\.accent) private var accent
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle().fill(accent.soft).frame(width: 110, height: 110)
                Image(systemName: kind.systemImage)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(accent.base)
            }
            .padding(.bottom, 26)

            Text(kind.title)
                .font(.display(24, .bold))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.bottom, 10)

            Text(kind.rationale)
                .font(.ui(15))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 34)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button(action: allow) {
                    Text(kind.allowTitle)
                        .font(.ui(16, .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(busy)

                Button(action: onContinue) {
                    Text("Not now")
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Palette.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream.ignoresSafeArea())
    }

    private func allow() {
        busy = true
        Task {
            await requester.request(kind)
            busy = false
            onContinue()
        }
    }
}

#if DEBUG
struct NoopPermissionRequester: PermissionRequesting {
    func request(_ kind: PermissionKind) async {}
}
#endif

#Preview {
    PermissionPrimingView(kind: .camera, requester: NoopPermissionRequester()) {}
        .environment(\.accent, AccentPalette(
            base: Color(hex: 0xE8602C), soft: Color(hex: 0xFDEBE0), deep: Color(hex: 0xC2461A)
        ))
}
```

- [ ] **Step 14: Implement `Snapceipt/Features/Onboarding/OnboardingView.swift`** (pure UI — build + `#Preview`)

Three-step flow after first sign-in: **create first profile** (reuses `AddProfileView` from Task: profiles), then **prime Camera**, then **prime Notifications**. When `AddProfileView` finishes (its `onCreated` callback), and after both priming steps, `onFinished()` lets `RootView` re-evaluate and route into the shell. `AddProfileView`'s exact init is owned by the profiles task; this view assumes the canonical `AddProfileView(onCreated:)` callback that fires after a successful optimistic create.

```swift
import SwiftUI

enum OnboardingStep { case profile, camera, notifications }

struct OnboardingView: View {
    /// Called once the first profile exists and permissions have been primed.
    let onFinished: () -> Void
    var requester: PermissionRequesting = LivePermissionRequester()

    @State private var step: OnboardingStep = .profile

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            switch step {
            case .profile:
                AddProfileView(onCreated: {
                    withAnimation { step = .camera }
                })
            case .camera:
                PermissionPrimingView(kind: .camera, requester: requester) {
                    withAnimation { step = .notifications }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            case .notifications:
                PermissionPrimingView(kind: .notifications, requester: requester) {
                    onFinished()
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

#Preview {
    OnboardingView(onFinished: {}, requester: NoopPermissionRequester())
        .environment(\.accent, AccentPalette(
            base: Color(hex: 0xE8602C), soft: Color(hex: 0xFDEBE0), deep: Color(hex: 0xC2461A)
        ))
}
```

> Note: if the profiles task shipped `AddProfileView` with a different completion hook name (e.g. `onComplete`/`onDone`) or required `ProfilesStore` in the environment, adapt the single call site above to that signature — do **not** redefine `AddProfileView`. The onboarding screen only needs "profile created → advance".

- [ ] **Step 15: Wire `AuthViewModel` + deep-link handling into `Snapceipt/App/SnapceiptApp.swift` (Modify)**

Inject the `AuthViewModel` (built from the same `APIClient` + `AuthStore` the rest of the app uses) into the environment, and route `onOpenURL` to `handleDeepLink`. Adjust the property/initializer names below to whatever the app-shell task created (it owns the `ModelContainer`, `APIClient`, `AuthStore`, `Router`, `ProfilesStore`, `ToastCenter` instances) — the only required additions are the bracketed lines.

```swift
import SwiftUI
import SwiftData

@main
struct SnapceiptApp: App {
    private let container: ModelContainer

    @State private var auth: AuthStore
    @State private var api: APIClient
    @State private var router = Router()
    @State private var toasts = ToastCenter()
    @State private var authVM: AuthViewModel        // <-- added

    init() {
        // ModelContainer + APIClient + AuthStore are constructed by the app-shell task;
        // this mirrors that construction and adds the AuthViewModel.
        let container = try! ModelContainer(for: ModelContainer.snapceiptSchema)
        self.container = container
        let auth = AuthStore(keychain: Keychain())
        let api: APIClient = LiveAPIClient(baseURL: AppConfig.apiBaseURL, auth: auth)
        _auth = State(initialValue: auth)
        _api = State(initialValue: api)
        _authVM = State(initialValue: AuthViewModel(api: api, auth: auth))   // <-- added
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authVM)              // <-- added
                .environment(auth)
                .environment(router)
                .environment(toasts)
                .modelContainer(container)
                .onOpenURL { url in               // <-- added: magic-link Universal/custom link
                    Task { await authVM.handleDeepLink(url) }
                }
        }
    }
}
```

> The `ModelContainer.snapceiptSchema`, `LiveAPIClient(baseURL:auth:)`, and `AppConfig.apiBaseURL` references belong to earlier tasks (model / sync). If their exact names differ, keep this file's existing construction and only add the three `// <-- added` lines (the `authVM` state, its `.environment(authVM)`, and the `.onOpenURL` handler).

- [ ] **Step 16: Route auth states in `Snapceipt/App/RootView.swift` (Modify)**

`RootView` reads `AuthViewModel.state` and the live profile list (the app-shell task already wires the tab shell — preserve it as the signed-in branch). The "signed-in but no profile" gate uses a SwiftData `@Query` for `Profile`; an alternative is `ProfilesStore.profiles.isEmpty` if the shell already holds a `ProfilesStore`.

```swift
import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(AuthViewModel.self) private var authVM
    @Query private var profiles: [Profile]

    var body: some View {
        Group {
            switch authVM.state {
            case .signedIn:
                if profiles.isEmpty {
                    OnboardingView(onFinished: { /* profiles non-empty re-renders into the shell */ })
                } else {
                    AppShellView()        // the 5-tab shell from the app-shell task
                }
            case .awaitingLink, .verifying where authVM.pendingEmail != nil:
                MagicLinkWaitView()
            default:
                SignInView()
            }
        }
        .animation(.easeInOut(duration: 0.28), value: profiles.isEmpty)
    }
}
```

> `AppShellView` is the tab-bar shell created by the app-shell task — substitute its actual name. The `where` clause keeps the wait screen visible while a tapped link is verifying (so the UI doesn't flash back to Sign-in mid-verify). `RootView` re-renders automatically: when `OnboardingView` creates the first profile via `AddProfileView`, the `@Query` updates and `profiles.isEmpty` flips, swapping in the shell.

- [ ] **Step 17: Regenerate the Xcode project (new files must be picked up by XcodeGen)**

```bash
xcodegen generate --spec /Users/yangqi/Documents/github/Snapceipt/project.yml
```

Expected: `Loaded project ... Created project at .../Snapceipt.xcodeproj`. The five new `Features/Auth` + `Features/Onboarding` source files and the three new test files are now in the `Snapceipt` / `SnapceiptTests` targets (the `project.yml` from the app-shell task globs `Snapceipt/**` and `SnapceiptTests/**`).

- [ ] **Step 18: Build the app (verifies all pure-UI views + the modified app shell compile)**

```bash
xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

Expected: **PASS** — `** BUILD SUCCEEDED **`. `SignInView`, `MagicLinkWaitView`, `OnboardingView`, `PermissionPrimingView`, the `#Preview`s, and the modified `SnapceiptApp`/`RootView` all type-check against the design system, `AuthStore`, `Router`, `AddProfileView`, and the `APIClient` protocol. If the build flags an unknown `AppShellView`/`AddProfileView(onCreated:)`/`ModelContainer.snapceiptSchema` symbol, reconcile that single call site to the name the owning task actually shipped (do not redefine the type).

- [ ] **Step 19: Re-run the full auth test suite after the project regen (no regressions)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AuthViewModelTests -only-testing:SnapceiptTests/MagicLinkParserTests -only-testing:SnapceiptTests/AppleNonceTests
```

Expected: **PASS** — 19 tests green (9 + 7 + 3), confirming the views/wiring didn't break the logic layer.

- [ ] **Step 20: Commit the UI + app wiring**

```bash
git add Snapceipt/Features/Auth/SignInView.swift Snapceipt/Features/Auth/MagicLinkWaitView.swift Snapceipt/Features/Onboarding/OnboardingView.swift Snapceipt/Features/Onboarding/PermissionPrimingView.swift Snapceipt/App/SnapceiptApp.swift Snapceipt/App/RootView.swift project.yml
git commit -m "$(cat <<'EOF'
feat(ios): sign-in, magic-link wait + onboarding screens and auth routing

Add SignInView (Sign in with Apple + Continue with email), MagicLinkWaitView
(check-your-email + resend + expired error), OnboardingView (create first
profile via AddProfileView, then Camera + Notifications permission priming),
and PermissionPrimingView with an injectable PermissionRequesting. Wire
AuthViewModel + onOpenURL deep-link handling into SnapceiptApp and route
RootView: no session -> SignIn, session but no profile -> Onboarding, else
the tab shell. Pure-UI verified by build + #Preview.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: one commit with the four new view files, the two modified `App/` files, and the regenerated `project.yml` reference.

---

**Notes / cross-task contracts honored:**
- DTOs consumed verbatim from Task: sync — `APIClient` protocol, `AppleAuthBody` (`identityToken, authorizationCode, rawNonce, fullName?, email?`), `SessionResponse { accessToken, refreshToken, expiresIn, user{ id, email, displayName } }`, `MeResponse`, `APIError { code, message, status }`, plus `PushMutation`/`PushResponse`/`PullResponse` (referenced only to satisfy the mock's protocol conformance). `expiresIn` is `900` to match the backend.
- `AuthStore.save(_:)` / `clear()` / `session` / `bearer()` / `deviceId` and `Keychain(service:)` are from Task: sync — used, not redefined.
- `Router`, `ProfilesStore`, `Profile`, `AddProfileView`, `ToastCenter`, `AccentPalette`, `Palette`, `Radius`, `Font.display`/`Font.ui`, `Color(hex:)`, `Clock.nowMs()` are from earlier tasks — used, not redefined.
- Deep-link forms parsed: `snapceipt://auth/verify?token=` (custom scheme, §13) and the Universal Links `https://snapceipt.app/auth/verify?token=` (spec §9) + `…/auth/magic?token=` (the backend's emitted link). The custom scheme + AASA association are declared in `Info.plist` / the project config by the app-shell task; this task only consumes the URL.


---

### Task 13: Profiles — ProfilesStore, switcher header, picker sheet, AddProfile (form + success)

Builds the multi-profile layer on top of the SwiftData `Profile` `@Model` (Task on Model), the `AccentPalette` + `\.accent` environment (DesignSystem task), the `SyncEngine` (Sync task), and `Router` (App task). Switching the active profile re-skins the app accent; adding a profile writes to SwiftData synchronously and enqueues a sync upsert. TDD the logic (`AddProfileViewModel`, `ProfilesStore`) with Swift Testing + an in-memory `ModelContainer` and a `MockSyncEngine` spy; verify the three pure-SwiftUI views with `#Preview` + a build.

**Canonical references (do NOT redefine — import/extend):** `Profile` (`@Model`, syncable; stored props `id, userId, profileId, createdAt, updatedAt, deletedAt, rev, lastEditedDeviceId` + `name, type, initials, accent1, accent2, accent3, abn, gstRegistered, isDefault, sortOrder`), `AccentPalette { base; soft; deep }`, `EnvironmentValues.accent`, `EntityType` (`.profile`), `SyncEngine.enqueue(op:entityType:entity:)`, `ID.uuidv7()`, `Clock.nowMs()`, `Palette`, `Radius`, `Color(hex:)`, `Font.display/ui`, `.cardShadow()`, `Card`, `IconCircle`, `Router`/`Overlay`.

> Decoupling note: `ProfilesStore` and `AddProfileViewModel` enqueue sync through a tiny `SyncEnqueuing` protocol (one method, the exact `SyncEngine.enqueue` signature) so tests inject a `MockSyncEngine` spy. `SyncEngine` conforms to it via an extension — no change to `SyncEngine` itself.

**Files**
- Create: `Snapceipt/Features/Profiles/ProfilesStore.swift`
- Create: `Snapceipt/Features/Profiles/AddProfileViewModel.swift`
- Create: `Snapceipt/Features/Profiles/ProfileSwitcherHeader.swift`
- Create: `Snapceipt/Features/Profiles/ProfilePickerSheet.swift`
- Create: `Snapceipt/Features/Profiles/AddProfileView.swift`
- Test: `SnapceiptTests/AddProfileViewModelTests.swift`
- Test: `SnapceiptTests/ProfilesStoreTests.swift`
- Modify: `project.yml` (no edit needed — files land under the globbed `Snapceipt/`/`SnapceiptTests/` sources; just regenerate)

---

- [ ] **Step 1: Define the sync seam + accent palettes in `ProfilesStore.swift` (no behavior yet, just the shared types the VMs depend on)**

Create `Snapceipt/Features/Profiles/ProfilesStore.swift` with the `SyncEnqueuing` protocol, the 8 `AP_ACCENTS` swatches (verbatim hexes from `theme.jsx`/`screens.md`), `ProfileType`, and a `SyncEngine` conformance. (The `ProfilesStore` class itself is added in Step 7 — split out so the VM test in Steps 2-6 compiles against just these types.)

```swift
import Foundation
import SwiftData
import SwiftUI

// MARK: - Sync seam

/// One-method seam over `SyncEngine.enqueue` so view-models can enqueue a sync
/// mutation while staying unit-testable (tests inject a `MockSyncEngine` spy).
/// The signature mirrors `SyncEngine.enqueue` VERBATIM.
protocol SyncEnqueuing: AnyObject {
    func enqueue(op: String, entityType: EntityType, entity: any Syncable)
}

extension SyncEngine: SyncEnqueuing {}

// MARK: - Profile type

/// UI-facing profile kind. Mirrors the `profiles.type` CHECK enum
/// (`'personal' | 'business'`). Drives the conditional ABN/GST fields and the
/// default accent suggestion.
enum ProfileType: String, CaseIterable, Identifiable {
    case personal
    case business
    var id: String { rawValue }
    var label: String { self == .personal ? "Personal" : "Business" }
    var iconName: String { self == .personal ? "wallet" : "building" }
}

// MARK: - Accent swatches

/// One of the 8 selectable accent palettes (the `AP_ACCENTS` set from theme.jsx).
/// `base/soft/deep` map to `profiles.accent_1/2/3` and to `AccentPalette`.
struct AccentSwatch: Identifiable, Equatable {
    let id: String
    let name: String
    let base: String   // hex "#RRGGBB"
    let soft: String
    let deep: String

    var palette: AccentPalette {
        AccentPalette(
            base: Color(hex: hex(base)),
            soft: Color(hex: hex(soft)),
            deep: Color(hex: hex(deep))
        )
    }
}

/// Parse "#E8602C" -> 0xE8602C for `Color(hex:)`.
func hex(_ s: String) -> UInt32 {
    UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
}

/// The 8 production accent palettes. Personal terracotta is index 0 (default for
/// a fresh Personal profile); Business teal is index 1. Hexes are verbatim from
/// theme.jsx / screens.md (incl. Lumen blue + Rentals green).
let AP_ACCENTS: [AccentSwatch] = [
    .init(id: "terracotta", name: "Terracotta", base: "#E8602C", soft: "#FDEBE0", deep: "#C2461A"),
    .init(id: "teal",       name: "Teal",       base: "#0E7C72", soft: "#DCF0ED", deep: "#0A5950"),
    .init(id: "indigo",     name: "Indigo",     base: "#3F5BB0", soft: "#E7EAF8", deep: "#2C4290"),
    .init(id: "forest",     name: "Forest",     base: "#2F7A55", soft: "#DFF0E6", deep: "#205B3D"),
    .init(id: "violet",     name: "Violet",     base: "#7B5BD6", soft: "#EBE5F8", deep: "#5C3FB0"),
    .init(id: "ocean",      name: "Ocean",      base: "#2F6FB0", soft: "#E2ECF6", deep: "#1F4E80"),
    .init(id: "rose",       name: "Rose",       base: "#B0568F", soft: "#F4E4EF", deep: "#854069"),
    .init(id: "amber",      name: "Amber",      base: "#C99A22", soft: "#F6EECE", deep: "#9A7314"),
]

/// Default swatch for a profile type (Personal -> terracotta, Business -> teal).
func defaultSwatch(for type: ProfileType) -> AccentSwatch {
    type == .personal ? AP_ACCENTS[0] : AP_ACCENTS[1]
}
```

- [ ] **Step 2: Write the FAILING `AddProfileViewModel` test FIRST**

Create `SnapceiptTests/AddProfileViewModelTests.swift`. Uses Swift Testing (`import Testing`) + an in-memory `ModelContainer` + a `MockSyncEngine` spy. Asserts: invalid until name entered; `create()` persists a `Profile` with ABN+GST+palette into the context, sets it active on the store, and enqueues exactly one `.profile` upsert. This FAILS to compile (`AddProfileViewModel`, `ProfilesStore`, `MockSyncEngine` don't exist yet).

```swift
import Testing
import SwiftData
@testable import Snapceipt

/// Spy implementing the sync seam — records every enqueue for assertions.
final class MockSyncEngine: SyncEnqueuing {
    struct Call { let op: String; let entityType: EntityType; let entityId: String }
    private(set) var calls: [Call] = []
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {
        calls.append(Call(op: op, entityType: entityType, entityId: entity.id))
    }
}

@MainActor
struct AddProfileViewModelTests {

    /// A fresh in-memory context + a ProfilesStore + spy, wired together.
    private func makeFixture() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, configurations: config)
        let context = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: context, sync: sync, userId: "u1")
        return (context, store, sync)
    }

    @Test("invalid until a non-empty name is entered")
    func validity() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        #expect(vm.isValid == false)
        vm.name = "   "
        #expect(vm.isValid == false)        // whitespace-only is still invalid
        vm.name = "Studio"
        #expect(vm.isValid == true)
    }

    @Test("create() persists a Business profile with ABN + GST + chosen palette")
    func createPersists() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .business
        vm.name = "Lumen Studio"
        vm.abn = "12 345 678 901"
        vm.gstRegistered = true
        vm.swatch = AP_ACCENTS[2]           // Indigo

        let created = try #require(vm.create())

        // Round-trips through the in-memory store.
        let all = try context.fetch(FetchDescriptor<Profile>())
        #expect(all.count == 1)
        let p = try #require(all.first)
        #expect(p.id == created.id)
        #expect(p.userId == "u1")
        #expect(p.name == "Lumen Studio")
        #expect(p.type == "business")
        #expect(p.abn == "12 345 678 901")
        #expect(p.gstRegistered == true)
        #expect(p.accent1 == "#3F5BB0")
        #expect(p.accent2 == "#E7EAF8")
        #expect(p.accent3 == "#2C4290")
        #expect(p.initials == "LS")          // derived from name
    }

    @Test("create() sets the new profile active and enqueues exactly one upsert")
    func createActivatesAndSyncs() throws {
        let (context, store, sync) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.name = "Personal"
        let created = try #require(vm.create())

        #expect(store.activeProfileId == created.id)
        #expect(sync.calls.count == 1)
        #expect(sync.calls.first?.op == "upsert")
        #expect(sync.calls.first?.entityType == .profile)
        #expect(sync.calls.first?.entityId == created.id)
    }

    @Test("create() returns nil and writes nothing when invalid")
    func createInvalidNoop() throws {
        let (context, store, sync) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        // name left empty
        #expect(vm.create() == nil)
        #expect(try context.fetch(FetchDescriptor<Profile>()).isEmpty)
        #expect(sync.calls.isEmpty)
    }

    @Test("personal profiles drop ABN/GST even if set on the form")
    func personalClearsBusinessFields() throws {
        let (context, store, _) = try makeFixture()
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = .personal
        vm.name = "Me"
        vm.abn = "99 999 999 999"            // should be ignored for personal
        vm.gstRegistered = true
        _ = try #require(vm.create())
        let p = try #require(try context.fetch(FetchDescriptor<Profile>()).first)
        #expect(p.abn == nil)
        #expect(p.gstRegistered == false)
    }
}
```

- [ ] **Step 3: Run the test — expect FAIL (compile error: missing types)**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AddProfileViewModelTests
```

Expected (FAIL): build fails — `cannot find 'AddProfileViewModel' in scope`, `cannot find 'ProfilesStore' in scope`. This proves the test drives the not-yet-written types.

- [ ] **Step 4: Implement `ProfilesStore` (the persistence + active-profile + accent layer the VM needs)**

Append the `ProfilesStore` class to `Snapceipt/Features/Profiles/ProfilesStore.swift` (below the types from Step 1).

```swift
// MARK: - ProfilesStore

/// Active-profile + profile-list state, backed by SwiftData. `activeProfileId`
/// is persisted to UserDefaults ("sc.activeProfile"); `accent` is derived from
/// the active profile's palette and drives the app-wide `\.accent` environment.
@Observable
final class ProfilesStore {
    private let context: ModelContext
    private let sync: any SyncEnqueuing
    private let userId: String
    private static let activeKey = "sc.activeProfile"

    /// All non-deleted profiles for the signed-in user, sorted for display.
    private(set) var profiles: [Profile] = []
    var activeProfileId: String {
        didSet { UserDefaults.standard.set(activeProfileId, forKey: Self.activeKey) }
    }

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.activeProfileId = UserDefaults.standard.string(forKey: Self.activeKey) ?? ""
        reload()
        // Default to the first/default profile if no valid active id is set.
        if profiles.first(where: { $0.id == activeProfileId }) == nil {
            activeProfileId = profiles.first(where: { $0.isDefault })?.id
                ?? profiles.first?.id ?? ""
        }
    }

    /// Re-read profiles from SwiftData (call after add/import/sync).
    func reload() {
        let uid = userId
        let descriptor = FetchDescriptor<Profile>(
            predicate: #Predicate { $0.userId == uid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        profiles = (try? context.fetch(descriptor)) ?? []
    }

    var activeProfile: Profile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    /// Accent palette for the active profile, parsed from its stored hexes.
    /// Falls back to personal terracotta when there is no active profile.
    var accent: AccentPalette {
        guard let p = activeProfile else { return AP_ACCENTS[0].palette }
        return AccentPalette(
            base: Color(hex: hex(p.accent1)),
            soft: Color(hex: hex(p.accent2)),
            deep: Color(hex: hex(p.accent3))
        )
    }

    /// Switch the active profile (no-op for an unknown id).
    func setActive(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
    }

    /// Insert a profile, refresh the list, enqueue a sync upsert, and activate it.
    func add(_ p: Profile) {
        context.insert(p)
        try? context.save()
        reload()
        sync.enqueue(op: "upsert", entityType: .profile, entity: p)
        setActive(p.id)
    }
}
```

- [ ] **Step 5: Implement `AddProfileViewModel`**

Create `Snapceipt/Features/Profiles/AddProfileViewModel.swift`.

```swift
import Foundation
import SwiftData

/// Drives the AddProfile form (type, name, ABN, GST, accent swatch) and the
/// two-step form -> success flow. `create()` builds a `Profile`, persists +
/// enqueues it through `ProfilesStore.add`, and activates it.
@Observable
@MainActor
final class AddProfileViewModel {
    private let store: ProfilesStore
    private let context: ModelContext
    private let userId: String

    var type: ProfileType = .personal {
        didSet { if !userPickedSwatch { swatch = defaultSwatch(for: type) } }
    }
    var name: String = ""
    var abn: String = ""
    var gstRegistered: Bool = false
    var swatch: AccentSwatch = defaultSwatch(for: .personal) {
        didSet { userPickedSwatch = true }
    }
    /// Set once the user changes the accent so the type-default stops overriding.
    private var userPickedSwatch = false

    /// Step-machine: false = form, true = success screen.
    private(set) var didCreate = false
    private(set) var createdProfile: Profile?

    init(store: ProfilesStore, context: ModelContext, userId: String) {
        self.store = store
        self.context = context
        self.userId = userId
    }

    /// Valid when the trimmed name is non-empty.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Up to two uppercase initials derived from the entered name.
    var derivedInitials: String {
        let words = name.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first }.map { String($0).uppercased() }
        return chars.joined()
    }

    /// Build + persist the profile. Returns nil (and no-ops) when invalid.
    @discardableResult
    func create() -> Profile? {
        guard isValid else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Clock.nowMs()
        let isBusiness = type == .business

        let p = Profile()
        p.id = ID.uuidv7()
        p.userId = userId
        p.profileId = nil
        p.name = trimmed
        p.type = type.rawValue
        p.initials = derivedInitials
        p.accent1 = swatch.base
        p.accent2 = swatch.soft
        p.accent3 = swatch.deep
        // ABN/GST are Business-only (personal profiles hide tax identity, §3.2).
        p.abn = isBusiness ? abn.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
        p.gstRegistered = isBusiness ? gstRegistered : false
        p.isDefault = store.profiles.isEmpty
        p.sortOrder = store.profiles.count
        p.createdAt = now
        p.updatedAt = now
        p.deletedAt = nil
        p.rev = 0
        p.lastEditedDeviceId = nil

        store.add(p)            // persists + enqueues sync + activates
        createdProfile = p
        didCreate = true
        return p
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 6: Run the test — expect PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AddProfileViewModelTests
```

Expected (PASS): all 5 `AddProfileViewModelTests` pass — validity gating, persistence with ABN/GST/palette + derived initials, activation + single `.profile` upsert enqueue, invalid no-op, and personal-clears-business-fields.

- [ ] **Step 7: Write the FAILING `ProfilesStore` test (setActive + accent derivation)**

Create `SnapceiptTests/ProfilesStoreTests.swift`. This compiles now (types exist) but asserts behavior we double-check: `setActive` updates `activeProfile`/`accent`; unknown id is a no-op; `add` enqueues. FAILS only if behavior is wrong.

```swift
import Testing
import SwiftData
import SwiftUI
@testable import Snapceipt

@MainActor
struct ProfilesStoreTests {

    private func makeStore() throws -> (ModelContext, ProfilesStore, MockSyncEngine) {
        // Isolate UserDefaults so a persisted activeProfileId from another run
        // can't leak in.
        UserDefaults.standard.removeObject(forKey: "sc.activeProfile")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Profile.self, configurations: config)
        let context = ModelContext(container)
        let sync = MockSyncEngine()
        let store = ProfilesStore(context: context, sync: sync, userId: "u1")
        return (context, store, sync)
    }

    private func seed(_ store: ProfilesStore, _ context: ModelContext,
                      name: String, type: ProfileType, swatch: AccentSwatch) -> Profile {
        let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
        vm.type = type
        vm.name = name
        vm.swatch = swatch
        return vm.create()!
    }

    @Test("setActive switches the active profile and re-derives the accent")
    func setActiveUpdatesAccent() throws {
        let (context, store, _) = try makeStore()
        let personal = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        let business = seed(store, context, name: "Lumen Studio", type: .business, swatch: AP_ACCENTS[2])

        store.setActive(personal.id)
        #expect(store.activeProfile?.id == personal.id)
        #expect(store.accent.base == Color(hex: 0xE8602C))   // terracotta

        store.setActive(business.id)
        #expect(store.activeProfile?.id == business.id)
        #expect(store.accent.base == Color(hex: 0x3F5BB0))   // indigo
    }

    @Test("setActive ignores an unknown id")
    func setActiveUnknownNoop() throws {
        let (context, store, _) = try makeStore()
        let p = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        store.setActive(p.id)
        store.setActive("does-not-exist")
        #expect(store.activeProfileId == p.id)
    }

    @Test("first added profile is the default and becomes active")
    func firstIsDefaultActive() throws {
        let (context, store, sync) = try makeStore()
        let p = seed(store, context, name: "Me", type: .personal, swatch: AP_ACCENTS[0])
        #expect(p.isDefault == true)
        #expect(store.activeProfileId == p.id)
        #expect(store.profiles.count == 1)
        #expect(sync.calls.count == 1)        // exactly one upsert per add
    }
}
```

- [ ] **Step 8: Run the `ProfilesStore` test — expect PASS**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ProfilesStoreTests
```

Expected (PASS): all 3 `ProfilesStoreTests` pass — accent re-derivation on `setActive`, unknown-id no-op, and first-profile default/active + single enqueue.

- [ ] **Step 9: Implement `ProfileSwitcherHeader` (pure SwiftUI; avatar + "ACTIVE PROFILE" + name + chevron)**

Create `Snapceipt/Features/Profiles/ProfileSwitcherHeader.swift`. Tokens are verbatim from screens.md (avatar 46×46 r15 gradient palette[0]→palette[2], label 11.5 ink3 uppercase ls 0.4, name 19 weight700, chevron pill only when >1 profile).

```swift
import SwiftUI

/// Home header: gradient avatar + "ACTIVE PROFILE" + name + (chevron when
/// multiple profiles). Tapping opens the picker via the supplied closure.
struct ProfileSwitcherHeader: View {
    let store: ProfilesStore
    /// Invoked when the user taps to switch (only meaningful with >1 profile).
    var onTapSwitch: () -> Void

    private var profile: Profile? { store.activeProfile }
    private var canSwitch: Bool { store.profiles.count > 1 }

    var body: some View {
        Button(action: { if canSwitch { onTapSwitch() } }) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE PROFILE")
                        .font(.ui(11.5, .bold))
                        .tracking(0.4)
                        .foregroundStyle(Palette.ink3)
                    HStack(spacing: 8) {
                        Text(profile?.name ?? "No profile")
                            .font(.display(19, .bold))
                            .tracking(-0.3)
                            .foregroundStyle(Palette.ink)
                        if canSwitch { chevronPill }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
    }

    private var avatar: some View {
        let base = Color(hex: hex(profile?.accent1 ?? "#E8602C"))
        let deep = Color(hex: hex(profile?.accent3 ?? "#C2461A"))
        return Text(profile?.initials ?? "?")
            .font(.display(17, .bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(
                LinearGradient(colors: [base, deep],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .shadow(color: base.opacity(0.45), radius: 7, x: 0, y: 6)
    }

    private var chevronPill: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Palette.ink2)
            .frame(width: 22, height: 22)
            .background(Palette.paper2, in: Circle())
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, configurations: config)
    let context = ModelContext(container)
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
    vm.name = "Lumen Studio"; vm.type = .business; vm.swatch = AP_ACCENTS[2]
    vm.create()
    vm.name = "Personal"; vm.type = .personal; vm.swatch = AP_ACCENTS[0]
    let v2 = AddProfileViewModel(store: store, context: context, userId: "u1")
    v2.name = "Personal"; v2.swatch = AP_ACCENTS[0]; v2.create()
    return ProfileSwitcherHeader(store: store, onTapSwitch: {})
        .padding()
        .background(Palette.cream)
}

/// Preview-only no-op sync seam (lives behind `#if DEBUG` so it never ships).
#if DEBUG
final class PreviewSync: SyncEnqueuing {
    func enqueue(op: String, entityType: EntityType, entity: any Syncable) {}
}
#endif

import SwiftData
```

> If the `import SwiftData` at the file foot trips a lint preference, move it to the top with the other imports — it is placed last only to keep the preview helper grouped; functionally identical.

- [ ] **Step 10: Implement `ProfilePickerSheet` (bottom sheet: profile rows + active check + "Add a profile")**

Create `Snapceipt/Features/Profiles/ProfilePickerSheet.swift`. Tokens from screens.md: sheet r28 top, title "Switch profile" 20 display, 42×42 gradient avatar rows, active row border = palette[0] + check, dashed "Add a profile" row.

```swift
import SwiftUI
import SwiftData

/// Bottom sheet listing the user's profiles with an active check, plus a dashed
/// "Add a profile" row. Selecting a row activates it and dismisses.
struct ProfilePickerSheet: View {
    let store: ProfilesStore
    var onAddProfile: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.line)
                .frame(width: 40, height: 5)
                .padding(.top, 10).padding(.bottom, 14)

            HStack {
                Text("Switch profile")
                    .font(.display(20, .bold))
                    .foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            VStack(spacing: 8) {
                ForEach(store.profiles, id: \.id) { p in
                    profileRow(p)
                }
                addRow
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func profileRow(_ p: Profile) -> some View {
        let isActive = p.id == store.activeProfileId
        let base = Color(hex: hex(p.accent1))
        let deep = Color(hex: hex(p.accent3))
        return Button {
            store.setActive(p.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(p.initials ?? "?")
                    .font(.display(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [base, deep],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.ui(15.5, .bold)).foregroundStyle(Palette.ink)
                    Text(ProfileType(rawValue: p.type)?.label ?? p.type)
                        .font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isActive ? base : Palette.line)
            }
            .padding(12)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .stroke(isActive ? base : Palette.line2, lineWidth: isActive ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var addRow: some View {
        Button(action: onAddProfile) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.ink2)
                    .frame(width: 42, height: 42)
                Text("Add a profile").font(.ui(15.5, .semibold)).foregroundStyle(Palette.ink2)
                Spacer(minLength: 0)
            }
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Palette.line)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, configurations: config)
    let context = ModelContext(container)
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    let a = AddProfileViewModel(store: store, context: context, userId: "u1")
    a.name = "Personal"; a.swatch = AP_ACCENTS[0]; a.create()
    let b = AddProfileViewModel(store: store, context: context, userId: "u1")
    b.name = "Lumen Studio"; b.type = .business; b.swatch = AP_ACCENTS[2]; b.create()
    return ProfilePickerSheet(store: store, onAddProfile: {})
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(Color.black.opacity(0.4))
}
```

- [ ] **Step 11: Implement `AddProfileView` (two-step: form + success)**

Create `Snapceipt/Features/Profiles/AddProfileView.swift`. Form fields per §12.5: Personal/Business segmented type, name, conditional Business name/ABN/GST toggle, 8-swatch accent picker; success step confirms + dismisses.

```swift
import SwiftUI
import SwiftData

/// Two-step "Add a profile": a form with live accent preview, then a success
/// screen. Persists optimistically (local-first) via `AddProfileViewModel.create`.
struct AddProfileView: View {
    @Bindable var vm: AddProfileViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if vm.didCreate { successStep } else { formStep }
        }
        .background(Palette.cream)
    }

    // MARK: Form

    private var formStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preview
                typePicker
                field("Profile name") {
                    TextField("e.g. Lumen Studio", text: $vm.name)
                        .font(.ui(16, .regular))
                        .textInputAutocapitalization(.words)
                }
                if vm.type == .business {
                    field("ABN (optional)") {
                        TextField("12 345 678 901", text: $vm.abn)
                            .font(.ui(16, .regular))
                            .keyboardType(.numbersAndPunctuation)
                    }
                    Toggle(isOn: $vm.gstRegistered) {
                        Text("Registered for GST").font(.ui(15.5, .semibold))
                            .foregroundStyle(Palette.ink)
                    }
                    .tint(Color(hex: hex(vm.swatch.base)))
                    .padding(14)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                }
                accentPicker
                createButton
            }
            .padding(18)
        }
    }

    private var preview: some View {
        let base = Color(hex: hex(vm.swatch.base))
        let deep = Color(hex: hex(vm.swatch.deep))
        return HStack(spacing: 12) {
            Text(vm.derivedInitials.isEmpty ? "?" : vm.derivedInitials)
                .font(.display(17, .bold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [base, deep], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name.isEmpty ? "New profile" : vm.name)
                    .font(.display(19, .bold)).foregroundStyle(Palette.ink)
                Text(vm.type.label).font(.ui(12.5, .regular)).foregroundStyle(Palette.ink3)
            }
            Spacer()
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    private var typePicker: some View {
        Picker("Type", selection: $vm.type) {
            ForEach(ProfileType.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private var accentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACCENT").font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(AP_ACCENTS) { sw in
                    let selected = sw.id == vm.swatch.id
                    Circle()
                        .fill(Color(hex: hex(sw.base)))
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(Palette.ink, lineWidth: selected ? 3 : 0))
                        .overlay(Circle().stroke(Palette.line, lineWidth: selected ? 0 : 1))
                        .onTapGesture { vm.swatch = sw }
                }
            }
        }
        .padding(16)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .cardShadow()
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(.ui(11.5, .bold)).tracking(0.4).foregroundStyle(Palette.ink3)
            content()
                .padding(14)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).stroke(Palette.line, lineWidth: 1))
        }
    }

    private var createButton: some View {
        Button { _ = vm.create() } label: {
            Text("Create profile")
                .font(.ui(17, .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 56)
                .background(Color(hex: hex(vm.swatch.base)),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!vm.isValid)
        .opacity(vm.isValid ? 1 : 0.5)
    }

    // MARK: Success

    private var successStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(Color(hex: hex(vm.swatch.base)))
            Text("Profile created")
                .font(.display(24, .bold)).foregroundStyle(Palette.ink)
            Text("\(vm.createdProfile?.name ?? "") is now your active profile.")
                .font(.ui(14.5, .regular)).foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done").font(.ui(16, .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(Color(hex: hex(vm.swatch.base)),
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Profile.self, configurations: config)
    let context = ModelContext(container)
    let store = ProfilesStore(context: context, sync: PreviewSync(), userId: "u1")
    let vm = AddProfileViewModel(store: store, context: context, userId: "u1")
    return AddProfileView(vm: vm)
}
```

- [ ] **Step 12: Regenerate the Xcode project + build (verifies all three views + previews compile)**

```bash
xcodegen generate && xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

Expected (PASS): `xcodegen` picks up the 5 new `Features/Profiles/*.swift` + 2 test files via the existing source globs; `xcodebuild build` succeeds with `** BUILD SUCCEEDED **` (the three SwiftUI views + their `#Preview`s compile against the canonical `Profile`, `AccentPalette`, `Palette`, `Radius`, `Font`, `Card`/`IconCircle`).

- [ ] **Step 13: Run the full profiles suite once more (regression) then commit**

```bash
xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/AddProfileViewModelTests -only-testing:SnapceiptTests/ProfilesStoreTests
```

Expected (PASS): all 8 tests across both suites pass.

```bash
git add Snapceipt/Features/Profiles SnapceiptTests/AddProfileViewModelTests.swift SnapceiptTests/ProfilesStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): profiles store, switcher header, picker sheet + add-profile flow

Add ProfilesStore (SwiftData-backed profile list, persisted active id in
UserDefaults "sc.activeProfile", accent derived from the active profile's
palette, setActive, add+enqueue) and AddProfileViewModel (personal/business
type, name/abn/gst, 8 AP_ACCENTS swatch pick, validity, create() that
persists + activates + enqueues a .profile sync upsert). Wire the
ProfileSwitcherHeader, ProfilePickerSheet, and two-step AddProfileView UI.
Covered by AddProfileViewModelTests + ProfilesStoreTests (in-memory
ModelContainer + MockSyncEngine spy).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: a single `ios`-scoped commit with the 5 feature files + 2 test files.

---

**Implementation notes for the executor**
- `Profile` is the canonical syncable `@Model` (Model task). This task uses property names `id, userId, profileId, name, type, initials, accent1, accent2, accent3, abn, gstRegistered, isDefault, sortOrder, createdAt, updatedAt, deletedAt, rev, lastEditedDeviceId`. If the Model task named the accent columns differently (e.g. `accentBase/Soft/Deep`), update the four assignments in `AddProfileViewModel.create()` + the avatar/accent readers accordingly — the names here mirror the backend `accent_1/2/3` columns.
- `SyncEngine` gains `SyncEnqueuing` conformance via the extension in `ProfilesStore.swift`; the real `SyncEngine.enqueue(op:entityType:entity:)` signature is already canonical, so the extension body is empty (protocol witness is the existing method).
- The app-wide accent re-skin is delivered by writing `store.accent` into the `\.accent` environment at the `RootView` level (App task). `ProfilesStore.accent` is the single source the App task reads; this task only guarantees it re-derives on `setActive` (proved by `ProfilesStoreTests.setActiveUpdatesAccent`).
- `PreviewSync` is `#if DEBUG`-gated so it is excluded from release builds; `MockSyncEngine` lives in the test target only.



---

### Task 14: App shell + cross-cutting (Router, raised-center TabBar, BottomSheet, Toast, SyncStatus, OfflineBanner, RootView) + integration test

This task assembles the authed app shell and the cross-cutting overlays on top of every layer built by Tasks 1–13. It owns the `Router`, the frosted raised-center 5-tab `TabBar`, a reusable `BottomSheet`, the global `ToastCenter`/`ToastHost`, the `SyncStatusView` (reads `SyncEngine.status`), the `OfflineBanner` (reads `Reachability`), and rewires `RootView` to compose all of it. It closes with a Swift Testing in-memory integration test that wires `AuthStore` + `ProfilesStore` + `SyncEngine(MockAPIClient)`, simulates a signed-in user with one profile, enqueues a profile upsert, runs `push()` then `pull()`, and asserts the store reflects both — plus `Router.go` tab/overlay switching.

Canonical types consumed verbatim (owned by earlier tasks, do NOT redefine): `Palette`, `AccentPalette`, the `\.accent` environment key, `Radius`, `.cardShadow()`/`.popShadow()`, `Font.display`/`Font.ui`, `Icon`/`Icons`, `ProfilesStore`, `Profile`, `AuthStore`, `SyncEngine`, `SyncStatus`, `Reachability`, `APIClient` + DTOs (`AppleAuthBody`, `SessionResponse`, `MeResponse`, `PushMutation`, `PushResponse`, `PullResponse`), `EntityType`, `Syncable`, `ID`, `Clock`, `ProfileSwitcherHeader`.

**Files**
- Create: `Snapceipt/App/Router.swift`
- Create: `Snapceipt/DesignSystem/TabBar.swift`
- Create: `Snapceipt/DesignSystem/BottomSheet.swift`
- Create: `Snapceipt/Shared/Toast.swift`
- Create: `Snapceipt/Shared/SyncStatusView.swift`
- Create: `Snapceipt/Shared/OfflineBanner.swift`
- Modify: `Snapceipt/App/RootView.swift`
- Test: `SnapceiptTests/ShellIntegrationTests.swift`

---

- [ ] **Step 1: Create `Snapceipt/App/Router.swift`** — the `@Observable` `Router` with the `Tab` enum (home/activity/snap/reports/profile, default `.home`), the `Overlay` enum (profilePicker, addProfile; capture/alerts added later phases), a `Route` enum, and `go(_:_:)`. The center Snap tab never changes the active tab — it raises the capture overlay (a placeholder this phase).

```swift
import SwiftUI
import Observation

/// The 5 bottom-bar tabs. `.snap` is the raised center FAB — selecting it never
/// becomes the active tab; it opens Capture (a placeholder until P1).
enum Tab: String, CaseIterable, Hashable {
    case home, activity, snap, reports, profile
}

/// Modal overlays the shell can present. profilePicker + addProfile are wired this
/// phase (Tasks 11/13); the rest are stubs surfaced for later phases so `go(_:)`
/// has a stable target set.
enum Overlay: Hashable {
    case profilePicker
    case addProfile
    case capture   // placeholder: "capture coming soon" until P1
    case alerts    // placeholder until P1
}

/// Routes the shell understands. Tab routes swap the active tab; overlay routes
/// raise a cover/sheet. `capture` is special-cased to the capture overlay.
enum Route: Hashable {
    case tab(Tab)
    case overlay(Overlay)
}

/// Single source of navigation truth for the authed shell.
/// `@Observable` so SwiftUI views re-render on tab/overlay change.
@MainActor
@Observable
final class Router {
    /// Active bottom tab. Persisted only in-memory this phase (no localStorage parity needed).
    var tab: Tab = .home
    /// Currently presented overlay, if any.
    var overlay: Overlay?

    /// Navigate. Tab routes switch the active tab (re-keying the screen replays the
    /// enter animation in RootView). Overlay routes raise a cover/sheet.
    /// The center Snap button calls `go(.overlay(.capture))` and must NOT change `tab`.
    func go(_ route: Route, _ payload: Any? = nil) {
        switch route {
        case .tab(let t):
            // `.snap` is not a destination tab — it always opens Capture.
            if t == .snap {
                overlay = .capture
            } else {
                tab = t
            }
        case .overlay(let o):
            overlay = o
        }
    }

    /// Dismiss any presented overlay.
    func dismissOverlay() {
        overlay = nil
    }
}
```

- [ ] **Step 2: Create `Snapceipt/DesignSystem/BottomSheet.swift`** — a reusable bottom-sheet container (grabber + cream rounded-top panel + `sc-rise` entry) used by the profile picker / add-profile overlays. Pure UI; verified by build + `#Preview`.

```swift
import SwiftUI

/// Reusable bottom-sheet container matching the prototype's ProfilePickerSheet shell:
/// 28pt top-corner radius, cream panel, a 40×5 grabber, scrim dismiss, sc-rise entry.
/// Content is injected; the sheet owns chrome + dismissal affordance.
struct BottomSheet<Content: View>: View {
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Scrim
            Color(red: 20/255, green: 16/255, blue: 12/255)
                .opacity(appeared ? 0.4 : 0)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                // Grabber
                Capsule()
                    .fill(Palette.line)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                content()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)
            .background(Palette.cream)
            .clipShape(.rect(topLeadingRadius: 28, topTrailingRadius: 28))
            .popShadow()
            .offset(y: appeared ? 0 : 14)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.98, anchor: .bottom)
        }
        .onAppear {
            withAnimation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.32)) {
                appeared = true
            }
        }
    }
}

#Preview {
    ZStack {
        Palette.cream.ignoresSafeArea()
        BottomSheet(onClose: {}) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Switch profile")
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                Text("Choose which profile to view.")
                    .font(.ui(13))
                    .foregroundStyle(Palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
    }
}
```

- [ ] **Step 3: Create `Snapceipt/DesignSystem/TabBar.swift`** — the frosted raised-center 5-tab bar (home/activity/snap-FAB/reports/profile). Active tabs use the accent tint; the center FAB is a 58×58 r20 accent-gradient button raised −26 with a 3pt cream ring and an accent FAB shadow. Non-foundation tabs route through `Router.go`; the FAB opens the capture overlay. Includes `StubTabView` for the non-foundation tab content. Pure UI; verified by build + `#Preview`.

```swift
import SwiftUI

/// A single non-center tab button (home/activity/reports/profile).
private struct TabItem: View {
    let tab: Tab
    let iconName: String
    let label: String
    let isActive: Bool
    let accent: AccentPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Icon(iconName, size: 23)
                    .foregroundStyle(isActive ? accent.base : Palette.ink3)
                Text(label)
                    .font(.ui(10.5, .semibold))
                    .foregroundStyle(isActive ? accent.base : Palette.ink3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Frosted, floating raised-center tab bar. The center Snap FAB opens Capture and
/// never changes the active tab (Router.go handles that). 64pt bar height, blur(18)
/// saturate(180) frosted material, 26pt corner radius, accent FAB raised −26.
struct TabBar: View {
    @Bindable var router: Router
    let accent: AccentPalette

    var body: some View {
        HStack(spacing: 0) {
            TabItem(tab: .home, iconName: Icons.home, label: "Home",
                    isActive: router.tab == .home, accent: accent) {
                router.go(.tab(.home))
            }
            TabItem(tab: .activity, iconName: Icons.receipt, label: "Activity",
                    isActive: router.tab == .activity, accent: accent) {
                router.go(.tab(.activity))
            }

            // Center Snap FAB — raised, accent gradient, 3pt cream ring, sh-fab.
            Button {
                router.go(.tab(.snap)) // routed to capture overlay (never sets .snap)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.base, accent.deep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Palette.cream, lineWidth: 3)
                        )
                        .shadow(color: accent.base.opacity(0.55), radius: 12, x: 0, y: 8)
                        .shadow(color: Color(red: 33/255, green: 28/255, blue: 24/255).opacity(0.18),
                                radius: 4, x: 0, y: 3)
                    Icon(Icons.camera, size: 28)
                        .foregroundStyle(.white)
                }
                .offset(y: -26)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("tabbar.snap")

            TabItem(tab: .reports, iconName: Icons.chart, label: "Reports",
                    isActive: router.tab == .reports, accent: accent) {
                router.go(.tab(.reports))
            }
            TabItem(tab: .profile, iconName: Icons.user, label: "Profile",
                    isActive: router.tab == .profile, accent: accent) {
                router.go(.tab(.profile))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .background(.regularMaterial)
        .background(Palette.paper.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
        .cardShadow()
        .padding(.horizontal, 16)
    }
}

/// Placeholder content for non-foundation tabs (Activity/Reports/Profile screens
/// land in later phases). Renders a calm centered EmptyArt-style message.
struct StubTabView: View {
    let title: String
    let accent: AccentPalette

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(accent.soft).frame(width: 96, height: 96)
                Icon(Icons.receipt, size: 34)
                    .foregroundStyle(accent.base)
            }
            Text(title)
                .font(.display(20))
                .foregroundStyle(Palette.ink)
            Text("Coming soon")
                .font(.ui(13.5))
                .foregroundStyle(Palette.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }
}

#Preview {
    ZStack(alignment: .bottom) {
        Palette.cream.ignoresSafeArea()
        TabBar(router: Router(), accent: AccentPalette(
            base: Palette.income, soft: Palette.incomeSoft, deep: Palette.income))
    }
}
```

> Note: `Icons.home`, `Icons.receipt`, `Icons.camera`, `Icons.chart`, `Icons.user` are the SF-Symbol-or-vector icon name constants defined in `DesignSystem/Icons.swift` (Task 2). If a constant differs (e.g. `Icons.person`), swap to that exact name — do not invent new icon assets here.

- [ ] **Step 4: Create `Snapceipt/Shared/Toast.swift`** — the global `@Observable` `ToastCenter` (`show(_:kind:)`) plus the `ToastHost` overlay that renders the top-most toast (info/success/error styling) and auto-dismisses. `SyncEngine`'s LWW "Updated on another device" toast routes through this.

```swift
import SwiftUI
import Observation

/// Visual kind of a toast — drives icon + accent color.
enum ToastKind: Hashable {
    case info, success, error
}

/// A single transient toast.
struct ToastItem: Identifiable, Hashable {
    let id = UUID()
    let message: String
    let kind: ToastKind
}

/// App-wide toast queue. `show` enqueues; ToastHost renders + auto-dismisses.
@MainActor
@Observable
final class ToastCenter {
    /// The most recent toast (single-slot; a new toast replaces the visible one).
    private(set) var current: ToastItem?

    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, kind: ToastKind = .info) {
        current = ToastItem(message: message, kind: kind)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// Overlays the app and renders the current toast near the top, above the safe area.
struct ToastHost: View {
    @Bindable var toasts: ToastCenter

    var body: some View {
        VStack {
            if let item = toasts.current {
                toastView(item)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.3), value: toasts.current)
        .allowsHitTesting(toasts.current != nil)
    }

    @ViewBuilder
    private func toastView(_ item: ToastItem) -> some View {
        HStack(spacing: 9) {
            Icon(icon(for: item.kind), size: 17)
                .foregroundStyle(tint(for: item.kind))
            Text(item.message)
                .font(.ui(13.5, .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .stroke(Palette.line, lineWidth: 1)
        )
        .popShadow()
        .onTapGesture { toasts.dismiss() }
    }

    private func icon(for kind: ToastKind) -> String {
        switch kind {
        case .info: return Icons.sparkles
        case .success: return Icons.check
        case .error: return Icons.shield
        }
    }

    private func tint(for kind: ToastKind) -> Color {
        switch kind {
        case .info: return Palette.ink2
        case .success: return Palette.income
        case .error: return Palette.alert
        }
    }
}

#Preview {
    let center = ToastCenter()
    return ZStack {
        Palette.cream.ignoresSafeArea()
        ToastHost(toasts: center)
    }
    .onAppear { center.show("Updated on another device", kind: .info) }
}
```

> Note: `Icons.sparkles`, `Icons.check`, `Icons.shield` are from `DesignSystem/Icons.swift`. If your icon set names a checkmark differently (e.g. `Icons.checkmark`), use that exact constant.

- [ ] **Step 5: Create `Snapceipt/Shared/SyncStatusView.swift`** — `SyncStatusView` reads `SyncEngine.status` (`.idle`/`.syncing`/`.offline`/`.error(String)`) and renders a small status pill (spinner while syncing, hidden when idle). Pure UI; verified by build + `#Preview`.

```swift
import SwiftUI

/// A compact status pill reflecting the SyncEngine state. Hidden when idle so the
/// shell stays calm; visible (with copy + tint) while syncing / offline / errored.
struct SyncStatusView: View {
    let status: SyncStatus

    var body: some View {
        if let model = display {
            HStack(spacing: 6) {
                if model.spinning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(model.tint)
                } else {
                    Circle().fill(model.tint).frame(width: 7, height: 7)
                }
                Text(model.label)
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Palette.ink2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.paper)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            .cardShadow()
        }
    }

    private struct Display {
        let label: String
        let tint: Color
        let spinning: Bool
    }

    private var display: Display? {
        switch status {
        case .idle:
            return nil
        case .syncing:
            return Display(label: "Syncing…", tint: Palette.ink3, spinning: true)
        case .offline:
            return Display(label: "Offline", tint: Palette.ink3, spinning: false)
        case .error:
            return Display(label: "Sync failed", tint: Palette.alert, spinning: false)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        SyncStatusView(status: .syncing)
        SyncStatusView(status: .offline)
        SyncStatusView(status: .error("boom"))
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.cream)
}
```

> Note: `SyncStatus` (with cases `.idle/.syncing/.offline/.error(String)`) is owned by `Sync/SyncEngine.swift` (Task 9/10). This view only reads it. If `SyncStatus` is nested as `SyncEngine.Status`, reference it as that exact type in the `status` parameter.

- [ ] **Step 6: Create `Snapceipt/Shared/OfflineBanner.swift`** — `OfflineBanner` reads `Reachability` and renders a thin alert-tinted banner when the device is offline; renders nothing when online. Pure UI; verified by build + `#Preview`.

```swift
import SwiftUI

/// A slim banner shown when the device has no connectivity. Reads the shared
/// Reachability (@Observable). Renders nothing while online.
struct OfflineBanner: View {
    @Bindable var reachability: Reachability

    var body: some View {
        if !reachability.isOnline {
            HStack(spacing: 7) {
                Icon(Icons.shield, size: 14)
                    .foregroundStyle(.white)
                Text("You’re offline — changes will sync later")
                    .font(.ui(12.5, .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Palette.alert)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview {
    let r = Reachability()
    return VStack(spacing: 0) {
        OfflineBanner(reachability: r)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.cream)
    .onAppear { r.isOnline = false }
}
```

> Note: `Reachability` is owned by `Sync/Reachability.swift` (Task 8/9) and exposes `var isOnline: Bool`. If the property is named `online`/`connected`, use that exact name. The `#Preview` mutating `r.isOnline` assumes a settable property; if `Reachability` only exposes a read-only flag, drop the `.onAppear` mutation in the preview.

- [ ] **Step 7: Modify `Snapceipt/App/RootView.swift`** — compose the authed shell: a `ZStack` of (active-tab content re-keyed on `tab`+`activeProfileId` to replay the enter animation) + `OfflineBanner` + `SyncStatusView` + floating `TabBar` + overlays (profile picker / add-profile bottom sheets, capture placeholder cover) + `ToastHost`. Inject the active profile's `AccentPalette` into the environment. Trigger `SyncEngine.sync()` on launch and on foreground. The Home tab is a stub hosting `ProfileSwitcherHeader` this phase. Replace the file's body wholesale.

```swift
import SwiftUI
import SwiftData

/// The authed app shell: tab content + floating raised-center TabBar + overlays +
/// cross-cutting offline/sync/toast layers. Switching tab or active profile re-keys
/// the screen so the enter animation (sc-fade-up) replays. SyncEngine.sync() fires
/// on launch and on foreground.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    @Bindable var router: Router
    @Bindable var auth: AuthStore
    @Bindable var profiles: ProfilesStore
    @Bindable var sync: SyncEngine
    @Bindable var toasts: ToastCenter
    @Bindable var reachability: Reachability

    var body: some View {
        let accent = profiles.accent

        ZStack(alignment: .bottom) {
            Palette.cream.ignoresSafeArea()

            // --- Active tab content, re-keyed on tab + active profile ---
            VStack(spacing: 0) {
                OfflineBanner(reachability: reachability)
                tabContent(accent: accent)
                    // Re-key: a new identity replays the enter animation.
                    .id(router.tab.rawValue + "|" + profiles.activeProfileId)
                    .transition(.opacity.combined(with: .offset(y: 10)))
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34),
                               value: router.tab)
                    .animation(.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.34),
                               value: profiles.activeProfileId)
            }

            // --- Floating sync status pill (above the tab bar, hidden when idle) ---
            VStack {
                HStack {
                    Spacer()
                    SyncStatusView(status: sync.status)
                        .padding(.trailing, 18)
                        .padding(.top, 6)
                }
                Spacer()
            }

            // --- Floating raised-center tab bar ---
            TabBar(router: router, accent: accent)
                .padding(.bottom, 22)
        }
        .environment(\.accent, accent)
        // --- Overlays ---
        .overlay {
            overlayContent
        }
        // --- Global toasts on top of everything ---
        .overlay {
            ToastHost(toasts: toasts)
        }
        .task {
            // Launch sync.
            await sync.sync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.sync() }
            }
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(accent: AccentPalette) -> some View {
        switch router.tab {
        case .home:
            homeStub(accent: accent)
        case .activity:
            StubTabView(title: "Activity", accent: accent)
        case .reports:
            StubTabView(title: "Reports", accent: accent)
        case .profile:
            StubTabView(title: "Profile", accent: accent)
        case .snap:
            // Never the active tab (Router routes .snap to the capture overlay),
            // but render Home as a safe fallback.
            homeStub(accent: accent)
        }
    }

    /// Home-tab stub: the profile-switcher header (Task 13) over a placeholder body.
    @ViewBuilder
    private func homeStub(accent: AccentPalette) -> some View {
        VStack(spacing: 0) {
            ProfileSwitcherHeader(
                profiles: profiles,
                onTapProfile: { router.go(.overlay(.profilePicker)) }
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)

            Spacer()
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.soft).frame(width: 96, height: 96)
                    Icon(Icons.receipt, size: 34).foregroundStyle(accent.base)
                }
                Text("Snap a receipt")
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                Text("Your dashboard lands in the next build.")
                    .font(.ui(13.5))
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlayContent: some View {
        switch router.overlay {
        case .profilePicker:
            BottomSheet(onClose: { router.dismissOverlay() }) {
                ProfilePickerSheet(
                    profiles: profiles,
                    onAddProfile: { router.go(.overlay(.addProfile)) },
                    onClose: { router.dismissOverlay() }
                )
            }
        case .addProfile:
            BottomSheet(onClose: { router.dismissOverlay() }) {
                AddProfileView(
                    profiles: profiles,
                    onDone: { router.dismissOverlay() }
                )
            }
        case .capture:
            capturePlaceholder
        case .alerts:
            capturePlaceholder
        case .none:
            EmptyView()
        }
    }

    /// Capture is P1 — surface a calm "coming soon" cover this phase.
    @ViewBuilder
    private var capturePlaceholder: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                Icon(Icons.camera, size: 40).foregroundStyle(.white)
                Text("Capture is coming soon")
                    .font(.display(22))
                    .foregroundStyle(.white)
                Button {
                    router.dismissOverlay()
                } label: {
                    Text("Close")
                        .font(.ui(16, .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Palette.paper.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }
}
```

> Note: `ProfileSwitcherHeader`, `ProfilePickerSheet`, and `AddProfileView` are owned by `Features/Profiles/*` (Task 13). The exact initializer parameter labels above (`profiles:`, `onTapProfile:`, `onAddProfile:`, `onClose:`, `onDone:`) must match Task 13's signatures — adjust to those exact labels if they differ. `ProfilesStore` exposes `accent: AccentPalette`, `activeProfileId: String`. `SyncEngine.sync()` is `async`. The `RootView(...)` call site lives in `App/RootView.swift`'s sibling (the authed branch of `App/SnapceiptApp.swift`/the unauthed-vs-authed switch from Task 9/12) — pass the shared `Router/AuthStore/ProfilesStore/SyncEngine/ToastCenter/Reachability` instances there.

- [ ] **Step 8: Write the FAILING integration test `SnapceiptTests/ShellIntegrationTests.swift`** — wires the real stores against an in-memory `ModelContainer` and a `MockAPIClient`, simulates a signed-in user with one profile, enqueues a profile upsert, runs `push()` then `pull()`, and asserts the store reflects both; plus `Router.go` tab/overlay switching. The suite is `@MainActor` (all stores are `@MainActor @Observable` and touch `ModelContext`).

```swift
import Testing
import SwiftData
@testable import Snapceipt

/// A mock APIClient conforming to the canonical protocol. push() echoes each mutation
/// back as "applied" with a bumped rev; pull() returns one server-authored profile
/// envelope the first time, then nothing (cursor exhausted).
@MainActor
final class MockAPIClient: APIClient {
    var pushedMutations: [PushMutation] = []
    var pulledOnce = false
    let serverProfileId = ID.uuidv7()
    let serverNow = Clock.nowMs()

    func authApple(_ body: AppleAuthBody) async throws -> SessionResponse {
        SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                        user: .init(id: "u1", email: "u@x.com", displayName: "U"))
    }
    func magicLinkRequest(email: String) async throws {}
    func magicLinkVerify(token: String) async throws -> SessionResponse {
        SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                        user: .init(id: "u1", email: "u@x.com", displayName: "U"))
    }
    func refresh(refreshToken: String) async throws -> SessionResponse {
        SessionResponse(accessToken: "a2", refreshToken: "r2", expiresIn: 900,
                        user: .init(id: "u1", email: "u@x.com", displayName: "U"))
    }
    func signOut() async throws {}
    func me() async throws -> MeResponse {
        MeResponse(user: .init(id: "u1", email: "u@x.com", displayName: "U"))
    }

    func syncPush(deviceId: String, mutations: [PushMutation]) async throws -> PushResponse {
        pushedMutations.append(contentsOf: mutations)
        let results = mutations.map { m in
            PushResult(mutationId: m.mutationId, status: "applied", reason: nil,
                       entity: serverEntity(id: m.entityId, type: m.entityType,
                                            rev: (m.baseRev ?? 0) + 1, updatedAt: serverNow))
        }
        return PushResponse(results: results, serverTime: serverNow)
    }

    func syncPull(cursor: String?, limit: Int) async throws -> PullResponse {
        if pulledOnce {
            return PullResponse(changes: [], nextCursor: "c1", hasMore: false, serverTime: serverNow)
        }
        pulledOnce = true
        let change = serverEntity(id: serverProfileId, type: "profile",
                                  rev: 1, updatedAt: serverNow + 1, name: "Business")
        return PullResponse(changes: [change], nextCursor: "c1", hasMore: false, serverTime: serverNow + 1)
    }

    /// Builds a minimal server-canonical entity envelope (matches the backend `type`-tagged shape).
    private func serverEntity(id: String, type: String, rev: Int, updatedAt: Int,
                              name: String = "Personal") -> SyncEntity {
        SyncEntity(
            type: type, id: id, userId: "u1", profileId: nil,
            createdAt: serverNow, updatedAt: updatedAt, deletedAt: nil,
            rev: rev, lastEditedDeviceId: "server",
            fields: ["name": .string(name), "profileType": .string("business"),
                     "accent1": .string("#0E7C72"), "accent2": .string("#DCF0ED"),
                     "accent3": .string("#0A5950")]
        )
    }
}

@MainActor
@Suite("Shell integration")
struct ShellIntegrationTests {

    /// Spins up an in-memory SwiftData stack with every syncable @Model registered.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Profile.self, Transaction.self, LineItem.self, Category.self,
            Budget.self, LoyaltyCard.self, MileageTrip.self, WFHLog.self,
            Quote.self, QuoteLineItem.self, TaxSettings.self, OutboxMutation.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return ModelContext(container)
    }

    @Test("push then pull: the store reflects the local upsert and the server-pulled profile")
    func pushThenPull() async throws {
        let context = try makeContext()
        let api = MockAPIClient()
        let auth = AuthStore()
        auth.save(SessionResponse(accessToken: "a", refreshToken: "r", expiresIn: 900,
                                  user: .init(id: "u1", email: "u@x.com", displayName: "U")))
        let engine = SyncEngine(api: api, context: context, auth: auth)
        let store = ProfilesStore(context: context)

        // Simulate a signed-in user with one local profile.
        let local = Profile(
            id: ID.uuidv7(), userId: "u1", name: "Personal", type: "personal",
            accent1: "#E8602C", accent2: "#FDEBE0", accent3: "#C2461A"
        )
        store.add(local)
        store.setActive(local.id)

        // Enqueue a profile upsert + push.
        engine.enqueue(op: "upsert", entityType: .profile, entity: local)
        await engine.push()

        // The mock received the mutation and it was acked (outbox drained).
        #expect(api.pushedMutations.contains { $0.entityId == local.id })
        let pendingAfterPush = try context.fetch(
            FetchDescriptor<OutboxMutation>(predicate: #Predicate { $0.status == "pending" })
        )
        #expect(pendingAfterPush.isEmpty)

        // Pull a new server-authored profile and reload the store.
        await engine.pull()
        store.reload()

        // Both profiles present: the local one and the server-pulled "Business".
        #expect(store.profiles.contains { $0.id == local.id })
        #expect(store.profiles.contains { $0.id == api.serverProfileId })
        #expect(store.profiles.contains { $0.name == "Business" })
    }

    @Test("Router.go switches tab and raises/dismisses overlays; Snap never becomes the active tab")
    func routerNavigation() {
        let router = Router()
        #expect(router.tab == .home)
        #expect(router.overlay == nil)

        router.go(.tab(.reports))
        #expect(router.tab == .reports)

        // Snap routes to the capture overlay and must NOT change the active tab.
        router.go(.tab(.snap))
        #expect(router.tab == .reports)
        #expect(router.overlay == .capture)

        router.dismissOverlay()
        #expect(router.overlay == nil)

        router.go(.overlay(.profilePicker))
        #expect(router.overlay == .profilePicker)
    }

    @Test("ToastCenter.show publishes the current toast")
    func toastCenter() {
        let center = ToastCenter()
        #expect(center.current == nil)
        center.show("Updated on another device", kind: .info)
        #expect(center.current?.message == "Updated on another device")
        #expect(center.current?.kind == .info)
        center.dismiss()
        #expect(center.current == nil)
    }
}
```

> Note: `SyncEntity`/`PushResult`/`SessionResponse.user` (and its `.init(id:email:displayName:)`), `PullResponse`, `PushResponse`, the value-codec used for `fields` (shown as `.string(_)`), and the `Profile` initializer labels are owned by `Sync/DTOs.swift`, `Sync/SyncEngine.swift`, and `Model/Entities/Profile.swift` (Tasks 6/9/10 and 7). Reconcile the literal constructor calls above to those exact shapes — the test's *logic* (enqueue → push drains outbox → pull adds the server profile → store reflects both; Router/Toast assertions) is what matters and must stay. If `ProfilesStore.reload()` is named `refresh()`/`load()`, use that exact name; if `ProfilesStore` re-reads SwiftData reactively on the engine's `context`, the explicit reload call may be dropped.

- [ ] **Step 9: Generate the Xcode project so the new files are in the targets, then run the integration test and watch it FAIL**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodegen generate
```

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ShellIntegrationTests
```

  Expected (FAIL): the build fails to resolve `Router`, `TabBar`, `ToastCenter`, `BottomSheet`, `SyncStatusView`, `OfflineBanner`, or the new `RootView` composition — or, once those compile, the `ShellIntegrationTests` assertions fail because `RootView`/`Router` are not yet wired (e.g. `router.tab == .reports` not satisfied, or the outbox not drained). This proves the test exercises the new shell.

- [ ] **Step 10: Verify the shell compiles end-to-end (pure-UI build verify) and the full app builds**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" build
```

  Expected (PASS): `** BUILD SUCCEEDED **`. All new pure-UI views (`TabBar`, `BottomSheet`, `ToastHost`, `SyncStatusView`, `OfflineBanner`) and their `#Preview`s compile; `RootView` composes them against the real stores; `Router` resolves.

- [ ] **Step 11: Run the integration test and watch it PASS**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:SnapceiptTests/ShellIntegrationTests
```

  Expected (PASS): `Test Suite 'ShellIntegrationTests' passed`. `pushThenPull` confirms the mock received the profile upsert, the outbox drained to non-pending after `push()`, and after `pull()` + `reload()` the store contains both the local "Personal" and the server "Business" profile. `routerNavigation` confirms tab switches, Snap→capture-overlay (no tab change), and overlay raise/dismiss. `toastCenter` confirms `show`/`dismiss`.

- [ ] **Step 12: Run the FULL foundation test suite to confirm no regressions across earlier tasks**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && xcodebuild test -scheme Snapceipt -destination "platform=iOS Simulator,name=iPhone 16"
```

  Expected (PASS): `** TEST SUCCEEDED **` — every suite (Formatters/Money, Categories, Syncable/EntityType, entities, Keychain, APIClient, SyncEngine, AuthViewModel/AddProfileViewModel/ProfilesStore, and `ShellIntegrationTests`) passes.

- [ ] **Step 13: Commit the shell + cross-cutting layer**

```bash
cd /Users/yangqi/Documents/github/Snapceipt && git checkout -b ios-shell-crosscutting 2>/dev/null || git checkout ios-shell-crosscutting
git add Snapceipt/App/Router.swift Snapceipt/App/RootView.swift \
  Snapceipt/DesignSystem/TabBar.swift Snapceipt/DesignSystem/BottomSheet.swift \
  Snapceipt/Shared/Toast.swift Snapceipt/Shared/SyncStatusView.swift Snapceipt/Shared/OfflineBanner.swift \
  SnapceiptTests/ShellIntegrationTests.swift project.yml
git commit -m "$(cat <<'EOF'
feat(ios): app shell + cross-cutting (Router, raised-center TabBar, toast/sync/offline)

Add the @Observable Router (Tab/Overlay/Route + go()), the frosted
raised-center 5-tab TabBar with an accent-gradient Snap FAB (opens a
capture placeholder; non-foundation tabs render StubTabView), a reusable
BottomSheet, the global ToastCenter/ToastHost, SyncStatusView (reads
SyncEngine.status) and OfflineBanner (reads Reachability). Rewire RootView
to compose the authed shell — re-keying the screen on tab/active-profile
change to replay the enter animation, injecting the active AccentPalette,
and firing SyncEngine.sync() on launch + foreground. Cover with an
in-memory integration test that wires AuthStore + ProfilesStore +
SyncEngine(MockAPIClient): enqueue a profile upsert, push (mock applies)
then pull (mock returns a new profile), and assert the store reflects both,
plus Router tab/overlay switching and ToastCenter.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

  Expected: a single commit on `ios-shell-crosscutting` containing the 6 new shell/cross-cutting files, the rewritten `RootView.swift`, the integration test, and the regenerated `project.yml` (if `xcodegen` rewrote it). This completes the foundation shell — later phases mount real Activity/Reports/Profile screens and the Capture flow onto these same `Router`/`TabBar`/overlay seams.



---

