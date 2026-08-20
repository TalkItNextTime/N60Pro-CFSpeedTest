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

# The fastest row must win even when it sorts last lexicographically. Field
# ranking cannot rely on `sort -t, -k...`: BusyBox on some OpenWrt builds
# ignores those flags and falls back to whole-line order.
cat > "$TMP/rank.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.5.6,10,10,0.00,3.79,2.61,FRA
104.25.120.184,10,10,0.00,4.94,1.03,FRA
162.159.145.165,10,10,0.00,5.44,0.35,FRA
172.67.242.80,10,10,0.00,5.13,1.02,AMS
198.41.200.158,10,10,0.00,5.32,9.08,LAX
EOF
selected="$(select_best_result "$TMP/rank.csv" 200 0.3 1)"
assert_eq "$selected" '{"ip":"198.41.200.158","latency_ms":5.32,"loss_ratio":0,"speed_mbps":72.64,"colo":"LAX"}'

# Equal speed falls back to latency asc, then loss asc.
cat > "$TMP/tiebreak.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.1.1,10,10,0.00,40.0,5.00,FRA
104.20.1.2,10,9,0.10,20.0,5.00,LAX
104.20.1.3,10,10,0.00,20.0,5.00,NRT
EOF
selected="$(select_best_result "$TMP/tiebreak.csv" 200 0.3 1)"
assert_eq "$selected" '{"ip":"104.20.1.3","latency_ms":20,"loss_ratio":0,"speed_mbps":40,"colo":"NRT"}'

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

# --- result_reject_summary: names the gate that emptied the set ---
# All download speeds zero: the latency/loss gate passes, min-speed rejects.
cat > "$TMP/zero-speed.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.18.4.4,10,10,0.00,45.32,0.00,HKG
104.18.5.5,10,10,0.00,52.10,0.00,N/A
EOF
summary="$(result_reject_summary "$TMP/zero-speed.csv" 200 0.3 1)"
assert_eq "$summary" 'rows=2 malformed=0 nonpublic=0 loss_rejected=0 latency_rejected=0 latency_loss_ok=2 max_speed_mbps=0.000 required_mbps=1'

# Mixed rejects: each gate is counted separately so the log names the culprit.
summary="$(result_reject_summary "$FIXTURES/no-qualified.csv" 200 0.2 1)"
assert_eq "$summary" 'rows=4 malformed=0 nonpublic=1 loss_rejected=1 latency_rejected=1 latency_loss_ok=1 max_speed_mbps=0.004 required_mbps=1'

summary="$(result_reject_summary "$TMP/missing.csv" 200 0.2 1)"
assert_eq "$summary" 'rows=0 csv=missing'
