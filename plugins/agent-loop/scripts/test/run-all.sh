#!/usr/bin/env bash
# Run every *_test.sh in this directory; exit non-zero if any fails.
# This is the loop's self-preservation gate: no self-modification lands red.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for t in "$here"/*_test.sh; do
  echo ">> $(basename "$t")"
  bash "$t" || { echo "FAIL: $(basename "$t")" >&2; status=1; }
done
[ "$status" = 0 ] && echo "ALL GREEN"
exit "$status"
