#!/usr/bin/env bash
# Build a before/after HTML gallery from two tour runs.
#   scripts/build-gallery.sh <baseline-run-id> <after-run-id>
set -euo pipefail
cd "$(dirname "$0")/.."
BEFORE="artifacts/tour/$1"
AFTER="artifacts/tour/$2"
OUT="artifacts/gallery"
mkdir -p "$OUT"
HTML="$OUT/index.html"
{
  echo '<!doctype html><meta charset="utf-8"><title>Beta hardening — before/after</title>'
  echo '<style>body{font-family:-apple-system,sans-serif;margin:24px;background:#fafafa}'
  echo 'h2{margin-top:40px;border-bottom:2px solid #0E7C72;padding-bottom:4px}'
  echo '.pair{display:flex;gap:16px;align-items:flex-start;margin:12px 0;padding:12px;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1)}'
  echo '.pair figure{margin:0}.pair img{width:300px;border:1px solid #ddd;border-radius:6px}'
  echo 'figcaption{font-size:12px;color:#666;margin-top:4px}.label{width:120px;font-weight:600}</style>'
  echo "<h1>Beta hardening — before ($1) / after ($2)</h1>"
  # Group by area (top-level dir under the AFTER run).
  for areaDir in "$AFTER"/*/; do
    [ -d "$areaDir" ] || continue
    area="$(basename "$areaDir")"
    echo "<h2>${area}</h2>"
    for afterPng in "$areaDir"*.png; do
      [ -e "$afterPng" ] || continue
      shot="$(basename "$afterPng")"
      beforePng="$BEFORE/$area/$shot"
      echo '<div class="pair">'
      echo "<div class=\"label\">${shot}</div>"
      if [ -e "$beforePng" ]; then
        echo "<figure><img src=\"../tour/$1/$area/$shot\"><figcaption>before</figcaption></figure>"
      else
        echo '<figure><figcaption>(no before)</figcaption></figure>'
      fi
      echo "<figure><img src=\"../tour/$2/$area/$shot\"><figcaption>after</figcaption></figure>"
      echo '</div>'
    done
  done
} > "$HTML"
echo "Gallery written to $HTML"
