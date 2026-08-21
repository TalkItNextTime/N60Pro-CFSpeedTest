#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

LIB="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest"
CLI="$CFST_ROOT/package/cloudflare-speedtest/files/usr/bin/cloudflare-speedtest"
MOCK_CFST="$CFST_ROOT/tests/helpers/mock-bin/cfst"
MOCK_HTTP="$CFST_ROOT/tests/helpers/mock_http.py"
FIXTURES_R="$CFST_ROOT/tests/fixtures/results"
FIXTURES_CF="$CFST_ROOT/tests/fixtures/cloudflare"

assert_file_exists "$CLI"
assert_file_exists "$LIB/runner.sh"
assert_file_exists "$MOCK_CFST"
assert_file_exists "$MOCK_HTTP"

TMP="${TMPDIR:-/tmp}/cfst-runner-test.$$"
mkdir -p "$TMP/runtime" "$TMP/etc" "$TMP/share" "$TMP/bin"
MOCK_PID=''
BG_PID=''
BASE_PATH="$PATH"
trap '
    if [ -n "${BG_PID:-}" ]; then kill "$BG_PID" 2>/dev/null || true; wait "$BG_PID" 2>/dev/null || true; fi
    if [ -n "${MOCK_PID:-}" ]; then kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; fi
    rm -rf "$TMP"
' EXIT INT TERM

printf '1.1.1.1\n' > "$TMP/share/ip.txt"

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
        sleep 0.05 2>/dev/null || sleep 1
        i=$((i + 1))
        if ! kill -0 "$MOCK_PID" 2>/dev/null; then
            fail "mock_http exited early for $scenario"
        fi
    done
    [ -s "$TMP/port" ] || fail "mock port file missing for $scenario"
    PORT="$(tr -d '\r\n' < "$TMP/port")"
    export CFST_CF_API_BASE="http://127.0.0.1:${PORT}"
}

request_log_text() {
    if [ -f "$TMP/requests.jsonl" ]; then
        tr -d '\r' < "$TMP/requests.jsonl"
    else
        printf ''
    fi
}

write_publish_fixture() {
    # Publish best CFST candidate 104.18.2.10 as szct.domain.com
    cat > "$TMP/publish_ok.json" <<'EOF'
{
  "rules": [
    {
      "method": "GET",
      "path": "/zones",
      "response": {
        "status": 200,
        "json": {
          "success": true,
          "errors": [],
          "result": [{"id": "zone-abc", "name": "domain.com", "status": "active"}]
        }
      }
    },
    {
      "method": "GET",
      "path": "/zones/zone-abc/dns_records",
      "sequence": [
        {
          "status": 200,
          "json": {
            "success": true,
            "errors": [],
            "result": []
          }
        },
        {
          "status": 200,
          "json": {
            "success": true,
            "errors": [],
            "result": [{
              "id": "rec-new",
              "type": "A",
              "name": "szct.domain.com",
              "content": "104.18.2.10",
              "proxied": false,
              "ttl": 1,
              "zone_id": "zone-abc"
            }]
          }
        }
      ]
    },
    {
      "method": "POST",
      "path": "/zones/zone-abc/dns_records",
      "response": {
        "status": 200,
        "json": {
          "success": true,
          "errors": [],
          "result": {
            "id": "rec-new",
            "type": "A",
            "name": "szct.domain.com",
            "content": "104.18.2.10",
            "proxied": false,
            "ttl": 1,
            "zone_id": "zone-abc"
          }
        }
      }
    }
  ]
}
EOF
}

write_cleanup_fail_fixture() {
    cat > "$TMP/cleanup_fail_best.json" <<'EOF'
{
  "rules": [
    {
      "method": "GET",
      "path": "/zones",
      "response": {
        "status": 200,
        "json": {
          "success": true,
          "errors": [],
          "result": [{"id": "zone-abc", "name": "domain.com", "status": "active"}]
        }
      }
    },
    {
      "method": "GET",
      "path": "/zones/zone-abc/dns_records",
      "sequence": [
        {
          "status": 200,
          "json": {
            "success": true,
            "errors": [],
            "result": []
          }
        },
        {
          "status": 200,
          "json": {
            "success": true,
            "errors": [],
            "result": [{
              "id": "rec-new",
              "type": "A",
              "name": "bjcm.domain.com",
              "content": "104.18.2.10",
              "proxied": false,
              "ttl": 1,
              "zone_id": "zone-abc"
            }]
          }
        }
      ]
    },
    {
      "method": "POST",
      "path": "/zones/zone-abc/dns_records",
      "response": {
        "status": 200,
        "json": {
          "success": true,
          "errors": [],
          "result": {
            "id": "rec-new",
            "type": "A",
            "name": "bjcm.domain.com",
            "content": "104.18.2.10",
            "proxied": false,
            "ttl": 1,
            "zone_id": "zone-abc"
          }
        }
      }
    },
    {
      "method": "GET",
      "path": "/zones/zone-abc/dns_records/rec-old",
      "response": {
        "status": 200,
        "json": {
          "success": true,
          "errors": [],
          "result": {
            "id": "rec-old",
            "type": "A",
            "name": "szct.domain.com",
            "content": "8.8.8.8",
            "proxied": false,
            "ttl": 1,
            "zone_id": "zone-abc"
          }
        }
      }
    },
    {
      "method": "DELETE",
      "path": "/zones/zone-abc/dns_records/rec-old",
      "response": {
        "status": 500,
        "json": {
          "success": false,
          "errors": [{"code": 10000, "message": "delete failed"}]
        }
      }
    }
  ]
}
EOF
}

write_dns_fail_fixture() {
    cat > "$TMP/dns_fail.json" <<'EOF'
{
  "rules": [
    {
      "method": "GET",
      "path": "/zones",
      "response": {
        "status": 403,
        "json": {
          "success": false,
          "errors": [{"code": 10000, "message": "Forbidden"}]
        }
      }
    }
  ]
}
EOF
}

write_uci() {
    city="${1-sz}"
    isp="${2-ct}"
    auto="${3:-0}"
    if [ "$#" -ge 5 ]; then
        template="$5"
    else
        template='{city}{isp}.{zone}'
    fi
    cat > "$CFST_TEST_UCI_FILE" <<EOF
cloudflare-speedtest.main.enabled=1
cloudflare-speedtest.main.interval_hours=6
cloudflare-speedtest.main.startup_delay=120
cloudflare-speedtest.main.log_level=info
cloudflare-speedtest.cloudflare.api_token=test-token-secret-value
cloudflare-speedtest.cloudflare.zone=domain.com
cloudflare-speedtest.cloudflare.ttl=1
cloudflare-speedtest.naming.template=${template}
cloudflare-speedtest.naming.auto_detect=${auto}
cloudflare-speedtest.naming.city_override=${city}
cloudflare-speedtest.naming.isp_override=${isp}
cloudflare-speedtest.naming.fallback_city=
cloudflare-speedtest.naming.fallback_isp=
cloudflare-speedtest.test.threads=50
cloudflare-speedtest.test.attempts=4
cloudflare-speedtest.test.download_count=5
cloudflare-speedtest.test.download_seconds=10
cloudflare-speedtest.test.port=443
cloudflare-speedtest.test.test_url=https://speed.cloudflare.com/__down?bytes=99000000
cloudflare-speedtest.test.max_latency_ms=200
cloudflare-speedtest.test.max_loss_ratio=0.2
cloudflare-speedtest.test.min_speed_mbps=0.01
cloudflare-speedtest.test.task_timeout_seconds=900
cloudflare-speedtest.test.ip_file=${TMP}/share/ip.txt
cloudflare-speedtest.geo.request_timeout=1
EOF
}

reset_env() {
    rm -rf "${TMP:?}/runtime" "${TMP:?}/etc"
    mkdir -p "$TMP/runtime" "$TMP/etc"
    : > "$TMP/cfst.args"
    : > "$TMP/plugin.log"
    export CFST_ROOT
    export CFST_LIB_DIR="$LIB"
    export CFST_BIN_DIR="$TMP/bin"
    export CFST_CFST_BIN="$MOCK_CFST"
    export CFST_RUNTIME_DIR="$TMP/runtime"
    export CFST_STATUS_FILE="$TMP/runtime/status.json"
    export CFST_STATE_FILE="$TMP/etc/state.json"
    export CFST_LOCK_DIR="$TMP/runtime/lock"
    export CFST_LOG_FILE="$TMP/plugin.log"
    export CFST_CITIES_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/cities.tsv"
    export CFST_PROVIDERS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/providers.tsv"
    export CFST_COLOS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv"
    export CFST_TEST_UCI_FILE="$TMP/uci"
    export CFST_MOCK_CFST_LOG="$TMP/cfst.args"
    export CFST_MOCK_CFST_FIXTURE="$FIXTURES_R/valid.csv"
    export CFST_MOCK_NFT_LOG="$TMP/nft.args"
    export CFST_MOCK_SSD_LOG="$TMP/ssd.args"
    : > "$TMP/nft.args"
    : > "$TMP/ssd.args"
    export CFST_DIRECT_USER=nobody
    # Git Bash has no nobody account, so hand direct.sh the uid directly.
    export CFST_DIRECT_UID=65534
    unset CFST_MOCK_CFST_SLEEP CFST_MOCK_CFST_EXIT CFST_MOCK_CFST_REAL_SLEEP
    unset CFST_TASK_TIMEOUT_OVERRIDE CFST_STOP_GRACE_SECONDS
    export CFST_DISABLE_WATCHDOG=1
    export CFST_SLEEP_CMD='true'
    export CFST_NOW=1700000000
    export CFST_NOW_TEXT='2023-11-14 22:13:20'
    export PATH="$CFST_ROOT/tests/helpers/mock-bin:$BASE_PATH"
    write_uci
    rm -f "$TMP/requests.jsonl"
}

run_cli() {
    sh "$CLI" "$@"
}

status_text() {
    if [ -f "$CFST_STATUS_FILE" ]; then
        tr -d '\r\n' < "$CFST_STATUS_FILE"
    else
        printf ''
    fi
}

state_text() {
    if [ -f "$CFST_STATE_FILE" ]; then
        tr -d '\r\n' < "$CFST_STATE_FILE"
    else
        printf ''
    fi
}

# --- CLI rejects unknown commands ---
reset_env
set +e
run_cli unknown-command
status="$?"
set -e
assert_eq "$status" "2"

set +e
run_cli run --mode bad --trigger manual
status="$?"
set -e
assert_eq "$status" "2"

set +e
run_cli run --mode test-only --trigger weird
status="$?"
set -e
assert_eq "$status" "2"

# --- test-only: args, phases, no Cloudflare HTTP, last_tested only ---
reset_env
: > "$TMP/requests.jsonl"
write_publish_fixture
start_mock "$TMP/publish_ok.json"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
# The Chinese colo name is resolved at test time and stored in state, so the
# frontend never has to read a data file.
st_state="$(state_text)"
assert_contains "$st_state" '"colo":"HKG"'
assert_contains "$st_state" '"colo_name":"中国 香港"'
args="$(tr -d '\r' < "$TMP/cfst.args")"
assert_contains "$args" ' -p 0'
assert_contains "$args" ' -n 50'
assert_contains "$args" ' -t 4'
assert_contains "$args" ' -dn 5'
assert_contains "$args" ' -dt 10'
assert_contains "$args" ' -tp 443'
assert_contains "$args" ' -tl 200'
assert_contains "$args" ' -tlr 0.2'
assert_contains "$args" ' -url https://speed.cloudflare.com/__down?bytes=99000000'
# absolute -f and -o
case "$args" in
    *" -f ${TMP}/share/ip.txt"*|*" -f $TMP/share/ip.txt"*) : ;;
    *)
        # Windows may normalize path; require -f with absolute-looking path (starts with / or drive)
        printf '%s\n' "$args" | grep -E ' -f (/|[A-Za-z]:)' >/dev/null \
            || fail "expected absolute -f in: $args"
        ;;
esac
printf '%s\n' "$args" | grep -E ' -o (/|[A-Za-z]:|.*runtime)' >/dev/null \
    || fail "expected absolute -o in: $args"
st="$(status_text)"
assert_contains "$st" '"phase":"success"'
# phase history is last-write; ensure success after run. Spot-check log for earlier phases.
log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log_text" 'detecting_network'
assert_contains "$log_text" 'testing'
assert_contains "$log_text" 'validating_result'
case "$log_text" in
    *updating_dns*) fail "test-only must not enter updating_dns" ;;
esac
req="$(request_log_text)"
[ -z "$req" ] || fail "test-only must not call Cloudflare HTTP, got: $req"
persistent="$(state_text)"
assert_contains "$persistent" '"last_tested":{"ip":"104.18.2.10"'
case "$persistent" in
    *'"last_published":{"ip"'*) fail "test-only must not set last_published" ;;
esac

# --- custom relative subdomain path: no geo fields are needed ---
reset_env
write_uci '' '' 0 'nope.invalid' cf
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
persistent="$(state_text)"
assert_contains "$persistent" 'cf.domain.com'

# --- test-and-update success path ---
reset_env
write_publish_fixture
start_mock "$TMP/publish_ok.json"
set +e
run_cli run --mode test-and-update --trigger cron
status="$?"
set -e
assert_eq "$status" "0"
st="$(status_text)"
assert_contains "$st" '"phase":"success"'
log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log_text" 'detecting_network'
assert_contains "$log_text" 'testing'
assert_contains "$log_text" 'validating_result'
assert_contains "$log_text" 'updating_dns'
req="$(request_log_text)"
assert_contains "$req" '"method": "POST"'
assert_contains "$req" '104.18.2.10'
persistent="$(state_text)"
assert_contains "$persistent" '"last_tested":{"ip":"104.18.2.10"'
assert_contains "$persistent" '"last_published":{"ip":"104.18.2.10"'
assert_contains "$persistent" 'szct.domain.com'

# --- lock conflict ---
reset_env
mkdir -p "$CFST_LOCK_DIR"
printf '%s\n' "$$" > "$CFST_LOCK_DIR/pid"
printf '%s\n' '1700000000' > "$CFST_LOCK_DIR/started_at"
printf '%s\n' 'manual' > "$CFST_LOCK_DIR/trigger"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "30"
# cleanup fake lock for later tests
rm -rf "$CFST_LOCK_DIR"

# --- direct mode: rule installed before testing, removed after, cfst dropped
#     to the dedicated user, and the previous IPs are rechecked first ---
reset_env
printf '%s\n' 'cloudflare-speedtest.test.direct_mode=1' >> "$CFST_TEST_UCI_FILE"
cat > "$CFST_STATE_FILE" <<'EOF'
{"schema_version":1,"last_published":{"ip":"104.18.2.10","published_at":1700000000},"last_tested":{"ip":"104.18.1.1","tested_at":1700000000},"geo_cache":null,"managed_record":null,"network_cache":null}
EOF
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
nft_args="$(tr -d '\r' < "$TMP/nft.args")"
assert_contains "$nft_args" 'add table inet cfst_direct'
assert_contains "$nft_args" 'delete table inet cfst_direct'
assert_contains "$(tr -d '\r' < "$TMP/ssd.args")" '-c nobody'
log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log_text" 'recheck candidates=2'
# The recheck must run before the main pass.
recheck_line="$(grep -n 'recheck candidates=' "$CFST_LOG_FILE" | head -1 | cut -d: -f1)"
testing_line="$(grep -n 'phase=testing$' "$CFST_LOG_FILE" | head -1 | cut -d: -f1)"
[ "$recheck_line" -gt "$testing_line" ] || fail 'recheck must be logged inside the testing phase'
assert_contains "$log_text" 'select sticky'

# --- direct mode off: no nftables calls, cfst stays root ---
reset_env
printf '%s\n' 'cloudflare-speedtest.test.direct_mode=0' >> "$CFST_TEST_UCI_FILE"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
assert_eq "$(wc -c < "$TMP/nft.args" | tr -d ' ')" '0'
assert_eq "$(wc -c < "$TMP/ssd.args" | tr -d ' ')" '0'

# --- no qualified result ---
reset_env
export CFST_MOCK_CFST_FIXTURE="$FIXTURES_R/no-qualified.csv"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "51"
st="$(status_text)"
assert_contains "$st" '"phase":"failed"'
assert_contains "$st" 'RESULT_NO_QUALIFIED_IP'
# The log must name the gate that emptied the set, so a run that fails only on
# download speed is distinguishable from one that fails on latency or loss.
log="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log" 'result_reject rows='
assert_contains "$log" 'max_speed_mbps='

# --- a malformed CSV reports the header error, not the generic no-qualified one ---
reset_env
export CFST_MOCK_CFST_FIXTURE="$FIXTURES_R/bad-header.csv"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "50"
st="$(status_text)"
assert_contains "$st" '"phase":"failed"'
assert_contains "$st" 'RESULT_BAD_CSV'

# --- cfst exits 0 without CSV when its latency pre-filter has no candidate ---
reset_env
unset CFST_MOCK_CFST_FIXTURE
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "51"
st="$(status_text)"
assert_contains "$st" '"phase":"failed"'
assert_contains "$st" 'RESULT_NO_QUALIFIED_IP'
# The stable machine-readable error code above is the contract; the localized
# message may be rendered differently by the host shell locale.
# An empty CSV from the download pass means -sl rejected every candidate, so the
# log has to say so; there is no CSV left for result_reject to summarize.
assert_contains "$(tr -d '\r' < "$CFST_LOG_FILE")" 'download_reject no candidate reached required_mbps='

# --- adaptive candidate expansion: 2 -> 3, latency preflight before download ---
reset_env
printf '%s\n' 104.18.10.1 104.18.10.2 104.18.10.3 104.18.10.4 > "$TMP/share/ip.txt"
printf '%s\n' 'cloudflare-speedtest.test.candidate_count=2' >> "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.test.test_all=0' >> "$CFST_TEST_UCI_FILE"
export CFST_MOCK_CFST_FIXTURE="$FIXTURES_R/valid.csv"
export CFST_MOCK_CFST_DOWNLOAD_FIXTURE="$FIXTURES_R/valid.csv"
export CFST_MOCK_CFST_PREFLIGHT_FIXTURES="$FIXTURES_R/no-qualified-latency.csv:$FIXTURES_R/valid.csv"
export CFST_MOCK_CFST_PREFLIGHT_COUNT_FILE="$TMP/preflight-count"
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log_text" 'latency_preflight candidates=2'
assert_contains "$log_text" 'latency_preflight no qualified result; expanding candidates=2 next=3'
assert_contains "$log_text" 'latency_preflight qualified candidates=3'
# The download pass must run on the preflight survivors, not the whole sample,
# so the expensive latency phase is not repeated. valid.csv has five rows that
# clear the latency/loss gate; the -f argument itself is always the sanitised
# copy, so the survivor count is the observable signal.
assert_contains "$log_text" 'latency_preflight survivors=5'
preflight_count="$(grep -c -- ' -dd' "$TMP/cfst.args" || true)"
assert_eq "$preflight_count" "2"
last_args="$(tail -n 1 "$TMP/cfst.args")"
case "$last_args" in
    *' -dd'*) fail 'download phase must not use latency-only -dd' ;;
esac
assert_contains "$last_args" ' -f '
# -sl belongs to the download pass only, so cfst keeps testing past unusable
# low-latency IPs instead of stopping after -dn addresses.
assert_contains "$last_args" ' -sl 0.001250'
first_args="$(head -n 1 "$TMP/cfst.args")"
case "$first_args" in
    *' -sl '*) fail 'latency preflight must not pass -sl' ;;
esac
assert_contains "$(status_text)" '"phase":"success"'
unset CFST_MOCK_CFST_DOWNLOAD_FIXTURE CFST_MOCK_CFST_PREFLIGHT_FIXTURES CFST_MOCK_CFST_PREFLIGHT_COUNT_FILE

# --- preferred provider + test-all: keep finite returned IPs, do not pass -allip ---
reset_env
printf '%s\n' 'cloudflare-speedtest.test.ip_source=preferred' >> "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.test.test_all=1' >> "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.preferred.provider=ct' >> "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.preferred.url_ct=http://preferred.test/ct' >> "$CFST_TEST_UCI_FILE"
cat > "$TMP/preferred-body" <<'EOF'
104.18.10.1#CF 电信优选
104.18.10.2#CF 电信优选
EOF
cat > "$TMP/curl" <<'EOF'
#!/bin/sh
out=''
prev=''
for arg in "$@"; do
    if [ "$prev" = '--output' ]; then out="$arg"; fi
    prev="$arg"
done
cp "${CFST_PREFERRED_FIXTURE:?}" "$out"
EOF
chmod +x "$TMP/curl"
export CFST_PREFERRED_FIXTURE="$TMP/preferred-body"
export PATH="$TMP:$PATH"
# The test fixture supplies a valid CSV; the important contract is the argv.
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
last_args="$(tail -n 1 "$TMP/cfst.args")"
case "$last_args" in *' -allip'*) fail 'preferred finite IP list must not receive -allip' ;; esac
assert_contains "$last_args" ' -f '
unset CFST_PREFERRED_FIXTURE

# --- GeoIP failure with usable manual override (auto on, bad providers) ---
reset_env
write_uci sz ct 1 'nope.invalid'
write_publish_fixture
start_mock "$TMP/publish_ok.json"
set +e
run_cli run --mode test-and-update --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
persistent="$(state_text)"
assert_contains "$persistent" 'szct.domain.com'
assert_contains "$persistent" '104.18.2.10'

# --- DNS failure preserves prior publication ---
reset_env
cat > "$CFST_STATE_FILE" <<'EOF'
{"schema_version":1,"last_published":{"ip":"1.1.1.1","hostname":"szct.domain.com"},"last_tested":null,"geo_cache":null,"managed_record":{"id":"rec-old","name":"szct.domain.com","type":"A","content":"1.1.1.1","zone_id":"zone-abc"}}
EOF
write_dns_fail_fixture
start_mock "$TMP/dns_fail.json"
set +e
run_cli run --mode test-and-update --trigger manual
status="$?"
set -e
assert_eq "$status" "61"
persistent="$(state_text)"
assert_contains "$persistent" '"last_published":{"ip":"1.1.1.1"'
assert_contains "$persistent" '"last_tested":{"ip":"104.18.2.10"'

# --- new publication + cleanup failure 鈫?partial_success 66 ---
reset_env
write_uci bj cm 0 'nope.invalid'
cat > "$CFST_STATE_FILE" <<'EOF'
{"schema_version":1,"last_published":{"ip":"8.8.8.8","hostname":"szct.domain.com"},"last_tested":null,"geo_cache":null,"managed_record":{"id":"rec-old","name":"szct.domain.com","type":"A","content":"8.8.8.8","zone_id":"zone-abc"}}
EOF
write_cleanup_fail_fixture
start_mock "$TMP/cleanup_fail_best.json"
set +e
run_cli run --mode test-and-update --trigger manual
status="$?"
set -e
assert_eq "$status" "66"
st="$(status_text)"
assert_contains "$st" '"phase":"partial_success"'
persistent="$(state_text)"
assert_contains "$persistent" 'bjcm.domain.com'
assert_contains "$persistent" '104.18.2.10'
assert_contains "$persistent" '"id":"rec-new"'

# --- timeout ---
reset_env
unset CFST_DISABLE_WATCHDOG
export CFST_TASK_TIMEOUT_OVERRIDE=1
export CFST_MOCK_CFST_SLEEP=5
export CFST_MOCK_CFST_REAL_SLEEP=sleep
export CFST_SLEEP_CMD=sleep
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
# timeout should fail with stable CFST_TIMEOUT code (52)
assert_eq "$status" "52"
st="$(status_text)"
assert_contains "$st" 'CFST_TIMEOUT'
unset CFST_TASK_TIMEOUT_OVERRIDE CFST_MOCK_CFST_SLEEP CFST_MOCK_CFST_REAL_SLEEP
export CFST_DISABLE_WATCHDOG=1
export CFST_SLEEP_CMD=true

# --- cancellation via stop ---
reset_env
export CFST_MOCK_CFST_SLEEP=30
export CFST_MOCK_CFST_REAL_SLEEP=sleep
export CFST_SLEEP_CMD=sleep
export CFST_STOP_GRACE_SECONDS=1
sh "$CLI" run --mode test-only --trigger manual >/dev/null 2>&1 &
BG_PID=$!
# wait until lock appears
i=0
while [ ! -f "$CFST_LOCK_DIR/pid" ] && [ "$i" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
[ -f "$CFST_LOCK_DIR/pid" ] || fail 'runner did not acquire lock for cancel test'
set +e
run_cli stop
stop_status="$?"
set -e
assert_eq "$stop_status" "0"
# wait for background runner to exit
i=0
while kill -0 "$BG_PID" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
wait "$BG_PID" 2>/dev/null || true
BG_PID=''
st="$(status_text)"
assert_contains "$st" '"phase":"cancelled"'
[ ! -d "$CFST_LOCK_DIR" ] || fail 'lock should be released after stop'
unset CFST_MOCK_CFST_SLEEP CFST_MOCK_CFST_REAL_SLEEP CFST_STOP_GRACE_SECONDS
export CFST_SLEEP_CMD=true

# --- apply-schedule writes marked cron line ---
reset_env
export CFST_CRONTAB_FILE="$TMP/crontab.root"
export CFST_DEFERRED_SCHEDULE_FILE="$TMP/deferred-schedule"
export CFST_CRON_RELOAD_CMD="true"
export CFST_HOSTNAME=host46
rm -f "$CFST_DEFERRED_SCHEDULE_FILE"
: > "$CFST_CRONTAB_FILE"
set +e
run_cli apply-schedule
status="$?"
set -e
assert_eq "$status" "0"
cron_text="$(tr -d '\r' < "$CFST_CRONTAB_FILE")"
assert_contains "$cron_text" '17 */6 * * * /usr/bin/cloudflare-speedtest run --mode test-and-update --trigger cron'
assert_contains "$cron_text" 'cloudflare-speedtest'
unset CFST_CRONTAB_FILE CFST_DEFERRED_SCHEDULE_FILE CFST_CRON_RELOAD_CMD CFST_HOSTNAME

# --- status / result / logs read-only smoke ---
reset_env
printf '%s\n' '{"phase":"idle","message":"Idle","updated_at":1}' > "$CFST_STATUS_FILE"
out="$(run_cli status)"
assert_contains "$out" '"phase":"idle"'
printf '%s\n' '{"schema_version":1,"last_published":null,"last_tested":{"ip":"1.2.3.4"},"geo_cache":null,"managed_record":null}' > "$CFST_STATE_FILE"
out="$(run_cli result)"
assert_contains "$out" '1.2.3.4'
printf 'hello-log\n' > "$CFST_LOG_FILE"
out="$(run_cli logs 100)"
assert_contains "$out" 'hello-log'
run_cli clear-logs
[ ! -f "$CFST_LOG_FILE" ] || fail 'clear-logs should remove log file'

# --- validate ---
reset_env
set +e
run_cli validate
status="$?"
set -e
assert_eq "$status" "0"

stop_mock
printf 'OK runner integration\n'
