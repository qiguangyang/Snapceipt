#!/usr/bin/env bash
# Journey-suite runner: boots `wrangler dev` (local, E2E seams) against a persist
# dir, runs a chosen subset of SnapceiptUITests classes (default: LiveJourneyUITests),
# tears the Worker down. PROD-SAFE: only binds loopback / local Miniflare.
# Optional IOS_E2E_PORT, IOS_TEST_DESTINATION and IOS_DERIVED_DATA override local setup.
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

# Overrides keep the existing default while supporting multiple installed runtimes/services.
PORT="${IOS_E2E_PORT:-8787}"
BASE="http://127.0.0.1:$PORT"
WPID=""
cleanup() {
  [[ -n "${WPID:-}" ]] && kill "$WPID" 2>/dev/null || true
  [[ -n "${WPID:-}" ]] && wait "$WPID" 2>/dev/null || true
  [[ "$CLEAN_PERSIST" -eq 1 ]] && rm -rf "$PERSIST" || true
}
trap cleanup EXIT

# Refuse an occupied port before a health response from another app can look like ours.
node --input-type=module - "$PORT" <<'JS'
import net from "node:net";
const server = net.createServer();
server.on("error", error => { console.error(`Live harness port unavailable: ${error.message}`); process.exit(1); });
server.listen(Number(process.argv[2]), "127.0.0.1", () => server.close());
JS

echo "Applying D1 migrations (local) to $PERSIST ..."
CI=1 npx wrangler d1 migrations apply snapceipt --local --persist-to "$PERSIST"

echo "Starting wrangler dev (E2E_TEST_MODE, persist=$PERSIST) ..."
node node_modules/wrangler/bin/wrangler.js dev --local --persist-to "$PERSIST" --port "$PORT" --ip 127.0.0.1 \
  --var E2E_TEST_MODE:1 \
  --var E2E_EXTRACT_MODE:1 \
  --var JWT_SIGNING_KEY:dev-e2e-signing-key-0123456789-abcdef \
  --var APPLE_BUNDLE_ID:com.snapceipt.app \
  > /tmp/snapceipt-e2e-journeys-wrangler.log 2>&1 &
WPID=$!

echo "Waiting for the Worker on $BASE/health ..."
for _ in $(seq 1 120); do
  kill -0 "$WPID" 2>/dev/null || { echo "Owned Worker exited; see /tmp/snapceipt-e2e-journeys-wrangler.log"; exit 1; }
  curl -sf "$BASE/health" >/dev/null && break
  sleep 0.5
done
kill -0 "$WPID" 2>/dev/null || { echo "Owned Worker exited"; exit 1; }
curl -sf "$BASE/health" >/dev/null \
  || { echo "Worker did not come up; see /tmp/snapceipt-e2e-journeys-wrangler.log"; exit 1; }

# Health is accepted only if this harness owns the actual listening workerd process.
LISTENERS="$(lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN)"
[[ -n "$LISTENERS" ]] || { echo "No listener on requested port"; exit 1; }
for LISTENER in $LISTENERS; do
  ANCESTOR="$LISTENER"
  while [[ "$ANCESTOR" != "$WPID" && "$ANCESTOR" != "1" && -n "$ANCESTOR" ]]; do
    ANCESTOR="$(ps -o ppid= -p "$ANCESTOR" | tr -d ' ')"
  done
  [[ "$ANCESTOR" == "$WPID" ]] || { echo "Port $PORT belongs to an unrelated process; refusing live tests"; exit 1; }
  echo "Verified owned listener $LISTENER beneath Worker $WPID on port $PORT"
done
echo "Backend up. Running journey classes: ${CLASSES[*]}"
xcodegen generate
ONLY=()
for c in "${CLASSES[@]}"; do ONLY+=("-only-testing:SnapceiptUITests/$c"); done
XCODE_ARGS=()
if [[ -n "${IOS_DERIVED_DATA:-}" ]]; then XCODE_ARGS+=("-derivedDataPath" "$IOS_DERIVED_DATA"); fi
TEST_RUNNER_E2E_LIVE=1 TEST_RUNNER_API_BASE_URL="$BASE" \
  xcodebuild test -scheme Snapceipt \
  -destination "${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}" \
  "${XCODE_ARGS[@]}" \
  "${ONLY[@]}"
