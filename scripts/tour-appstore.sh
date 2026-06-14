#!/usr/bin/env bash
# App Store screenshot generator. Reuses ScreenshotTourUITests (the same suite
# scripts/tour.sh drives) but renders the curated hero subset on the two device
# sizes App Store Connect requires for an iPhone-only app:
#   6.7" -> iPhone 16 Plus    (1290x2796)
#   6.5" -> iPhone 11 Pro Max (1242x2688)
# Output: artifacts/appstore/<run-id>/<size>/<screen>-<state>.png  (size = 6.7|6.5)
# Usage:  scripts/tour-appstore.sh <run-id>
#
# Note: runs two full simulator sessions (~10-15 min total). Simulators must be
# available in your local Xcode installation. The generated PNGs are gitignored
# (artifacts/ is in .gitignore); copy into fastlane/screenshots/en-AU/ to upload.
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_ID="${1:?usage: scripts/tour-appstore.sh <run-id>}"
OUT="artifacts/appstore/${RUN_ID}"
rm -rf "$OUT"; mkdir -p "$OUT"

# Curated hero screens (the method -> shoot() PNGs it emits are the ones Apple shows).
# Only the 4 most representative areas; Apple allows up to 10, 3-5 is plenty for GA.
HERO_METHODS=(
  test_area03_home
  test_area05_reports
  test_area09_quotes
  test_area14_bas
)

# shoot_size <size-label> <device-name>
# Boots the named simulator, runs the hero subset, and exports PNGs to $OUT/$label/.
shoot_size() {
  local label="$1" device="$2"
  local dest="platform=iOS Simulator,name=${device}"
  local bundle="artifacts/appstore/_result-${RUN_ID}-${label}.xcresult"
  local export_dir="artifacts/appstore/_export-${RUN_ID}-${label}"
  rm -rf "$bundle" "$export_dir"

  echo "==> appstore: booting ${device} (${label}\")..."
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b || true
  # Pin status bar to Apple's canonical marketing state: 9:41, full battery + bars.
  xcrun simctl status_bar "$device" override \
    --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi

  local only=()
  for m in "${HERO_METHODS[@]}"; do
    only+=("-only-testing:SnapceiptUITests/ScreenshotTourUITests/$m")
  done

  echo "==> appstore: running hero subset on ${device}..."
  xcodebuild test -scheme Snapceipt -destination "$dest" \
    "${only[@]}" -resultBundlePath "$bundle" 2>&1 | tail -6

  # Export attachments and rename them (strip xcresulttool's _<idx>_<UUID> suffix,
  # same idiom as scripts/tour.sh).
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$export_dir"
  local dest_dir="$OUT/$label"; mkdir -p "$dest_dir"
  python3 - "$export_dir" "$dest_dir" <<'PY'
import json, os, re, shutil, sys
export_dir, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(export_dir, "manifest.json")))
count = 0
for entry in manifest:
    for att in entry.get("attachments", []):
        src = att.get("exportedFileName")
        name = att.get("suggestedHumanReadableName") or att.get("name") or src
        if not src:
            continue
        # Strip xcresulttool's "_<idx>_<UUID>" suffix (same idiom as scripts/tour.sh).
        name = re.sub(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?=\.|$)", "", name)
        name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
        if not name.lower().endswith(".png"):
            name += ".png"
        shutil.copyfile(os.path.join(export_dir, src), os.path.join(out, name))
        count += 1
print(f"appstore: exported {count} PNG(s) to {out}")
PY
  xcrun simctl status_bar "$device" clear || true
}

# Regenerate the .xcodeproj from project.yml (the xcodeproj is gitignored).
/opt/homebrew/bin/xcodegen generate

shoot_size "6.7" "iPhone 16 Plus"
shoot_size "6.5" "iPhone 11 Pro Max"

echo "appstore tour done: $OUT"
echo ""
echo "To verify pixel dimensions (must be 1290x2796 for 6.7\", 1242x2688 for 6.5\"):"
echo "  for f in ${OUT}/6.7/*.png; do sips -g pixelWidth -g pixelHeight \"\$f\"; done"
echo "  for f in ${OUT}/6.5/*.png; do sips -g pixelWidth -g pixelHeight \"\$f\"; done"
echo ""
echo "To upload: copy PNGs into fastlane/screenshots/en-AU/ then run: bundle exec fastlane release"
