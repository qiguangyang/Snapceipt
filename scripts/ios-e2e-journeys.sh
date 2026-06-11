#!/usr/bin/env bash
# Journey-suite runner: boots `wrangler dev` (local, E2E seams) against a persist
# dir, runs a chosen subset of SnapceiptUITests classes (default: LiveJourneyUITests),
# tears the Worker down. PROD-SAFE: only ever binds 127.0.0.1:8787 / local Miniflare.
#
#   Usage:
#     scripts/ios-e2e-journeys.sh [--persist DIR] CLASS [CLASS ...]
#   Examples:
#     scripts/ios-e2e-journeys.sh LiveJourneyUITests
#     scripts/ios-e2e-journeys.sh --persist .e2e-journey-state ProfileScopingUITests
#
# --persist DIR : use a STABLE persist dir (survives restarts, for crash-recovery
#                 journeys). Without it: an ephemeral mktemp dir, removed on exit.
set -euo pipefail
cd "$(dirname "$0")/.."

PERSIST=""
CLEAN_PERSIST=0
CLASSES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persist) PERSIST="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) CLASSES+=("$1"); shift ;;
  esac
done
if [[ ${#CLASSES[@]} -eq 0 ]]; then CLASSES=("LiveJourneyUITests"); fi
if [[ -z "$PERSIST" ]]; then PERSIST="$(mktemp -d)"; CLEAN_PERSIST=1; fi

WPID=""
cleanup() {
  [[ -n "${WPID:-}" ]] && kill "$WPID" 2>/dev/null || true
  [[ "$CLEAN_PERSIST" -eq 1 ]] && rm -rf "$PERSIST" || true
}
trap cleanup EXIT

echo "Applying D1 migrations (local) to $PERSIST ..."
CI=1 npx wrangler d1 migrations apply snapceipt --local --persist-to "$PERSIST"

echo "Starting wrangler dev (E2E_TEST_MODE, persist=$PERSIST) ..."
npx wrangler dev --local --persist-to "$PERSIST" --port 8787 --ip 127.0.0.1 \
  --var E2E_TEST_MODE:1 \
  --var E2E_EXTRACT_MODE:1 \
  --var JWT_SIGNING_KEY:dev-e2e-signing-key-0123456789-abcdef \
  --var APPLE_BUNDLE_ID:com.snapceipt.app \
  > /tmp/snapceipt-e2e-journeys-wrangler.log 2>&1 &
WPID=$!

echo "Waiting for the Worker on http://127.0.0.1:8787/health ..."
for _ in $(seq 1 120); do
  curl -sf http://127.0.0.1:8787/health >/dev/null && break
  sleep 0.5
done
curl -sf http://127.0.0.1:8787/health >/dev/null \
  || { echo "Worker did not come up; see /tmp/snapceipt-e2e-journeys-wrangler.log"; exit 1; }

echo "Backend up. Running journey classes: ${CLASSES[*]}"
xcodegen generate
ONLY=()
for c in "${CLASSES[@]}"; do ONLY+=("-only-testing:SnapceiptUITests/$c"); done
TEST_RUNNER_E2E_LIVE=1 TEST_RUNNER_API_BASE_URL=http://127.0.0.1:8787 \
  xcodebuild test -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  "${ONLY[@]}"
