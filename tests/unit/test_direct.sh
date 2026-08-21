#!/bin/sh
# Direct-path marking: install/remove the nftables rule and pick the run user.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

DIRECT_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh"
LOG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh"
assert_file_exists "$DIRECT_SH"

TMP="${TMPDIR:-/tmp}/cfst-direct-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
export CFST_LOG_FILE="$TMP/plugin.log"
export PATH="$CFST_ROOT/tests/helpers/mock-bin:$PATH"
export CFST_MOCK_NFT_LOG="$TMP/nft.args"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh
. "$LOG_SH"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh
. "$DIRECT_SH"

# --- disabled by config: no nft calls, cfst runs as root ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=0
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
direct_enable
assert_eq "$(wc -c < "$CFST_MOCK_NFT_LOG" | tr -d ' ')" '0'
assert_eq "$(direct_run_user)" ''

# --- enabled with a resolvable user: table, chain and rule are created ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=1
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
direct_enable
args="$(tr -d '\r' < "$CFST_MOCK_NFT_LOG")"
assert_contains "$args" 'add table inet cfst_direct'
assert_contains "$args" 'add chain inet cfst_direct mark_out'
assert_contains "$args" 'meta skuid'
assert_contains "$args" 'meta mark set 0x000000ff'
assert_eq "$(direct_run_user)" 'nobody'

# --- idempotent: a second enable must not add a second rule ---
: > "$CFST_MOCK_NFT_LOG"
direct_enable
assert_eq "$(grep -c 'add rule' "$CFST_MOCK_NFT_LOG" || true)" '0'

# --- disable removes the whole table ---
: > "$CFST_MOCK_NFT_LOG"
direct_disable
assert_contains "$(cat "$CFST_MOCK_NFT_LOG")" 'delete table inet cfst_direct'

# --- unknown user: degrade to root, warn, no rule ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=cfst-does-not-exist
CFST_DIRECT_UID=''
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode user missing'

# --- nft missing: degrade quietly, no crash ---
: > "$CFST_LOG_FILE"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
CFST_NFT_BIN=/nonexistent/nft
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode nft unavailable'

printf 'direct tests passed\n'
