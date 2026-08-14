#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

RESULT_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh"
STATE_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh"
assert_file_exists "$RESULT_SH"

TMP="${TMPDIR:-/tmp}/cfst-result-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CFST_RUNTIME_DIR="$TMP/runtime"
export CFST_STATUS_FILE="$CFST_RUNTIME_DIR/status.json"
export CFST_STATE_FILE="$TMP/state.json"
mkdir -p "$CFST_RUNTIME_DIR"

# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh
. "$STATE_SH"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh
. "$RESULT_SH"

FIXTURES="$CFST_ROOT/tests/fixtures/results"

# --- is_ipv4 ---
assert_status 0 is_ipv4 '104.18.2.10'
assert_status 0 is_ipv4 '1.1.1.1'
assert_status 1 is_ipv4 '10.0.0.1'
assert_status 1 is_ipv4 'not-an-ip'
assert_status 1 is_ipv4 '1.2.3'
assert_status 1 is_ipv4 ''

# --- validate_cfst_header ---
assert_status 0 validate_cfst_header "$FIXTURES/valid.csv"
assert_status 0 validate_cfst_header "$FIXTURES/no-qualified.csv"

# BOM-prefixed header must still validate
printf '\357\273\277' > "$TMP/bom.csv"
cat "$FIXTURES/valid.csv" >> "$TMP/bom.csv"
assert_status 0 validate_cfst_header "$TMP/bom.csv"

set +e
validate_cfst_header "$FIXTURES/bad-header.csv"
status="$?"
set -e
assert_eq "$status" "50"
assert_eq "$CFST_ERROR_CODE" "RESULT_BAD_CSV"

# --- candidate_is_qualified ---
# ip sent recv loss latency speed
assert_status 0 candidate_is_qualified '104.18.2.10' 4 4 0 38.1 0.125 200 0.2 1
assert_status 1 candidate_is_qualified '10.0.0.1' 4 4 0 20 99 200 0.2 0.01
assert_status 1 candidate_is_qualified '104.18.9.9' 4 0 0 10 50 200 0.2 0.01
assert_status 1 candidate_is_qualified '104.18.8.8' 4 4 0.5 10 50 200 0.2 0.01
assert_status 1 candidate_is_qualified '104.18.7.7' 4 4 0 250 50 200 0.2 0.01
assert_status 1 candidate_is_qualified '104.18.6.6' 4 4 0 30 0.001 200 0.2 1
assert_status 1 candidate_is_qualified '104.18.5.5' 4 4 bad 30 40 200 0.2 0.01

# --- select_best_result: ordering speed desc, latency asc, loss asc ---
selected="$(select_best_result "$FIXTURES/valid.csv" 200 0.2 0.01)"
assert_eq "$selected" '{"ip":"104.18.2.10","latency_ms":38.1,"loss_ratio":0,"speed_mbps":373.6,"colo":"HKG"}'

# A 0.5 MB/s CSV result is 4 Mbps and must pass a 1 Mbps setting.
cat > "$TMP/mbps-boundary.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.18.4.4,4,4,0.00,40.0,0.50,HKG
EOF
selected="$(select_best_result "$TMP/mbps-boundary.csv" 200 0.3 1)"
assert_eq "$selected" '{"ip":"104.18.4.4","latency_ms":40,"loss_ratio":0,"speed_mbps":4,"colo":"HKG"}'

# BOM file selects the same winner
selected="$(select_best_result "$TMP/bom.csv" 200 0.2 0.01)"
assert_eq "$selected" '{"ip":"104.18.2.10","latency_ms":38.1,"loss_ratio":0,"speed_mbps":373.6,"colo":"HKG"}'

set +e
select_best_result "$FIXTURES/no-qualified.csv" 200 0.2 1 >/dev/null
status="$?"
set -e
assert_eq "$status" "51"
assert_eq "$CFST_ERROR_CODE" "RESULT_NO_QUALIFIED_IP"

set +e
select_best_result "$FIXTURES/bad-header.csv" 200 0.2 0.01 >/dev/null
status="$?"
set -e
assert_eq "$status" "50"
assert_eq "$CFST_ERROR_CODE" "RESULT_BAD_CSV"
