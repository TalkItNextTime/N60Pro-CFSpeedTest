#!/bin/sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
export CFST_ROOT="$ROOT"
export PATH="$ROOT/tests/helpers/mock-bin:$PATH"

failed=0
for test_file in "$ROOT"/tests/unit/test_*.sh "$ROOT"/tests/integration/test_*.sh; do
    [ -f "$test_file" ] || continue
    printf '==> %s\n' "${test_file#"$ROOT"/}"
    if ! sh "$test_file"; then
        failed=1
    fi
done
exit "$failed"
