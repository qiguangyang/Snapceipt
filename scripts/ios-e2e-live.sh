#!/usr/bin/env bash
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
  > /tmp/snapceipt-e2e-wrangler.log 2>&1 &
WPID=$!

echo "Waiting for the Worker on http://127.0.0.1:8787/health ..."
for _ in $(seq 1 120); do
  curl -sf http://127.0.0.1:8787/health >/dev/null && break
  sleep 0.5
done
curl -sf http://127.0.0.1:8787/health >/dev/null || { echo "Worker did not come up; see /tmp/snapceipt-e2e-wrangler.log"; exit 1; }

echo "Backend up. Running the live smoke ..."
xcodegen generate
TEST_RUNNER_E2E_LIVE=1 TEST_RUNNER_API_BASE_URL=http://127.0.0.1:8787 \
  xcodebuild test -scheme Snapceipt \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:SnapceiptUITests/LiveSmokeUITests
