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

# --- select_best_result: published-IP stickiness ---
cat > "$TMP/sticky.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.1.1,10,10,0.00,40.0,5.00,LAX
104.20.1.2,10,10,0.00,45.0,4.20,FRA
104.20.1.3,10,10,0.00,50.0,4.16,AMS
EOF

# No sticky IP given: the fastest wins, exactly as before.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# 5.00 vs 4.20 is +19.05%, below the 20% bar, so the published IP is kept.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.2'

# 5.00 vs 4.16 is +20.19%, above the bar, so the faster IP takes over.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.3 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# margin 0 always takes the fastest.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 0)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# A sticky IP that is not in the qualified set is ignored.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 203.0.113.9 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# The sticky winner keeps its own metrics, not the fastest row's.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 20)"
assert_eq "$selected" '{"ip":"104.20.1.2","latency_ms":45,"loss_ratio":0,"speed_mbps":33.6,"colo":"FRA"}'

# --- select_best_result: speed and latency are scored together ---
# Real measurements from an N60 Pro run. Raw speed alone picks the LAX node,
# but it sits three timezones away; the NRT node is only 26% slower and less
# than a third of the round trip, which is the better node to publish.
cat > "$TMP/score.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.18.1.239,10,10,0.00,167.77,49.82,LAX
162.159.44.229,10,10,0.00,56.96,36.78,NRT
104.18.37.255,10,10,0.00,95.04,36.64,SIN
EOF
selected="$(select_best_result "$TMP/score.csv" 300 0.3 1)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"colo":"\([^"]*\)".*/\1/p')" 'NRT'

# speed_weight 100 ignores latency entirely and restores raw-speed ranking.
selected="$(select_best_result "$TMP/score.csv" 300 0.3 1 '' 0 100)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"colo":"\([^"]*\)".*/\1/p')" 'LAX'

# speed_weight 0 ranks purely on latency.
selected="$(select_best_result "$TMP/score.csv" 300 0.3 1 '' 0 0)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"colo":"\([^"]*\)".*/\1/p')" 'NRT'

# Stickiness compares scores, not raw speed: LAX is published but scores 0.736
# against NRT's 0.843, which is a 14% gap and under the 20% bar, so it stays.
selected="$(select_best_result "$TMP/score.csv" 300 0.3 1 104.18.1.239 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"colo":"\([^"]*\)".*/\1/p')" 'LAX'
# With no margin the better-scoring node takes over.
selected="$(select_best_result "$TMP/score.csv" 300 0.3 1 104.18.1.239 0)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"colo":"\([^"]*\)".*/\1/p')" 'NRT'

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

# --- result_qualified_ips: narrows the download pass to preflight survivors ---
cat > "$TMP/preflight.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.3.1,10,10,0.00,40.0,0.00,LAX
10.0.0.5,10,10,0.00,20.0,0.00,XXX
104.20.3.2,10,10,0.00,250.0,0.00,FRA
104.20.3.3,10,4,0.60,50.0,0.00,AMS
104.20.3.4,10,10,0.00,60.0,0.00,NRT
104.20.3.1,10,10,0.00,41.0,0.00,LAX
EOF
survivors="$(result_qualified_ips "$TMP/preflight.csv" 200 0.3)"
# private, over-latency, over-loss and the duplicate are all dropped; the CSV
# order is preserved so the download pass tries the lowest latency first.
assert_eq "$survivors" '104.20.3.1
104.20.3.4'
assert_status 1 result_qualified_ips "$TMP/no-such-preflight.csv" 200 0.3

# --- result_merge_csv: one header, deduped by IP keeping the faster row ---
cat > "$TMP/merge-main.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.2.1,10,10,0.00,40.0,5.00,LAX
104.20.2.2,10,10,0.00,45.0,1.00,FRA
EOF
cat > "$TMP/merge-recheck.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.2.2,10,10,0.00,44.0,9.00,FRA
104.20.2.9,10,10,0.00,60.0,2.00,AMS
EOF
result_merge_csv "$TMP/merged.csv" "$TMP/merge-main.csv" "$TMP/merge-recheck.csv"
assert_eq "$(awk 'END { print NR }' "$TMP/merged.csv")" '4'
assert_eq "$(awk 'NR==1' "$TMP/merged.csv")" 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码'
# 104.20.2.2 appears once, with the faster recheck row
assert_eq "$(grep -c '^104\.20\.2\.2,' "$TMP/merged.csv")" '1'
assert_contains "$(cat "$TMP/merged.csv")" '104.20.2.2,10,10,0.00,44.0,9.00,FRA'
assert_contains "$(cat "$TMP/merged.csv")" '104.20.2.9,10,10,0.00,60.0,2.00,AMS'

# A missing or empty second input degrades to a copy of the first.
result_merge_csv "$TMP/merged2.csv" "$TMP/merge-main.csv" "$TMP/does-not-exist.csv"
assert_eq "$(awk 'END { print NR }' "$TMP/merged2.csv")" '3'

# Selection over the merged file sees the recheck row.
selected="$(select_best_result "$TMP/merged.csv" 200 0.3 1)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.2.2'
