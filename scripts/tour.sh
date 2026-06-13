#!/usr/bin/env bash
# Deterministic screenshot tour: boots the sim, pins the status bar, runs
# ScreenshotTourUITests, and exports each XCTAttachment PNG to
# artifacts/tour/<run-id>/<area>/<screen>-<state>.png.
#
# Usage:
#   scripts/tour.sh <run-id> [area-method ...]
#   scripts/tour.sh baseline                 # full tour, frozen as the "before" set
#   scripts/tour.sh r1 test_area08_loyalty   # re-shoot one area after a fix
set -euo pipefail
cd "$(dirname "$0")/.."

RUN_ID="${1:?usage: scripts/tour.sh <run-id> [area-method ...]}"
shift || true
DEST='platform=iOS Simulator,name=iPhone 16'
SIM_NAME='iPhone 16'
OUT="artifacts/tour/${RUN_ID}"
BUNDLE="artifacts/tour/_result-${RUN_ID}.xcresult"
rm -rf "$OUT" "$BUNDLE"
mkdir -p "$OUT"

# Map each tour method -> its area directory. (bash 3.2-safe: this machine's
# /usr/bin/env bash is /bin/bash 3.2.57 with NO associative arrays — `declare -A`
# would abort under `set -e`. Use an indexed list + a case lookup instead.)
METHODS_ALL=(
  test_area01_onboardingAuth
  test_area02_appShell
  test_area03_home
  test_area04_capture
  test_area05_reports
  test_area06_logbooks
  test_area07_budgets
  test_area08_loyalty
  test_area09_quotes
  test_area10_emailSettingsProfiles
  test_cross_emptyStates
  test_cross_accentReskin
  test_cross_largeType
)
area_for_method() {
  case "$1" in
    test_area01_onboardingAuth)        echo 01-onboarding-auth ;;
    test_area02_appShell)              echo 02-app-shell ;;
    test_area03_home)                  echo 03-home ;;
    test_area04_capture)               echo 04-capture ;;
    test_area05_reports)               echo 05-reports ;;
    test_area06_logbooks)              echo 06-logbooks ;;
    test_area07_budgets)               echo 07-budgets ;;
    test_area08_loyalty)               echo 08-loyalty ;;
    test_area09_quotes)                echo 09-quotes ;;
    test_area10_emailSettingsProfiles) echo 10-email-settings-profiles ;;
    test_cross_emptyStates)            echo _cross-empty ;;
    test_cross_accentReskin)           echo _cross-accent ;;
    test_cross_largeType)              echo _cross-xl ;;
    *)                                 echo _unsorted ;;
  esac
}

# Which methods to run (all, or the ones passed as args).
# (METHODS_ALL is never empty, so this expansion is safe under bash 3.2 `set -u`.)
if [ "$#" -gt 0 ]; then METHODS=("$@"); else METHODS=("${METHODS_ALL[@]}"); fi

# Boot the sim + pin the status bar (9:41, full battery, full bars — Apple's marketing time).
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_NAME" -b || true
xcrun simctl status_bar "$SIM_NAME" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi

/opt/homebrew/bin/xcodegen generate

# Build the -only-testing args.
ONLY=()
for m in "${METHODS[@]}"; do ONLY+=("-only-testing:SnapceiptUITests/ScreenshotTourUITests/$m"); done

xcodebuild test -scheme Snapceipt -destination "$DEST" \
  "${ONLY[@]}" -resultBundlePath "$BUNDLE" 2>&1 | tail -6

# Export attachments, then sort PNGs into <area>/<name>.png using the manifest.
EXPORT_DIR="artifacts/tour/_export-${RUN_ID}"
rm -rf "$EXPORT_DIR"
xcrun xcresulttool export attachments --path "$BUNDLE" --output-path "$EXPORT_DIR"

python3 - "$EXPORT_DIR" "$OUT" <<'PY'
import json, os, shutil, sys, re
export_dir, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(export_dir, "manifest.json")))
# manifest is a list of per-test objects; each has a testIdentifier-ish key and
# an "attachments" list with "exportedFileName" + "suggestedHumanReadableName".
AREA = {
  "test_area01_onboardingAuth":"01-onboarding-auth","test_area02_appShell":"02-app-shell",
  "test_area03_home":"03-home","test_area04_capture":"04-capture","test_area05_reports":"05-reports",
  "test_area06_logbooks":"06-logbooks","test_area07_budgets":"07-budgets","test_area08_loyalty":"08-loyalty",
  "test_area09_quotes":"09-quotes","test_area10_emailSettingsProfiles":"10-email-settings-profiles",
  "test_cross_emptyStates":"_cross-empty","test_cross_accentReskin":"_cross-accent",
  "test_cross_largeType":"_cross-xl",
}
def area_for(test_id):
    for method, dirn in AREA.items():
        if method in (test_id or ""):
            return dirn
    return "_unsorted"
count = 0
for entry in manifest:
    test_id = entry.get("testIdentifier") or entry.get("identifierURL") or entry.get("testName") or ""
    area = area_for(test_id)
    for att in entry.get("attachments", []):
        src = att.get("exportedFileName")
        name = att.get("suggestedHumanReadableName") or att.get("name") or src
        if not src: continue
        # xcresulttool suffixes the attachment name with "_<idx>_<UUID>"
        # (verified in the Task 4 probe manifest) — strip it so the file is
        # exactly the shoot() token: <screen>-<state>.png.
        name = re.sub(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?=\.|$)", "", name)
        name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
        if not name.lower().endswith(".png"): name += ".png"
        dest_dir = os.path.join(out, area)
        os.makedirs(dest_dir, exist_ok=True)
        shutil.copyfile(os.path.join(export_dir, src), os.path.join(dest_dir, name))
        count += 1
print(f"tour: exported {count} PNG(s) to {out}")
PY

# Clear the status-bar override so the sim returns to normal.
xcrun simctl status_bar "$SIM_NAME" clear || true
echo "tour done: $OUT"
