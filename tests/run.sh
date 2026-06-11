#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_local_ollama_registered="$HERE/local_ollama_test.sh"
total=0; failed=0
for t in "$HERE"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "RUN $(basename "$t")"
  bash "$t"; rc=$?
  total=$((total + 1))
  if [ "$rc" -ne 0 ]; then failed=$((failed + 1)); echo "  -> FAILED (rc=$rc)"; fi
done
echo "=== $((total - failed))/$total test files passed ==="
[ "$failed" -eq 0 ]
