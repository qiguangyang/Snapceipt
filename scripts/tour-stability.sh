#!/usr/bin/env bash
# Runs the tour twice and diffs static-screen PNGs. Inherently NON-static screens
# are excluded by name token:
#   scanning|saved|confetti — capture animations / confetti
#   keyboard                — a blinking text-cursor never matches byte-for-byte
#   magiclink|permission    — entry/priming screens with their own intro animation
# Exits non-zero if any static screen differs between runs.
# (bash 3.2-safe: no associative arrays / no `${!}` assoc expansion used here.)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/tour.sh stab-a >/dev/null
scripts/tour.sh stab-b >/dev/null

EXCLUDE='scanning|saved|confetti|keyboard|magiclink|permission'
fail=0
while IFS= read -r a; do
  rel="${a#artifacts/tour/stab-a/}"
  b="artifacts/tour/stab-b/${rel}"
  if echo "$rel" | grep -Eq "$EXCLUDE"; then continue; fi
  if [ ! -f "$b" ]; then echo "MISSING in run B: $rel"; fail=1; continue; fi
  if ! cmp -s "$a" "$b"; then echo "UNSTABLE: $rel"; fail=1; fi
done < <(find artifacts/tour/stab-a -name '*.png' | sort)

if [ "$fail" -eq 0 ]; then echo "stability: all static screens pixel-stable across two runs"; else
  echo "stability: FAILURES above — settle longer or exclude the screen's animation"; exit 1; fi
