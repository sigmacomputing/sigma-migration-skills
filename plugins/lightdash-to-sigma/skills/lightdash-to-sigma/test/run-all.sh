#!/usr/bin/env bash
set -uo pipefail
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
fail=0
for t in test/test-*.rb; do
  echo "### $t"
  if ruby "$t"; then :; else fail=1; fi
  echo
done
if [ "$fail" -eq 0 ]; then echo "== ALL SUITES PASS =="; else echo "== FAILURES =="; fi
exit "$fail"
