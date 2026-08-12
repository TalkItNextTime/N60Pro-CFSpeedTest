#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

LOG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh"
assert_file_exists "$LOG_SH"
# shellcheck disable=SC1090,SC1091
. "$LOG_SH"

TMP="${TMPDIR:-/tmp}/cfst-log-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

CFST_LOG_FILE="$TMP/cloudflare-speedtest.log"
CFST_LOG_MAX_BYTES=120
CFST_LOG_ROTATIONS=2
CFST_API_TOKEN='secret-token'
CFST_TEST_LOGGER_FILE="$TMP/system.log"
CFST_NOW_TEXT='2026-08-12 12:00:00'
export CFST_LOG_FILE CFST_LOG_MAX_BYTES CFST_LOG_ROTATIONS CFST_API_TOKEN CFST_TEST_LOGGER_FILE CFST_NOW_TEXT

cfst_log INFO 'Authorization: Bearer secret-token initial message'
active="$(tr -d '\r\n' < "$CFST_LOG_FILE")"
system="$(tr -d '\r\n' < "$CFST_TEST_LOGGER_FILE")"
assert_contains "$active" '[REDACTED]'
assert_contains "$system" '[REDACTED]'
case "$active$system" in *secret-token*) fail 'token leaked into logs' ;; esac

index=1
while [ "$index" -le 8 ]; do
    cfst_log INFO "rotation message $index with enough padding to cross the configured byte limit"
    index=$((index + 1))
done

assert_file_exists "$CFST_LOG_FILE.1"
for file in "$CFST_LOG_FILE" "$CFST_LOG_FILE.1" "$CFST_LOG_FILE.2"; do
    [ -f "$file" ] || continue
    size="$(wc -c < "$file" | tr -d ' ')"
    [ "$size" -le 240 ] || fail "log file too large: $file ($size bytes)"
done

recent="$(read_log_bytes 64)"
[ "$(printf '%s' "$recent" | wc -c | tr -d ' ')" -le 64 ] || fail 'bounded log read exceeded limit'
assert_status 2 read_log_bytes 65537

clear_plugin_logs
[ ! -e "$CFST_LOG_FILE" ] || fail 'active log was not cleared'
[ ! -e "$CFST_LOG_FILE.1" ] || fail 'rotated log was not cleared'
