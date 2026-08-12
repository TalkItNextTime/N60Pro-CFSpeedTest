#!/bin/sh
# shellcheck disable=SC2089,SC2090
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

STATE_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh"
assert_file_exists "$STATE_SH"
# shellcheck disable=SC1090,SC1091
. "$STATE_SH"

TMP="${TMPDIR:-/tmp}/cfst-state-test.$$"
mkdir -p "$TMP/runtime" "$TMP/etc"
trap 'rm -rf "$TMP"' EXIT INT TERM

CFST_RUNTIME_DIR="$TMP/runtime"
CFST_STATUS_FILE="$CFST_RUNTIME_DIR/status.json"
CFST_STATE_FILE="$TMP/etc/state.json"
CFST_NOW=1700000000
export CFST_RUNTIME_DIR CFST_STATUS_FILE CFST_STATE_FILE CFST_NOW

state_init manual
assert_file_exists "$CFST_STATUS_FILE"
assert_contains "$(tr -d '\r\n' < "$CFST_STATUS_FILE")" '"phase":"preparing"'
assert_contains "$(tr -d '\r\n' < "$CFST_STATUS_FILE")" '"trigger":"manual"'

state_set_phase testing_latency 'Testing "candidates"'
status_json="$(tr -d '\r\n' < "$CFST_STATUS_FILE")"
assert_eq "$status_json" '{"phase":"testing_latency","message":"Testing \"candidates\"","updated_at":1700000000}'

state_fail CFST_TIMEOUT 'Timed out'
status_json="$(tr -d '\r\n' < "$CFST_STATUS_FILE")"
assert_contains "$status_json" '"phase":"failed"'
assert_contains "$status_json" '"error_code":"CFST_TIMEOUT"'

state_success 'Published'
status_json="$(tr -d '\r\n' < "$CFST_STATUS_FILE")"
assert_contains "$status_json" '"phase":"success"'
assert_contains "$status_json" '"message":"Published"'

CFST_LAST_PUBLISHED='{"ip":"104.18.2.10"}'
CFST_LAST_TESTED='{"ip":"104.18.2.11"}'
CFST_GEO_CACHE='{"city":"sz","isp":"ct"}'
CFST_MANAGED_RECORD='{"id":"record-1","name":"szct.domain.com"}'
export CFST_LAST_PUBLISHED CFST_LAST_TESTED CFST_GEO_CACHE CFST_MANAGED_RECORD
state_save_persistent
assert_file_exists "$CFST_STATE_FILE"
persistent_json="$(tr -d '\r\n' < "$CFST_STATE_FILE")"
assert_contains "$persistent_json" '"schema_version":1'
assert_contains "$persistent_json" '"managed_record":{"id":"record-1"'

CFST_LAST_PUBLISHED=''
CFST_LAST_TESTED=''
CFST_GEO_CACHE=''
CFST_MANAGED_RECORD=''
CFST_STATE_CORRUPT=0
state_load_persistent
assert_eq "$CFST_STATE_CORRUPT" "0"
assert_eq "$CFST_LAST_PUBLISHED" '{"ip":"104.18.2.10"}'
assert_eq "$CFST_MANAGED_RECORD" '{"id":"record-1","name":"szct.domain.com"}'

printf '%s\n' '{not-json' > "$CFST_STATE_FILE"
CFST_MANAGED_RECORD='unsafe'
CFST_STATE_CORRUPT=0
set +e
state_load_persistent
load_status="$?"
set -e
assert_eq "$load_status" "1"
assert_eq "$CFST_STATE_CORRUPT" "1"
assert_eq "$CFST_MANAGED_RECORD" ""
