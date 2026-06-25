#!/usr/bin/env bash
# Live e2e for the auth rate-limit fix: boots a local `wrangler dev` Worker (real rate limiter)
# and runs AuthRateLimitLiveUITests (real LiveAPIClient in the sim) against it. Proves repeated
# failed password sign-ins do NOT block a subsequent code request ("Too many attempts" bug).
#
# Usage: scripts/ios-e2e-ratelimit.sh
#   SIM_DEST="platform=iOS Simulator,id=<udid>"  # optional; defaults to iPhone 16 by name
set -euo pipefail
cd "$(dirname "$0")/.."

PERSIST=$(mktemp -d)
trap 'kill ${WPID:-} 2>/dev/null || true; rm -rf "$PERSIST"' EXIT

echo "Applying D1 migrations (local) ..."
CI=1 npx wrangler d1 migrations apply snapceipt --local --persist-to "$PERSIST"

echo "Starting wrangler dev (E2E_TEST_MODE) ..."
npx wrangler dev --local --persist-to "$PERSIST" --port 8787 --ip 127.0.0.1 \
  --var E2E_TEST_MODE:1 \
  --var JWT_SIGNING_KEY:dev-e2e-signing-key-0123456789-abcdef \
  --var APPLE_BUNDLE_ID:com.snapceipt.app \
  > /tmp/snapceipt-e2e-ratelimit-wrangler.log 2>&1 &
WPID=$!

echo "Waiting for the Worker on http://127.0.0.1:8787/health ..."
for _ in $(seq 1 120); do
  curl -sf http://127.0.0.1:8787/health >/dev/null && break
  sleep 0.5
done
curl -sf http://127.0.0.1:8787/health >/dev/null || { echo "Worker did not come up; see /tmp/snapceipt-e2e-ratelimit-wrangler.log"; exit 1; }

echo "Backend up. Running the rate-limit live e2e ..."
xcodegen generate
SIM="${SIM_DEST:-platform=iOS Simulator,name=iPhone 16}"
TEST_RUNNER_E2E_LIVE=1 TEST_RUNNER_API_BASE_URL=http://127.0.0.1:8787 \
  xcodebuild test -scheme Snapceipt \
  -destination "$SIM" \
  ${DERIVED_DATA:+-derivedDataPath "$DERIVED_DATA"} \
  -only-testing:SnapceiptUITests/AuthRateLimitLiveUITests
