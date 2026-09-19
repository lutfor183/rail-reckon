#!/bin/bash
# Build the encrypted public payload. Run ONLY on your own machine.
# The passphrase is typed interactively and never stored anywhere.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-/tmp/reckon.tar.age}"
for f in rail.sh stations.txt pager.wav; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done
command -v age >/dev/null 2>&1 || { echo "install age first: pkg install age / sudo apt install age" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tar -czf "$tmp/payload.tar.gz" rail.sh stations.txt pager.wav
age -p "$tmp/payload.tar.gz" > "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "Copy it into the 'pub' branch checkout, commit, push."
