# TestFlight Beta Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Snapceipt to an external TestFlight beta: production backend live at `api.snapceipt.cc`, privacy/support site at `snapceipt.cc`, release-ready iOS app, and a one-command `fastlane beta` upload.

**Architecture:** Five tracks from the approved spec (`docs/superpowers/specs/2026-06-10-testflight-beta-launch-design.md`): execute the existing `scripts/deploy.sh` against the real Cloudflare account; add a second static-assets Worker for the public site; close the iOS release gaps (icon, entitlements, privacy manifest); walk the App Store Connect ceremony; wire fastlane (match + gym + pilot). Tasks 1–7 are repo-only and need no external accounts; Tasks 8–16 touch Cloudflare/Apple and are ordered by their real dependencies.

**Tech Stack:** Cloudflare Workers (wrangler v4 via `npx --yes wrangler@4`, run from the repo root unless stated), XcodeGen, Swift/CoreGraphics (icon generation), fastlane (Ruby ≥ 3.0 via Homebrew — system Ruby 2.6 is too old), App Store Connect API.

**User-supplied inputs** (the executor must STOP and ask the user when a step needs one):

| Input | Needed by | Where the user gets it |
|---|---|---|
| `TEAM_ID` (10-char Apple Team ID) | Task 6, 7, 11 | developer.apple.com → Membership |
| DeepSeek API key | Task 9 | platform.deepseek.com |
| APNs `.p8` + Key ID | Task 11 | created in Task 11 step 2 |
| ASC API key (`.p8`, key ID, issuer ID) | Task 12 | created in Task 12 step 2 |
| match cert repo URL + `MATCH_PASSWORD` | Task 12 | user creates private repo + picks passphrase |

Tasks marked **[USER]** are manual browser/device steps the user performs; the executor gives the exact instructions, waits, then runs the verification command.

---

### Task 1: Backend config — real bundle ID + custom-domain route

**Files:**
- Modify: `wrangler.jsonc`

- [ ] **Step 1: Update `wrangler.jsonc`**

Replace the full file content with (two changes vs current: the new `routes` key, and `APPLE_BUNDLE_ID` now `app.snapceipt.Snapceipt`):

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "snapceipt-api",
  "main": "src/index.ts",
  "compatibility_date": "2026-05-15",
  "compatibility_flags": ["nodejs_compat"],
  "observability": { "enabled": true },
  "triggers": { "crons": ["0 * * * *"] },
  "routes": [{ "pattern": "api.snapceipt.cc", "custom_domain": true }],
  "d1_databases": [
    {
      "binding": "DB",
      "database_name": "snapceipt",
      "database_id": "00000000-0000-0000-0000-000000000000",
      "migrations_dir": "migrations"
    }
  ],
  "kv_namespaces": [
    { "binding": "KV", "id": "00000000000000000000000000000000" }
  ],
  "r2_buckets": [
    { "binding": "RECEIPTS", "bucket_name": "snapceipt-receipts" }
  ],
  // Inbound Email Routing (F6): provision a catch-all on the in.snapceipt.cc zone
  // in the Cloudflare dashboard, routing to this Worker's email() handler. No binding
  // is declared here (inbound email is a handler, not a binding). The "ai" binding
  // below powers email-in OCR (gated by E2E_EMAIL_MODE in tests).
  "ai": { "binding": "AI" },
  "send_email": [
    { "name": "EMAIL", "allowed_sender_addresses": ["noreply@snapceipt.cc"] }
  ],
  "vars": {
    // The iOS app's real bundle id — SIWA verifies identityToken.aud against this.
    // Tests pin their own value in vitest.config.ts; this var is prod-only.
    "APPLE_BUNDLE_ID": "app.snapceipt.Snapceipt",
    "DEEPSEEK_MODEL": "deepseek-chat"
  }
}
```

- [ ] **Step 2: Verify tests are untouched by the var change**

Run: `npm run typecheck && npm test`
Expected: typecheck clean; **325 tests pass, 0 fail** (vitest.config.ts pins `APPLE_BUNDLE_ID: "com.snapceipt.app"` for the test runtime, so nothing moves).

- [ ] **Step 3: Commit**

```bash
git add wrangler.jsonc
git commit -m "fix(beta): point APPLE_BUNDLE_ID at the real iOS bundle id + attach api custom domain"
```

---

### Task 2: Public site Worker (privacy + support)

**Files:**
- Create: `site/wrangler.jsonc`
- Create: `site/public/index.html`
- Create: `site/public/privacy.html`
- Create: `site/public/support.html`

- [ ] **Step 1: Create `site/wrangler.jsonc`**

```jsonc
{
  "name": "snapceipt-site",
  "compatibility_date": "2026-06-01",
  // Assets-only Worker: no script, Cloudflare serves ./public directly.
  // html_handling default serves /privacy from privacy.html.
  "assets": { "directory": "./public" },
  "routes": [
    { "pattern": "snapceipt.cc", "custom_domain": true },
    { "pattern": "www.snapceipt.cc", "custom_domain": true }
  ]
}
```

- [ ] **Step 2: Create `site/public/index.html`**

```html
<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Snapceipt — snap receipts, sorted for tax</title>
<style>
  :root { --cream:#FBF6F0; --ink:#211C18; --ink2:#6B6258; --terra:#E8602C; --terra2:#C2461A; }
  * { box-sizing:border-box; margin:0; }
  body { background:var(--cream); color:var(--ink); font:18px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width:640px; margin:0 auto; padding:96px 24px; }
  h1 { font-size:40px; line-height:1.15; letter-spacing:-0.5px; }
  h1 span { color:var(--terra); }
  p.lede { margin-top:16px; color:var(--ink2); }
  nav { margin-top:40px; display:flex; gap:24px; }
  nav a { color:var(--terra2); font-weight:600; text-decoration:none; border-bottom:2px solid var(--terra2); padding-bottom:2px; }
  footer { margin-top:96px; font-size:14px; color:var(--ink2); }
</style>
</head>
<body>
<main>
  <h1>Snapceipt — <span>snap receipts</span>, sorted for tax.</h1>
  <p class="lede">Capture a receipt with your camera and Snapceipt reads the merchant,
  total, GST and category for you. Built for Australian sole traders and households.
  Currently in private beta on TestFlight.</p>
  <nav>
    <a href="/privacy">Privacy policy</a>
    <a href="/support">Support</a>
  </nav>
  <!-- App Store badge goes here at public launch (spec §4: link placeholder) -->
  <p class="lede" style="margin-top:40px">Coming soon to the App&nbsp;Store.</p>
  <footer>© 2026 Snapceipt</footer>
</main>
</body>
</html>
```

- [ ] **Step 3: Create `site/public/privacy.html`**

```html
<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Privacy Policy — Snapceipt</title>
<style>
  :root { --cream:#FBF6F0; --ink:#211C18; --ink2:#6B6258; --terra2:#C2461A; }
  * { box-sizing:border-box; margin:0; }
  body { background:var(--cream); color:var(--ink); font:17px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width:680px; margin:0 auto; padding:64px 24px; }
  h1 { font-size:32px; }
  h2 { font-size:20px; margin-top:36px; }
  p, li { margin-top:12px; color:var(--ink); }
  ul { padding-left:24px; }
  a { color:var(--terra2); }
  .muted { color:var(--ink2); font-size:14px; margin-top:8px; }
</style>
</head>
<body>
<main>
  <h1>Privacy Policy</h1>
  <p class="muted">Effective 10 June 2026 · Snapceipt ("we", "us")</p>

  <h2>What we collect</h2>
  <ul>
    <li><strong>Account details:</strong> your email address and, if you use Sign in
    with Apple, the name and email Apple shares with us.</li>
    <li><strong>Receipts and transactions:</strong> receipt photos you capture and the
    transaction details extracted from them (merchant, amounts, GST, category, notes).</li>
    <li><strong>Device push token:</strong> if you enable notifications, so we can send
    budget alerts you asked for.</li>
  </ul>

  <h2>How your data is processed</h2>
  <ul>
    <li>Your data is stored with <strong>Cloudflare</strong> (our hosting provider) —
    receipt images in object storage, transaction records in our database.</li>
    <li>To read a receipt, its image is OCR'd and the <strong>text</strong> is sent to
    <strong>DeepSeek</strong> (a third-party AI provider) to extract the merchant,
    total, GST and category. Only receipt text is shared — never your name, email or
    account details.</li>
    <li><strong>Apple</strong> processes your sign-in when you use Sign in with Apple.</li>
  </ul>

  <h2>What we don't do</h2>
  <ul>
    <li>No advertising, no tracking, no analytics SDKs.</li>
    <li>We never sell your data or share it for marketing.</li>
  </ul>

  <h2>Deleting your data</h2>
  <p>Delete your account any time in the app under <strong>Account → Delete
  Account</strong>. This permanently removes your account, receipts, images and
  transactions from our systems.</p>

  <h2>Contact</h2>
  <p>Questions? Email <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a>.</p>
</main>
</body>
</html>
```

- [ ] **Step 4: Create `site/public/support.html`**

```html
<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Support — Snapceipt</title>
<style>
  :root { --cream:#FBF6F0; --ink:#211C18; --ink2:#6B6258; --terra2:#C2461A; }
  * { box-sizing:border-box; margin:0; }
  body { background:var(--cream); color:var(--ink); font:17px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width:680px; margin:0 auto; padding:64px 24px; }
  h1 { font-size:32px; }
  h2 { font-size:20px; margin-top:36px; }
  p { margin-top:12px; }
  a { color:var(--terra2); }
</style>
</head>
<body>
<main>
  <h1>Support</h1>
  <p>Snapceipt is in private beta. If something looks wrong — a receipt that won't
  extract, a sync that didn't happen, a sign-in loop — we want to hear about it.</p>

  <h2>Get help</h2>
  <p>Email <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a> and include
  what you tapped, what you expected, and what happened instead. Screenshots help.</p>

  <h2>Sign-in issues</h2>
  <p>If a magic-link email doesn't arrive within a couple of minutes, check spam, or
  use Sign in with Apple instead.</p>

  <h2>Delete your account</h2>
  <p>In the app: <strong>Account → Delete Account</strong>. It removes all your data
  immediately and permanently.</p>
</main>
</body>
</html>
```

- [ ] **Step 5: Verify locally with wrangler dev**

Run from the repo root (no `cd` — backgrounding a `cd X && cmd &` compound never changes the foreground shell's directory; paths in the config resolve relative to the config file):

```bash
npx --yes wrangler@4 dev -c site/wrangler.jsonc --port 8788 &
for i in $(seq 1 30); do curl -sf -o /dev/null http://127.0.0.1:8788/privacy && break; sleep 2; done
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/privacy   # expect 200
curl -s http://127.0.0.1:8788/privacy | grep -c "DeepSeek"               # expect 1 (or more)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8788/support   # expect 200
lsof -ti:8788 | xargs kill
```
Expected: both pages return 200; the privacy page mentions DeepSeek. (The poll loop covers the first-run `npx` download of wrangler@4.)

- [ ] **Step 6: Commit**

```bash
git add site/
git commit -m "feat(beta): snapceipt.cc public site (landing + privacy + support)"
```

---

### Task 3: iOS entitlements + Face ID usage string

**Files:**
- Create: `Snapceipt/Snapceipt.entitlements` (Debug)
- Create: `Snapceipt/Snapceipt.Release.entitlements` (Release)
- Modify: `Snapceipt/Info.plist`
- Modify: `project.yml`

- [ ] **Step 1: Create the per-config entitlements pair**

Two files, because Release uses **manual signing** with the match App Store profile (Task 6): the archive itself is signed with that profile, and manual-signing validation requires the file's `aps-environment` to match the profile's (`production`). The export-re-sign mechanism only applies to automatic signing.

`Snapceipt/Snapceipt.entitlements` (Debug):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
	<!-- Debug/dev builds use automatic signing, whose dev profiles carry
	     aps-environment=development. Release uses Snapceipt.Release.entitlements
	     (production) because manual signing with the match App Store profile
	     validates this file's value against the profile. -->
	<key>aps-environment</key>
	<string>development</string>
</dict>
</plist>
```

`Snapceipt/Snapceipt.Release.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.applesignin</key>
	<array>
		<string>Default</string>
	</array>
	<!-- Release archives are signed directly with the match App Store profile
	     (manual signing), which pins aps-environment to production — the file
	     value must match or the archive fails validation. -->
	<key>aps-environment</key>
	<string>production</string>
</dict>
</plist>
```

- [ ] **Step 2: Add the Face ID usage string + export-compliance key to `Snapceipt/Info.plist`**

Insert directly after the existing `NSCameraUsageDescription` key/string pair:

```xml
	<key>NSFaceIDUsageDescription</key>
	<string>Snapceipt uses Face ID to unlock the app when 'Require Face ID' is turned on.</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
```

(The string names the actual UI label from `PrivacyView` — users never see the words "App Lock".)

`ITSAppUsesNonExemptEncryption: false` answers the export-compliance question at upload time for every build (the app uses only standard HTTPS — exempt). Without it, each uploaded build sits in ASC as "Missing Compliance" and `pilot` cannot distribute to the external group.

(The F7 app-lock uses `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` in `Snapceipt/Features/Account/AppLockController.swift` — Face ID on real devices requires this string. No `NSPhotoLibraryUsageDescription` is needed: the codebase has no `UIImagePickerController`/`PHPicker` usage, camera only.)

- [ ] **Step 3: Wire the entitlements file in `project.yml`**

In the `Snapceipt` target: add `CODE_SIGN_ENTITLEMENTS` to its base settings, and exclude the entitlements file from sources (like `Info.plist`). The target's `sources` and `settings.base` become:

```yaml
    sources:
      - path: Snapceipt
        excludes:
          - "Info.plist"
          - "Snapceipt.entitlements"
          - "Snapceipt.Release.entitlements"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.snapceipt.Snapceipt
        INFOPLIST_FILE: Snapceipt/Info.plist
        CODE_SIGN_ENTITLEMENTS: Snapceipt/Snapceipt.entitlements
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: NO
        TARGETED_DEVICE_FAMILY: "1"
        SUPPORTED_PLATFORMS: "iphoneos iphonesimulator"
        ENABLE_PREVIEWS: YES
        SWIFT_EMIT_LOC_STRINGS: YES
      configs:
        Release:
          CODE_SIGN_ENTITLEMENTS: Snapceipt/Snapceipt.Release.entitlements
```

- [ ] **Step 4: Regenerate and build for simulator**

```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` (simulator builds don't validate entitlements against a provisioning profile, so this passes with no Apple setup).

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Snapceipt.entitlements Snapceipt/Snapceipt.Release.entitlements Snapceipt/Info.plist project.yml
git commit -m "feat(beta): SIWA + push entitlements and Face ID usage string"
```

---

### Task 4: Generated app icon + asset catalog

**Files:**
- Create: `scripts/generate-app-icon.swift`
- Create: `Snapceipt/Resources/Assets.xcassets/Contents.json`
- Create: `Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (generated)
- Modify: `project.yml`

- [ ] **Step 1: Create `scripts/generate-app-icon.swift`**

```swift
// Generates the 1024px App Store icon: a cream receipt with a zigzag bottom
// edge on the brand terracotta gradient (Theme.swift palette). Run from the
// repo root:  swift scripts/generate-app-icon.swift
// The output PNG is committed; this script exists to regenerate it.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast = opaque bitmap: the App Store marketing icon must have NO alpha.
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha,
    ])!
}

// Brand gradient: terracotta #E8602C -> deep terracotta #C2461A (AccentTheme).
func drawBackgroundGradient() {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0xE8602C), color(0xC2461A)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0),
        options: []
    )
}

drawBackgroundGradient()

// Receipt body: cream (#FBF6F0) rect, rounded at the top, square at the bottom
// (the zigzag is cut out of the square edge below).
let receipt = CGRect(x: 292, y: 264, width: 440, height: 580)
let body = CGMutablePath()
body.addRoundedRect(in: receipt, cornerWidth: 44, cornerHeight: 44)
body.addRect(CGRect(x: receipt.minX, y: receipt.minY, width: receipt.width, height: 60))
ctx.addPath(body)
ctx.setFillColor(color(0xFBF6F0))
ctx.fillPath()

// Zigzag bottom edge: clip to 8 notch triangles, redraw the same gradient so
// the notches read as cut-outs revealing the background.
ctx.saveGState()
let teeth = 8
let toothW = receipt.width / CGFloat(teeth)
let notches = CGMutablePath()
for i in 0..<teeth {
    let x0 = receipt.minX + CGFloat(i) * toothW
    notches.move(to: CGPoint(x: x0, y: receipt.minY))
    notches.addLine(to: CGPoint(x: x0 + toothW / 2, y: receipt.minY + 34))
    notches.addLine(to: CGPoint(x: x0 + toothW, y: receipt.minY))
    notches.closeSubpath()
}
ctx.addPath(notches)
ctx.clip()
drawBackgroundGradient()
ctx.restoreGState()

// Receipt detail: three faded item lines + one bold total bar.
ctx.setFillColor(color(0xC2461A, alpha: 0.28))
for (i, w) in [292, 236, 264].enumerated() {
    ctx.fill(CGRect(x: Int(receipt.minX) + 56, y: 716 - i * 84, width: w, height: 26))
}
ctx.setFillColor(color(0xC2461A))
ctx.fill(CGRect(x: Int(receipt.minX) + 56, y: 396, width: 174, height: 34))

let image = ctx.makeImage()!
let outPath = "Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("wrote \(outPath)")
```

- [ ] **Step 2: Create the asset catalog scaffolding**

`Snapceipt/Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

`Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` (single-size icon, iOS 17 target):

```json
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Generate the PNG and verify it**

```bash
mkdir -p Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset
swift scripts/generate-app-icon.swift
sips -g pixelWidth -g pixelHeight -g hasAlpha Snapceipt/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
Expected: `pixelWidth: 1024`, `pixelHeight: 1024`, `hasAlpha: no` (alpha would be rejected at App Store upload).

- [ ] **Step 4: Point the build at the icon set in `project.yml`**

Add one line to the `Snapceipt` target's `settings.base` (alongside `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS`):

```yaml
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

- [ ] **Step 5: Regenerate, build, and confirm the icon is compiled in**

```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build build 2>&1 | tail -3
ls build/Build/Products/Debug-iphonesimulator/Snapceipt.app/ | grep -i -E "AppIcon|Assets"
```
Expected: `** BUILD SUCCEEDED **` and the app bundle contains `Assets.car` (the compiled catalog) and `AppIcon60x60@2x.png` (or similar icon derivative).

- [ ] **Step 6: Commit (script AND generated PNG)**

```bash
git add scripts/generate-app-icon.swift Snapceipt/Resources/Assets.xcassets project.yml
git commit -m "feat(beta): generated app icon + asset catalog"
```

---

### Task 5: Privacy manifest (`PrivacyInfo.xcprivacy`)

**Files:**
- Create: `Snapceipt/PrivacyInfo.xcprivacy`

- [ ] **Step 1: Create `Snapceipt/PrivacyInfo.xcprivacy`**

Grounded in the actual code audit: UserDefaults is used (AppLaunch, ProfilesStore, AppLockController, etc. → reason `CA92.1`); no file-timestamp, disk-space, system-boot-time, or active-keyboard APIs found; no tracking of any kind. Data collected: email (account), purchase history (receipts/transactions), user ID — all linked, app-functionality only.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeEmailAddress</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypePurchaseHistory</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeUserID</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<true/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

> **Executed note:** quality review expanded the collected-data list with five more
> types matching the code + privacy policy — `Name` (SIWA fullName), `PhotosorVideos`
> (receipt images), `DeviceID` (push token), `OtherFinancialInfo` (income/budgets/tax),
> `OtherUserContent` (notes/clients/loyalty/vehicles) — same flags (linked,
> app-functionality, no tracking). `Snapceipt/PrivacyInfo.xcprivacy` (8 types) is
> canonical; mirror it when filling the ASC App Privacy questionnaire pre-App-Store.

- [ ] **Step 2: Verify it lands in the app bundle**

```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build build 2>&1 | tail -3
ls build/Build/Products/Debug-iphonesimulator/Snapceipt.app/PrivacyInfo.xcprivacy
```
Expected: `** BUILD SUCCEEDED **` and the `ls` finds the file (XcodeGen bundles non-source files under `Snapceipt/` as resources automatically).

- [ ] **Step 3: Commit**

```bash
git add Snapceipt/PrivacyInfo.xcprivacy
git commit -m "feat(beta): privacy manifest (no tracking, UserDefaults CA92.1)"
```

---

### Task 6: Signing settings — team ID + Release manual signing

**[USER INPUT required: `TEAM_ID`]** — ask the user for their 10-character Apple Team ID (developer.apple.com → Membership) before this task.

> **Executed note:** run with `DEVELOPMENT_TEAM` deferred — the value arrives via
> `beta-launch.env` (`APPLE_TEAM_ID`) and **must be written into `project.yml` +
> `xcodegen generate` before Task 13's device build**. Task 15 is covered either
> way: gym injects `DEVELOPMENT_TEAM` via xcargs from `FASTLANE_TEAM_ID`.

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Set the team and Release-only manual signing in `project.yml`**

Top-level `settings.base`: replace `DEVELOPMENT_TEAM: ""` with the real ID:

```yaml
    DEVELOPMENT_TEAM: "<TEAM_ID>"   # user-supplied, e.g. ABCDE12345
```

`Snapceipt` target `settings`: extend the existing `configs.Release` block (created in Task 3 for the Release entitlements) with the manual-signing keys. Debug stays Automatic from the top-level default, so simulator dev workflows are untouched; Release goes manual because fastlane match owns the distribution profile:

```yaml
    settings:
      base:
        # ... existing keys unchanged ...
      configs:
        Release:
          CODE_SIGN_ENTITLEMENTS: Snapceipt/Snapceipt.Release.entitlements   # from Task 3
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: "Apple Distribution"
          PROVISIONING_PROFILE_SPECIFIER: "match AppStore app.snapceipt.Snapceipt"
```

- [ ] **Step 2: Verify Debug/simulator builds still work**

```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **` (the manual-signing block only affects Release; the profile it names doesn't exist until Task 12, which is fine).

- [ ] **Step 3: Run the iOS test suites (baseline guard, spec §8)**

Tasks 3–6 restructured `project.yml` three times — this is the point to prove the iOS baselines didn't move:

```bash
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` — SnapceiptTests and SnapceiptUITests all green (this milestone makes no behavioral code change, so any failure traces back to the project.yml edits).

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "feat(beta): real team id + Release manual signing for match"
```

---

### Task 7: Fastlane scaffold

**Files:**
- Create: `Gemfile`
- Create: `fastlane/Appfile`
- Create: `fastlane/Matchfile`
- Create: `fastlane/Fastfile`
- Create: `fastlane/.env.example`
- Modify: `.gitignore`

- [ ] **Step 1: Install a modern Ruby (system Ruby 2.6 is too old for fastlane)**

```bash
brew install ruby
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
ruby -v   # expect ruby 3.x
gem install bundler
```
Note for the user: add the `export PATH=...` line to `~/.zshrc` so every future `fastlane` invocation finds Ruby 3 (every `bundle exec fastlane …` command in this plan assumes it).

- [ ] **Step 2: Create `Gemfile`**

```ruby
source "https://rubygems.org"

gem "fastlane"
```

- [ ] **Step 3: Create `fastlane/Appfile`**

```ruby
app_identifier("app.snapceipt.Snapceipt")
team_id(ENV["FASTLANE_TEAM_ID"])
```

- [ ] **Step 4: Create `fastlane/Matchfile`**

```ruby
git_url(ENV["MATCH_GIT_URL"])
storage_mode("git")
type("appstore")
app_identifier(["app.snapceipt.Snapceipt"])
```

- [ ] **Step 5: Create `fastlane/Fastfile`**

```ruby
default_platform(:ios)

platform :ios do
  # All lanes auth via the ASC API key — never interactive Apple ID + 2FA.
  private_lane :asc_api_key do
    app_store_connect_api_key(
      key_id: ENV.fetch("ASC_KEY_ID"),
      issuer_id: ENV.fetch("ASC_ISSUER_ID"),
      key_filepath: ENV.fetch("ASC_KEY_PATH")
    )
  end

  desc "Sync App Store signing certs/profiles (first run creates them; new machines pull them)"
  lane :certs do
    match(type: "appstore", readonly: false, api_key: asc_api_key)
  end

  desc "Build and upload a TestFlight beta to the external 'Beta' group"
  lane :beta do
    ensure_git_status_clean
    # project.yml is the source of truth; the .xcodeproj is gitignored.
    sh("cd .. && xcodegen generate")
    api_key = asc_api_key
    match(type: "appstore", readonly: true, api_key: api_key)
    # Build numbers come from TestFlight, not local state — nothing to drift.
    build_num = latest_testflight_build_number(api_key: api_key, initial_build_number: 0) + 1
    gym(
      scheme: "Snapceipt",
      export_method: "app-store",
      xcargs: "CURRENT_PROJECT_VERSION=#{build_num}",
      export_options: {
        provisioningProfiles: {
          "app.snapceipt.Snapceipt" => "match AppStore app.snapceipt.Snapceipt"
        }
      }
    )
    pilot(
      api_key: api_key,
      # Spec §7: changelog prompted at run time; env var override for
      # non-interactive runs.
      changelog: ENV["BETA_CHANGELOG"] || prompt(text: "Changelog for this build: "),
      groups: ["Beta"],
      distribute_external: true
    )
  end
end
```

- [ ] **Step 6: Create `fastlane/.env.example`**

```bash
# Copy to fastlane/.env (gitignored) and fill in. Never commit real values.

# App Store Connect API key — ASC > Users and Access > Integrations (role: App Manager)
ASC_KEY_ID=ABC123XYZ9
ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
ASC_KEY_PATH=/Users/you/secrets/AuthKey_ABC123XYZ9.p8

# Apple Developer Team ID — developer.apple.com > Membership
FASTLANE_TEAM_ID=ABCDE12345

# fastlane match cert storage: a PRIVATE git repo + its encryption passphrase
MATCH_GIT_URL=git@github.com:qiguangyang/snapceipt-certs.git
MATCH_PASSWORD=keep-this-in-your-password-manager
```

- [ ] **Step 7: Append the fastlane section to `.gitignore`**

```gitignore

# fastlane
fastlane/.env
fastlane/report.xml
fastlane/README.md
fastlane/test_output/
*.ipa
*.dSYM.zip
```

> **Executed note:** quality review hardened the scaffold beyond the blocks above:
> Ruby pinned via `.ruby-version` (4.0.5) + Gemfile `ruby file:` directive; the
> changelog prompt hoisted to the top of the `beta` lane (before the 10-minute
> build); gym's `xcargs` also passes `DEVELOPMENT_TEAM=#{ENV.fetch("FASTLANE_TEAM_ID")}`
> so archives resolve the match profile even before project.yml carries the team.
> The committed `fastlane/Fastfile` is canonical.

- [ ] **Step 8: Install and verify the lanes parse**

(Every `bundle`/`fastlane` invocation in this plan re-exports the Homebrew Ruby PATH — plan steps run in fresh shells, and falling back to system Ruby 2.6 fails.)

```bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle install
bundle exec fastlane lanes
```
Expected: `bundle install` resolves fastlane; `lanes` output lists `ios beta` and `ios certs` with their descriptions (no Ruby parse errors).

- [ ] **Step 9: Commit**

```bash
git add Gemfile Gemfile.lock fastlane/Appfile fastlane/Matchfile fastlane/Fastfile fastlane/.env.example .gitignore
git commit -m "feat(beta): fastlane pipeline (match + gym + pilot, beta/certs lanes)"
```

---

### Task 8: [USER] Cloudflare + DeepSeek prerequisites

No repo files. The user performs these; the executor verifies.

- [ ] **Step 1 [USER]: Add the `snapceipt.cc` zone to Cloudflare**

Dashboard (techsiderau@gmail.com account, id `bb4412973b5e4f6d7a10a4e68b713177`) → Add a domain → `snapceipt.cc` → follow the nameserver instructions at the registrar. This is the longest pole (propagation up to hours) — start it first.

- [ ] **Step 2 [USER]: Log wrangler into the right account**

```bash
npx --yes wrangler@4 login
```

- [ ] **Step 3 [USER]: Have a funded DeepSeek API key ready** (platform.deepseek.com → API keys).

- [ ] **Step 4: Verify all three**

```bash
npx --yes wrangler@4 whoami            # expect the techsiderau account / bb44... id
dig +short NS snapceipt.cc             # expect *.ns.cloudflare.com nameservers
```
Expected: whoami names the right account; the NS records point at Cloudflare (zone active).

---

### Task 9: Backend production deploy

Depends on: Tasks 1, 8.

- [ ] **Step 1: Dry run (read-only)**

```bash
DRY_RUN=1 ./scripts/deploy.sh
```
Expected: wrangler v4 confirmed, `deploy --dry-run` validates, D1/KV/R2 inventories print, "No changes made."

- [ ] **Step 2: Live deploy** (ask the user for the DeepSeek key; don't echo it)

```bash
DEEPSEEK_API_KEY=<from user> ./scripts/deploy.sh
```
Expected: D1/KV/R2 ensured, real ids patched into `wrangler.jsonc`, secrets stored, Email Sending onboarding kicked off (SPF/DKIM auto-injected; 5–15 min), remote migrations applied, Worker deployed. The Task 1 `routes` entry attaches `api.snapceipt.cc` during this deploy.

- [ ] **Step 3: Smoke-test the API over the custom domain**

```bash
curl -s https://api.snapceipt.cc/health
```
Expected: `{"ok":true,"service":"snapceipt-api"}`. If DNS hasn't propagated yet, wait and retry (the deploy script also prints the `*.workers.dev` fallback URL). If the `*.workers.dev` URL works but `api.snapceipt.cc` still fails after DNS has propagated, the custom-domain attach failed during deploy (zone wasn't fully active yet) — re-run `npx --yes wrangler@4 deploy` and re-curl.

- [ ] **Step 4: Smoke-test real email delivery**

```bash
curl -s -i -X POST https://api.snapceipt.cc/auth/magic-link/request \
  -H 'content-type: application/json' \
  -d '{"email":"qiguangyang@gmail.com"}' | head -1
```
Expected: `HTTP/2 202` with an **empty body — this is intentional** (the endpoint always returns 202 regardless of account state, for anti-enumeration; `src/routes/auth.ts`). The real success signal: within ~2 minutes a magic-link email from `noreply@snapceipt.cc` lands in that inbox (check spam the first time — fresh domain). If `env.EMAIL.send` errors, Email Sending onboarding hasn't finished: `npx --yes wrangler@4 email sending dns get snapceipt.cc` to check, wait, retry.

- [ ] **Step 5: Commit the patched `wrangler.jsonc`**

The deploy script replaced the placeholder D1/KV ids and added `account_id` — these are not secrets.

```bash
git add wrangler.jsonc
git commit -m "chore(beta): real Cloudflare resource ids + account id from provisioning"
```

---

### Task 10: Site deploy + support@ forwarding

Depends on: Tasks 2, 8.

- [ ] **Step 1: Deploy the site Worker**

From the repo root:

```bash
npx --yes wrangler@4 deploy -c site/wrangler.jsonc
```
Expected: deploys `snapceipt-site` with custom domains `snapceipt.cc` and `www.snapceipt.cc`.

- [ ] **Step 2: Verify the live pages**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://snapceipt.cc/privacy   # expect 200
curl -s https://snapceipt.cc/privacy | grep -c "DeepSeek"               # expect >= 1
curl -s -o /dev/null -w "%{http_code}\n" https://snapceipt.cc/support   # expect 200
```

- [ ] **Step 3 [USER]: Create the support@ forward**

Dashboard → `snapceipt.cc` zone → Email → Email Routing → Routing rules → create `support@snapceipt.cc` → forward to `qiguangyang@gmail.com` (verify the destination address via the confirmation email Cloudflare sends).

- [ ] **Step 4: Verify the forward**

Send any email to `support@snapceipt.cc` from a personal account; expect it in the Gmail inbox within a minute.

---

### Task 11: [USER] App ID + APNs key → Worker push secrets

Depends on: Tasks 8, 9 (wrangler login; the Worker must be deployed so `secret put` has a target). Produces inputs for Tasks 12–13.

- [ ] **Step 1 [USER]: Register the App ID**

developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → `+` → App IDs → App. Bundle ID **explicit** `app.snapceipt.Snapceipt`, description "Snapceipt". Capabilities: check **Sign In with Apple** and **Push Notifications**. Register.

- [ ] **Step 2 [USER]: Create the APNs auth key**

Same portal → Keys → `+` → name "Snapceipt APNs", check **Apple Push Notifications service (APNs)** → Register → **Download the `.p8` now** (one-time download) → note the **Key ID**. Store the file in the password manager AND at a local path outside the repo (`.gitignore` already excludes `*.p8`, but don't tempt fate).

- [ ] **Step 3: Set the three push secrets on the Worker**

```bash
npx --yes wrangler@4 secret put APNS_KEY < /path/to/AuthKey_<KEYID>.p8
printf '%s' '<KEYID>' | npx --yes wrangler@4 secret put APNS_KEY_ID
printf '%s' '<TEAM_ID>' | npx --yes wrangler@4 secret put APNS_TEAM_ID
```

- [ ] **Step 4: Verify**

```bash
npx --yes wrangler@4 secret list
```
Expected: `JWT_SIGNING_KEY`, `DEEPSEEK_API_KEY`, `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`. (Until a real device registers a token, push remains untestable — `src/lib/apns.ts` stops stubbing as soon as `APNS_KEY` exists; the end-to-end check is Task 16 step 4.)

---

### Task 12: [USER] ASC app record + API key + match bootstrap

Depends on: Tasks 7, 11 (App ID must exist).

- [ ] **Step 1 [USER]: Create the App Store Connect app record**

appstoreconnect.apple.com → My Apps → `+` → New App: platform iOS, name **Snapceipt** (if taken, fall back to "Snapceipt — Receipts & Tax"; the bundle ID is unaffected), primary language **English (Australia)**, bundle ID `app.snapceipt.Snapceipt`, SKU `snapceipt-ios`.

- [ ] **Step 2 [USER]: Create the ASC API key**

ASC → Users and Access → Integrations → App Store Connect API → Team Keys → `+`: name "fastlane", role **App Manager**. Download the `.p8` (one-time), note the **Key ID** and the **Issuer ID** shown at the top of the page.

- [ ] **Step 3 [USER]: Create the match cert repo**

Create a **private** GitHub repo (e.g. `qiguangyang/snapceipt-certs`, empty, no README needed) and pick a strong `MATCH_PASSWORD`; store both in the password manager.

- [ ] **Step 4: Fill in `fastlane/.env`**

```bash
cp fastlane/.env.example fastlane/.env
# then edit fastlane/.env with the real ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH /
# FASTLANE_TEAM_ID / MATCH_GIT_URL / MATCH_PASSWORD values from steps 1-3 + Task 6.
git check-ignore fastlane/.env   # expect: fastlane/.env (it must be ignored)
```

- [ ] **Step 5: Bootstrap match (creates the distribution cert + profile)**

```bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle exec fastlane certs
```
Expected: match authenticates via the ASC API key (no Apple ID/2FA prompt — the `certs` lane passes `api_key`), clones the cert repo, creates an Apple Distribution certificate and an App Store provisioning profile named `match AppStore app.snapceipt.Snapceipt`, encrypts both into the repo, and prints a green summary table. The first run asks once for `MATCH_PASSWORD` unless it's already in `fastlane/.env`. Recovery if the repo/passphrase is ever lost: `bundle exec fastlane match nuke distribution`, then re-run `certs`.

---

### Task 13: On-device Debug smoke test

Depends on: Tasks 3–6, 9, 11 (App ID + capabilities registered; team set; production backend live — the smoke runs against `api.snapceipt.cc`). Catches SIWA/camera/Face ID problems before burning a TestFlight cycle.

- [ ] **Step 1 [USER]: Run a Debug build on a real iPhone**

First (executor): write `APPLE_TEAM_ID` from `beta-launch.env` into `project.yml`
`DEVELOPMENT_TEAM` and run `xcodegen generate` — the device build fails on an
empty team. Then: plug in the iPhone, trust the computer. Then either run from Xcode (open `Snapceipt.xcodeproj`, select the device, Run), or:

```bash
xcodegen generate
xcodebuild -project Snapceipt.xcodeproj -scheme Snapceipt \
  -destination 'platform=iOS,name=<device name>' -allowProvisioningUpdates build
```
Expected: automatic signing creates a development profile including the SIWA + push entitlements (works because the App ID now exists with those capabilities).

- [ ] **Step 2 [USER]: Smoke on the device (against production)**

1. **Sign in with Apple** → completes, lands on Home. (This exercises the Task 1 `APPLE_BUNDLE_ID` fix end-to-end: the token `aud` is now `app.snapceipt.Snapceipt`.)
2. Capture a receipt with the camera → extraction fills merchant/total.
3. Settings → App Lock on → background the app → reopen → **Face ID prompt appears** (and shows the usage description on first ask).

Known-good anomaly: push won't arrive on this Debug build — it gets *sandbox* APNs tokens and the backend targets production APNs. TestFlight builds (production tokens) are the real test.

---

### Task 14: [USER] TestFlight test information + Beta group

Depends on: Tasks 10 (privacy URL live), 12 (app record).

- [ ] **Step 1 [USER]: Fill in TestFlight Test Information**

ASC → Snapceipt → TestFlight → Test Information: beta app description (what Snapceipt does + what to test), feedback email `support@snapceipt.cc`, **privacy policy URL `https://snapceipt.cc/privacy`**.

- [ ] **Step 2 [USER]: Create the external group**

TestFlight → External Testing → `+` group named **Beta** (the Fastfile distributes to this exact name) → add testers by email.

- [ ] **Step 3 [USER]: Beta review notes**

In the group's review information: sign-in instructions — "Use Sign in with Apple with any Apple ID (no pre-made account needed). Alternative: enter any email on the sign-in screen and open the magic link emailed to it."

---

### Task 15: First beta upload

Depends on: Tasks 7, 12, 14.

- [ ] **Step 1: Run the beta lane**

```bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
BETA_CHANGELOG="First Snapceipt beta." bundle exec fastlane beta
```
Expected: clean-git check passes → xcodegen → match (readonly) finds the Task 12 profile → build number 1 (TestFlight has none yet) → gym archives and exports with `app-store` → pilot uploads and assigns the **Beta** group, which submits the build for Beta App Review.

Failure playbook: a "Processing" hang in ASC → re-run the lane (build number auto-increments); a beta-review rejection → fix what's named, re-run; gym signing errors → re-check Task 6's `PROVISIONING_PROFILE_SPECIFIER` matches the match profile name exactly.

- [ ] **Step 2: Verify in ASC**

TestFlight → iOS builds: the build reaches **Ready to Submit → In Beta Review → Approved**; testers get the invite email once approved.

---

### Task 16: Beta smoke checklist (spec §8)

Depends on: Task 15 (build approved, installed via TestFlight on a real device).

- [ ] **Step 1 [USER]: Run the core-loop checklist and record results**

1. Sign in with Apple; sign out; sign in again via magic link (email arrives, link opens the app through `https://api.snapceipt.cc/auth/magic` → `snapceipt://`).
2. Capture a real paper receipt → extraction fills merchant/total/GST.
3. Force-quit, delete the app, reinstall from TestFlight, sign in → data syncs back.
4. Create a budget with a cap just above current month spend, add a transaction crossing the threshold → push arrives within the hour (cron is hourly) → tapping it deep-links to the budget.
5. Reports tab renders; export CSV to a second email address → email arrives with the CSV.
6. Business profile: create + send a quote → recipient gets the PDF email.

- [ ] **Step 2: Close out**

Any failure here is a bug to triage individually (superpowers:systematic-debugging), not a plan step. When all six pass, the spec's success criteria are met — the beta is live.
