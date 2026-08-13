#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"
LIB="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest"
. "$LIB/candidates.sh"
TMP="${TMPDIR:-/tmp}/cfst-candidates-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
cat > "$TMP/source" <<'EOF'
1.1.1.0/30
2.2.2.2
2.2.2.2
EOF
candidates_prepare "$TMP/source" "$TMP/out" 2 0
assert_eq "$(wc -l < "$TMP/out" | tr -d ' ')" "2"
assert_eq "$CFST_CANDIDATE_AVAILABLE" "5"
candidates_prepare "$TMP/source" "$TMP/all" 0 0
assert_eq "$(wc -l < "$TMP/all" | tr -d ' ')" "2"
candidates_prepare "$TMP/source" "$TMP/test-all" 1 1
assert_eq "$(wc -l < "$TMP/test-all" | tr -d ' ')" "2"
assert_eq "$(candidates_next_count 1)" "2"
assert_eq "$(candidates_next_count 2)" "3"
printf 'candidate tests passed\n'
