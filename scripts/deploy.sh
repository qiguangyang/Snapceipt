#!/usr/bin/env bash
#
# Snapceipt API — production provisioning + deploy (go-live Approach 1, spec §7).
#
# Idempotent: safe to re-run (get-or-create resources, secrets overwrite).
#
#   Validate only (no mutations, no deploy):   DRY_RUN=1 ./scripts/deploy.sh
#   Live provision + deploy:                                ./scripts/deploy.sh
#
# Required env for a LIVE run (ignored in DRY_RUN):
#   DEEPSEEK_API_KEY   - your DeepSeek API key (required)
# Optional env:
#   JWT_SIGNING_KEY    - HS256 signing key (auto-generated via `openssl rand` if unset)
#
# NOTE: wrangler.jsonc carries a custom-domain route for api.snapceipt.cc, so the
# snapceipt.cc zone MUST exist on this account before a live run — `wrangler deploy`
# attaches the domain unconditionally and (under set -e) aborts this script if the
# zone is missing. Add the zone first; DRY_RUN=1 is unaffected (no deploy).
#
set -euo pipefail

# --- constants ---------------------------------------------------------------
ACCOUNT_ID="bb4412973b5e4f6d7a10a4e68b713177"   # techsiderau@gmail.com
DB_NAME="snapceipt"
R2_BUCKET="snapceipt-receipts"
EMAIL_DOMAIN="snapceipt.cc"
CUSTOM_DOMAIN="api.snapceipt.cc"
# Pin wrangler v4 for deploy WITHOUT changing the project's devDependency: the test
# suite runs on @cloudflare/vitest-pool-workers, which pins wrangler 3.x, so we must
# not bump the repo's wrangler. `npx --yes wrangler@4` fetches v4 just for deploy.
# Override with e.g. WRANGLER="npx wrangler" if you've upgraded the toolchain to v4.
WRANGLER="${WRANGLER:-npx --yes wrangler@4}"
DRY_RUN="${DRY_RUN:-0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight (runs in both modes) ------------------------------------------
log "wrangler version"
$WRANGLER --version
ver="$($WRANGLER --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "${ver%%.*}" -ge 4 ] 2>/dev/null || die "wrangler v4+ required (found '${ver:-none}'): run  npm i -D wrangler@4"

log "authenticated account"
$WRANGLER whoami 2>/dev/null | grep -iE "techsiderau|${ACCOUNT_ID}" \
  || warn "could not confirm techsiderau account from whoami — verify manually before a live run"

log "validate worker build + config  (wrangler deploy --dry-run)"
$WRANGLER deploy --dry-run

# --- DRY_RUN: read-only inventory, then stop ---------------------------------
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — resource inventory (read-only; nothing is created or deployed)"
  echo "----- D1 -----"; $WRANGLER d1 list            2>/dev/null || warn "d1 list failed"
  echo "----- KV -----"; $WRANGLER kv namespace list  2>/dev/null || warn "kv list failed"
  echo "----- R2 -----"; $WRANGLER r2 bucket list     2>/dev/null || warn "r2 list failed (R2 enabled + token scope?)"
  log "DRY_RUN complete: config is valid under wrangler ${ver}. No changes made."
  exit 0
fi

# ============================================================================
#  LIVE RUN below this line — mutates the Cloudflare account + deploys.
# ============================================================================
[ -n "${DEEPSEEK_API_KEY:-}" ] || die "DEEPSEEK_API_KEY env var is required for a live deploy."
JWT_SIGNING_KEY="${JWT_SIGNING_KEY:-$(openssl rand -base64 48)}"

# --- 1. provision D1 (get-or-create) + capture id ----------------------------
log "D1: ensure database '${DB_NAME}'"
$WRANGLER d1 create "$DB_NAME" 2>/dev/null || warn "D1 '${DB_NAME}' likely already exists — continuing"
D1_ID="$(DB_NAME="$DB_NAME" $WRANGLER d1 list --json 2>/dev/null | python3 -c '
import sys, json, os
name = os.environ["DB_NAME"]
d = json.load(sys.stdin); rows = d if isinstance(d, list) else d.get("result", [])
print(next((r.get("uuid") or r.get("database_id") or r.get("id") for r in rows if r.get("name") == name), ""))
' || echo "")"
[ -n "$D1_ID" ] || die "could not resolve D1 database_id for '${DB_NAME}'"
log "D1 id: ${D1_ID}"

# --- 2. provision KV (get-or-create) + capture id ----------------------------
log "KV: ensure namespace (binding KV)"
$WRANGLER kv namespace create KV 2>/dev/null || warn "KV namespace likely already exists — continuing"
KV_ID="$($WRANGLER kv namespace list 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
# wrangler titles the namespace "<worker>-KV"; match the KV binding by title suffix.
print(next((n["id"] for n in d if str(n.get("title","")).endswith("KV")), ""))
' || echo "")"
[ -n "$KV_ID" ] || die "could not resolve KV namespace id (binding KV)"
log "KV id: ${KV_ID}"

# --- 3. provision R2 bucket --------------------------------------------------
log "R2: ensure bucket '${R2_BUCKET}'"
$WRANGLER r2 bucket create "$R2_BUCKET" 2>/dev/null || warn "R2 bucket likely already exists — continuing"

# --- 4. patch wrangler.jsonc (real ids + account_id), abort if capture failed -
log "patch wrangler.jsonc with real ids + account_id"
sed -i.bak "s/00000000-0000-0000-0000-000000000000/${D1_ID}/" wrangler.jsonc
sed -i.bak "s/00000000000000000000000000000000/${KV_ID}/" wrangler.jsonc
if ! grep -q '"account_id"' wrangler.jsonc; then
  sed -i.bak "s/\"name\": \"snapceipt-api\",/\"name\": \"snapceipt-api\",\n  \"account_id\": \"${ACCOUNT_ID}\",/" wrangler.jsonc
fi
rm -f wrangler.jsonc.bak
grep -q "00000000" wrangler.jsonc && die "wrangler.jsonc still contains placeholder ids — id capture failed, aborting before deploy."
log "wrangler.jsonc updated (commit it after a successful deploy — resource ids are not secret)."

# --- 5. secrets (piped, never echoed) ----------------------------------------
log "secrets: JWT_SIGNING_KEY + DEEPSEEK_API_KEY"
printf '%s' "$JWT_SIGNING_KEY"  | $WRANGLER secret put JWT_SIGNING_KEY
printf '%s' "$DEEPSEEK_API_KEY" | $WRANGLER secret put DEEPSEEK_API_KEY

# --- 6. Email Sending: onboard the domain (auto-injects SPF/DKIM) -------------
log "Email Sending: onboard ${EMAIL_DOMAIN}"
$WRANGLER email sending enable "$EMAIL_DOMAIN" || warn "email enable returned non-zero (already onboarded?)"
$WRANGLER email sending dns get "$EMAIL_DOMAIN" 2>/dev/null || warn "could not fetch email DNS status"

# --- 7. apply remote migrations + deploy -------------------------------------
log "apply remote D1 migrations"
$WRANGLER d1 migrations apply "$DB_NAME" --remote
log "deploy worker"
$WRANGLER deploy

# --- 8. custom domain ---------------------------------------------------------
# api.snapceipt.cc is attached automatically by the step-7 deploy via the routes
# entry in wrangler.jsonc; the ${EMAIL_DOMAIN} zone existing on this account is a
# hard prerequisite (see header note).

# --- 9. smoke test -----------------------------------------------------------
log "smoke test"
if curl -fsS "https://${CUSTOM_DOMAIN}/health" >/dev/null 2>&1; then
  log "health OK at https://${CUSTOM_DOMAIN}/health"
else
  warn "https://${CUSTOM_DOMAIN}/health not reachable yet — attach the custom domain (+DNS propagate),"
  warn "or smoke-test the printed *.workers.dev URL:  curl <worker-url>/health"
fi

log "Deploy complete. Next: point the app at https://${CUSTOM_DOMAIN}, then verify per spec §8."
