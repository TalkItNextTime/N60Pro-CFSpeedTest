#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

assert_file_exists "$CFST_ROOT/README.md"

assert_contains "$(cat "$CFST_ROOT/README.md")" "aarch64_cortex-a53"
assert_contains "$(cat "$CFST_ROOT/README.md")" "Zone:Read"
assert_contains "$(cat "$CFST_ROOT/README.md")" "DNS:Edit"
assert_contains "$(cat "$CFST_ROOT/README.md")" "灰云"
assert_contains "$(cat "$CFST_ROOT/README.md")" "bypass transparent proxy"
assert_contains "$(cat "$CFST_ROOT/README.md")" "Install/upgrade/uninstall"
assert_contains "$(cat "$CFST_ROOT/README.md")" "LuCI"
assert_contains "$(cat "$CFST_ROOT/README.md")" "CLI diagnostics"
assert_contains "$(cat "$CFST_ROOT/README.md")" "not encrypted at rest"

echo "docs test passed"