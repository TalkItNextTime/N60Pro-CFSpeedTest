#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

DNS_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/dns.sh"
STATE_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh"
LOG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh"
MOCK_HTTP="$CFST_ROOT/tests/helpers/mock_http.py"
FIXTURES="$CFST_ROOT/tests/fixtures/cloudflare"

assert_file_exists "$DNS_SH"
assert_file_exists "$MOCK_HTTP"

TMP="${TMPDIR:-/tmp}/cfst-dns-test.$$"
mkdir -p "$TMP/task" "$TMP/etc" "$TMP/runtime"
MOCK_PID=''
trap 'if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT INT TERM

export CFST_TASK_DIR="$TMP/task"
export CFST_LOG_FILE="$TMP/plugin.log"
export CFST_STATE_FILE="$TMP/etc/state.json"
export CFST_RUNTIME_DIR="$TMP/runtime"
export CFST_STATUS_FILE="$TMP/runtime/status.json"
export CFST_API_TOKEN='test-token-secret-value'
export CFST_ZONE='domain.com'
export CFST_TTL=1
export CFST_PROXIED=0
export CFST_SLEEP_CMD='true'
export CFST_NOW=1700000000
export CFST_NOW_TEXT='2023-11-14 22:13:20'
export CFST_STATE_CORRUPT=0
export CFST_MANAGED_RECORD=''

# Prefer real curl; keep mock jsonfilter/logger first.
export PATH="$CFST_ROOT/tests/helpers/mock-bin:$PATH"

# shellcheck disable=SC1090,SC1091
. "$STATE_SH"
# shellcheck disable=SC1090,SC1091
. "$LOG_SH"
# shellcheck disable=SC1090,SC1091
. "$DNS_SH"

stop_mock() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
        MOCK_PID=''
    fi
}

start_mock() {
    scenario="$1"
    stop_mock
    rm -f "$TMP/port" "$TMP/requests.jsonl"
    python3 "$MOCK_HTTP" \
        --port-file "$TMP/port" \
        --scenario "$scenario" \
        --request-log "$TMP/requests.jsonl" &
    MOCK_PID=$!
    i=0
    while [ ! -s "$TMP/port" ] && [ "$i" -lt 100 ]; do
        # brief wait for bind; not the DNS retry sleep
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
        if ! kill -0 "$MOCK_PID" 2>/dev/null; then
            fail "mock_http exited early for $scenario"
        fi
    done
    [ -s "$TMP/port" ] || fail "mock port file missing for $scenario"
    PORT="$(tr -d '\r\n' < "$TMP/port")"
    export CFST_CF_API_BASE="http://127.0.0.1:${PORT}"
    : > "$CFST_LOG_FILE"
    rm -f "$CFST_TASK_DIR"/cf_*
}

request_log_text() {
    if [ -f "$TMP/requests.jsonl" ]; then
        tr -d '\r' < "$TMP/requests.jsonl"
    else
        printf ''
    fi
}

assert_auth_header_present() {
    log="$(request_log_text)"
    assert_contains "$log" '"Authorization": "Bearer test-token-secret-value"'
}

assert_bodies_orange_cloud_a() {
    log="$(request_log_text)"
    case "$log" in
        *'"method": "POST"'*|*'"method": "PUT"'*)
            case "$log" in
                *'"proxied":true'*|*'"proxied": true'*) : ;;
                *) fail "missing proxied true in body: $log" ;;
            esac
            ;;
    esac
}

assert_bodies_gray_cloud_a() {
    log="$(request_log_text)"
    case "$log" in
        *'"method": "POST"'*|*'"method": "PUT"'*)
            case "$log" in
                *'"type":"A"'*|*'"type": "A"'*) : ;;
                *) fail "missing type A in body: $log" ;;
            esac
            case "$log" in
                *'"proxied":false'*|*'"proxied": false'*) : ;;
                *) fail "missing proxied false in body: $log" ;;
            esac
            ;;
    esac
}

assert_token_not_in_plugin_log() {
    if [ -f "$CFST_LOG_FILE" ]; then
        log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
        case "$log_text" in
            *test-token-secret-value*) fail "token leaked into plugin log" ;;
        esac
    fi
}

# --- Token verification success ---
start_mock "$FIXTURES/verify_ok.json"
set +e
cf_verify_token
status="$?"
set -e
assert_eq "$status" "0"
assert_auth_header_present
assert_token_not_in_plugin_log

# --- Zone lookup ---
start_mock "$FIXTURES/zone_ok.json"
set +e
zone_id="$(cf_find_zone_id domain.com)"
status="$?"
set -e
assert_eq "$status" "0"
assert_eq "$zone_id" "zone-abc"
assert_auth_header_present

# --- record not found then create ---
start_mock "$FIXTURES/create_record.json"
CFST_MANAGED_RECORD=''
CFST_STATE_CORRUPT=0
set +e
cf_sync_dns 'szct.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$CFST_MANAGED_RECORD" '"id":"rec-new"'
assert_contains "$CFST_MANAGED_RECORD" '"name":"szct.domain.com"'
assert_contains "$CFST_MANAGED_RECORD" '"content":"1.2.3.4"'
assert_contains "$CFST_MANAGED_RECORD" '"type":"A"'
req="$(request_log_text)"
assert_contains "$req" '"method": "POST"'
assert_bodies_gray_cloud_a
assert_auth_header_present
assert_token_not_in_plugin_log

# --- orange-cloud mode is persisted in the DNS request body ---
start_mock "$FIXTURES/create_record.json"
CFST_PROXIED=1
CFST_MANAGED_RECORD=''
set +e
cf_sync_dns 'szct.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "0"
assert_bodies_orange_cloud_a
CFST_PROXIED=0

# --- same-value idempotence (no needless PUT) ---
start_mock "$FIXTURES/idempotent_same.json"
CFST_MANAGED_RECORD=''
set +e
cf_sync_dns 'szct.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$CFST_MANAGED_RECORD" '"id":"rec-same"'
req="$(request_log_text)"
case "$req" in
    *'"method": "PUT"'*|*'"method": "POST"'*) fail "idempotent sync must not POST/PUT" ;;
esac

# --- changed-value update ---
start_mock "$FIXTURES/update_record.json"
CFST_MANAGED_RECORD=''
set +e
cf_sync_dns 'szct.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$CFST_MANAGED_RECORD" '"id":"rec-upd"'
assert_contains "$CFST_MANAGED_RECORD" '"content":"1.2.3.4"'
req="$(request_log_text)"
assert_contains "$req" '"method": "PUT"'
assert_bodies_gray_cloud_a

# --- duplicate records → 64 DNS_MULTIPLE_RECORDS ---
start_mock "$FIXTURES/duplicate_records.json"
set +e
cf_sync_dns 'szct.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "64"
assert_eq "$CFST_ERROR_CODE" "DNS_MULTIPLE_RECORDS"

# --- 401 → 60 ---
start_mock "$FIXTURES/unauthorized.json"
set +e
cf_verify_token
status="$?"
set -e
assert_eq "$status" "60"
assert_eq "$CFST_ERROR_CODE" "CF_API_UNAUTHORIZED"
assert_token_not_in_plugin_log

# --- 403 → 61 ---
start_mock "$FIXTURES/forbidden.json"
set +e
cf_find_zone_id domain.com
status="$?"
set -e
assert_eq "$status" "61"
assert_eq "$CFST_ERROR_CODE" "CF_API_FORBIDDEN"

# --- 429 with Retry-After: 0 then success ---
start_mock "$FIXTURES/rate_limit_then_ok.json"
set +e
cf_verify_token
status="$?"
set -e
assert_eq "$status" "0"

# --- transient 500 then success ---
start_mock "$FIXTURES/transient_500_then_ok.json"
set +e
cf_verify_token
status="$?"
set -e
assert_eq "$status" "0"

# --- old-record deletion refusal when managed metadata no longer matches ---
start_mock "$FIXTURES/cleanup_mismatch.json"
CFST_STATE_CORRUPT=0
CFST_MANAGED_RECORD='{"id":"rec-old","name":"szct.domain.com","type":"A","content":"8.8.8.8","zone_id":"zone-abc"}'
set +e
cf_sync_dns 'bjcm.domain.com' '5.6.7.8'
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$CFST_MANAGED_RECORD" '"id":"rec-new"'
assert_contains "$CFST_MANAGED_RECORD" '"name":"bjcm.domain.com"'
req="$(request_log_text)"
case "$req" in
    *'"method": "DELETE"'*) fail "must not DELETE when remote managed record no longer matches" ;;
esac

# --- cleanup failure after successful publish → exit 66 ---
start_mock "$FIXTURES/cleanup_fail.json"
CFST_STATE_CORRUPT=0
CFST_MANAGED_RECORD='{"id":"rec-old","name":"szct.domain.com","type":"A","content":"8.8.8.8","zone_id":"zone-abc"}'
set +e
cf_sync_dns 'bjcm.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "66"
assert_contains "$CFST_MANAGED_RECORD" '"id":"rec-new"'
assert_contains "$CFST_MANAGED_RECORD" '"name":"bjcm.domain.com"'
req="$(request_log_text)"
assert_contains "$req" '"method": "DELETE"'
assert_token_not_in_plugin_log

# --- CFST_STATE_CORRUPT=1 never auto-deletes ---
start_mock "$FIXTURES/cleanup_fail.json"
CFST_STATE_CORRUPT=1
CFST_MANAGED_RECORD='{"id":"rec-old","name":"szct.domain.com","type":"A","content":"8.8.8.8","zone_id":"zone-abc"}'
set +e
cf_sync_dns 'bjcm.domain.com' '1.2.3.4'
status="$?"
set -e
assert_eq "$status" "0"
req="$(request_log_text)"
case "$req" in
    *'"method": "DELETE"'*) fail "corrupt state must not auto-delete old records" ;;
esac

stop_mock
printf 'OK dns integration\n'
