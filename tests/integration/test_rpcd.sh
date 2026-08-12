#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

RPCD="$CFST_ROOT/package/luci-app-cloudflare-speedtest/root/usr/libexec/rpcd/cloudflare-speedtest"
ACL="$CFST_ROOT/package/luci-app-cloudflare-speedtest/root/etc/acl.d/luci-app-cloudflare-speedtest.json"
CLI="$CFST_ROOT/package/cloudflare-speedtest/files/usr/bin/cloudflare-speedtest"
LIB="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest"

assert_file_exists "$RPCD"
assert_file_exists "$ACL"
assert_file_exists "$CLI"

# Use repo-local temp so host Python and Git Bash share the same path space on Windows.
TMP="$CFST_ROOT/.tmp/cfst-rpcd-test.$$"
mkdir -p "$TMP/runtime" "$TMP/etc/config" "$TMP/bin" "$TMP/log"
trap 'rm -rf "$TMP"' EXIT INT TERM

SECRET_TOKEN='super-secret-token-value-never-leak'
NEW_TOKEN='another-secret-token-xyz'

export PATH="$TMP/bin:$CFST_ROOT/tests/helpers/mock-bin:/usr/bin:/bin:$PATH"
export CFST_LIB_DIR="$LIB"
export CFST_RUNTIME_DIR="$TMP/runtime"
export CFST_STATUS_FILE="$TMP/runtime/status.json"
export CFST_STATE_FILE="$TMP/etc/state.json"
export CFST_LOCK_DIR="$TMP/runtime/lock"
export CFST_LOG_FILE="$TMP/log/cloudflare-speedtest.log"
export CFST_UCI_CONFIG="$TMP/etc/config/cloudflare-speedtest"
export CFST_TEST_UCI_FILE="$TMP/uci.kv"
export CFST_TEST_UCI_COMMIT_LOG="$TMP/uci.commits"
export CFST_TEST_CHMOD_LOG="$TMP/chmod.log"
export CFST_MOCK_RUN_LOG="$TMP/run.log"
export CFST_SLEEP_CMD='true'
export CFST_KILL_CMD="$CFST_ROOT/tests/helpers/mock-bin/cfst-kill"
export CFST_TEST_LIVE_PIDS=''
export CFST_NOW=1700000000
export CFST_NOW_TEXT='2023-11-14 22:13:20'

# Mock chmod: record invocations.
cat > "$TMP/bin/chmod" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CFST_TEST_CHMOD_LOG}"
exit 0
EOF
chmod +x "$TMP/bin/chmod"

# Mock task binary used by start: record argv and exit.
cat > "$TMP/bin/cfst-run-recorder" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'argv:'
    for arg in "$@"; do
        printf ' %s' "$arg"
    done
    printf '\n'
} >> "${CFST_MOCK_RUN_LOG}"
exit 0
EOF
chmod +x "$TMP/bin/cfst-run-recorder"

# CLI shim: enough surface for rpcd without full runner stack.
cat > "$TMP/bin/cloudflare-speedtest-shim" <<'EOF'
#!/bin/sh
set -eu
cmd="${1:-}"
[ "$#" -ge 1 ] && shift
case "$cmd" in
    status)
        if [ -f "$CFST_STATUS_FILE" ]; then cat "$CFST_STATUS_FILE"
        else printf '%s\n' '{"phase":"idle","message":"Idle","updated_at":0}'
        fi
        ;;
    result)
        if [ -f "$CFST_STATE_FILE" ]; then cat "$CFST_STATE_FILE"
        else printf '%s\n' '{"schema_version":1,"last_published":null,"last_tested":null,"geo_cache":null,"managed_record":null}'
        fi
        ;;
    validate)
        token="$(uci -q get cloudflare-speedtest.cloudflare.api_token 2>/dev/null || true)"
        zone="$(uci -q get cloudflare-speedtest.cloudflare.zone 2>/dev/null || true)"
        if [ -z "$token" ]; then
            printf '%s\n' '{"valid":false,"error_code":"CONFIG_TOKEN_MISSING","error_message":"missing token"}'
            exit 20
        fi
        if [ -z "$zone" ]; then
            printf '%s\n' '{"valid":false,"error_code":"CONFIG_ZONE_MISSING","error_message":"missing zone"}'
            exit 20
        fi
        printf '%s\n' '{"valid":true}'
        ;;
    logs)
        limit="${1:-65536}"
        case "$limit" in ''|*[!0-9]*) exit 2 ;; esac
        [ "$limit" -le 65536 ] || limit=65536
        [ -f "$CFST_LOG_FILE" ] || exit 0
        tail -c "$limit" "$CFST_LOG_FILE"
        ;;
    clear-logs)
        rm -f "$CFST_LOG_FILE" "$CFST_LOG_FILE".1 "$CFST_LOG_FILE".2
        ;;
    stop)
        [ -d "$CFST_LOCK_DIR" ] || exit 0
        owner=""
        [ -f "$CFST_LOCK_DIR/pid" ] && IFS= read -r owner < "$CFST_LOCK_DIR/pid" || true
        case "$owner" in ''|*[!0-9]*) ;; *)
            if [ -n "${CFST_KILL_CMD:-}" ]; then
                "$CFST_KILL_CMD" -TERM "$owner" 2>/dev/null || true
            else
                kill -TERM "$owner" 2>/dev/null || true
            fi
            ;;
        esac
        rm -rf "$CFST_LOCK_DIR"
        ;;
    run)
        mode=''; trigger=''
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --mode) mode="$2"; shift 2 ;;
                --trigger) trigger="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        exec cfst-run-recorder run --mode "$mode" --trigger "$trigger"
        ;;
    *)
        printf 'unknown command: %s\n' "$cmd" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$TMP/bin/cloudflare-speedtest-shim"
export CFST_BIN="$TMP/bin/cloudflare-speedtest-shim"

cat > "$CFST_TEST_UCI_FILE" <<EOF
cloudflare-speedtest.main.enabled=1
cloudflare-speedtest.main.interval_hours=6
cloudflare-speedtest.main.startup_delay=120
cloudflare-speedtest.main.log_level=info
cloudflare-speedtest.cloudflare.api_token=${SECRET_TOKEN}
cloudflare-speedtest.cloudflare.zone=domain.com
cloudflare-speedtest.cloudflare.ttl=1
cloudflare-speedtest.naming.template={city}{isp}.{zone}
cloudflare-speedtest.naming.auto_detect=1
cloudflare-speedtest.test.threads=50
cloudflare-speedtest.test.port=443
EOF
: > "$CFST_UCI_CONFIG"
: > "$CFST_TEST_UCI_COMMIT_LOG"
: > "$CFST_TEST_CHMOD_LOG"
: > "$CFST_MOCK_RUN_LOG"

printf '%s\n' '{"phase":"idle","message":"Idle","updated_at":1700000000}' > "$CFST_STATUS_FILE"
printf '%s\n' '{"schema_version":1,"last_published":null,"last_tested":{"ip":"1.1.1.1"},"geo_cache":null,"managed_record":null}' > "$CFST_STATE_FILE"

rpcd_call() {
    method="$1"
    input="${2-}"
    [ -n "$input" ] || input='{}'
    printf '%s\n' "$input" | sh "$RPCD" call "$method"
}

json_field_len() {
    # json_field_len <json> <field>
    printf '%s\n' "$1" | python3 -c '
import json, sys
data = json.load(sys.stdin)
field = sys.argv[1]
text = data.get(field) or ""
print(len(text) if isinstance(text, str) else 0)
' "$2"
}

# --- list ---
LIST_OUT="$(sh "$RPCD" list)"
case "$LIST_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in list output' ;; esac
for method in status result start stop validate logs clear_logs config_summary set_token; do
    assert_contains "$LIST_OUT" "\"$method\""
done
assert_contains "$LIST_OUT" '"mode"'
assert_contains "$LIST_OUT" '"token"'
assert_contains "$LIST_OUT" '"clear"'

# --- ACL least privilege ---
ACL_TEXT="$(tr -d '\r' < "$ACL")"
case "$ACL_TEXT" in *'"file"'*) fail 'ACL must not grant generic file' ;; esac
case "$ACL_TEXT" in *'"exec"'*) fail 'ACL must not grant generic exec' ;; esac
case "$ACL_TEXT" in *'"*"'*) fail 'ACL must not grant unrestricted wildcard' ;; esac
assert_contains "$ACL_TEXT" 'cloudflare-speedtest'
assert_contains "$ACL_TEXT" 'status'
assert_contains "$ACL_TEXT" 'config_summary'
assert_contains "$ACL_TEXT" 'start'
assert_contains "$ACL_TEXT" 'set_token'

# --- status / result ---
STATUS_OUT="$(rpcd_call status '{}')"
assert_contains "$STATUS_OUT" '"phase"'
case "$STATUS_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in status' ;; esac

RESULT_OUT="$(rpcd_call result '{}')"
assert_contains "$RESULT_OUT" 'schema_version'
case "$RESULT_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in result' ;; esac

# --- config_summary ---
SUMMARY_OUT="$(rpcd_call config_summary '{}')"
assert_contains "$SUMMARY_OUT" '"token_configured"'
assert_contains "$SUMMARY_OUT" 'true'
assert_contains "$SUMMARY_OUT" '"zone"'
assert_contains "$SUMMARY_OUT" 'domain.com'
case "$SUMMARY_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in config_summary' ;; esac
case "$SUMMARY_OUT" in *api_token*) fail 'api_token key must not appear in config_summary' ;; esac

# --- start accepts only test-only / test-and-update ---
: > "$CFST_MOCK_RUN_LOG"
START_OUT="$(rpcd_call start '{"mode":"test-only"}')"
assert_contains "$START_OUT" '"accepted"'
assert_contains "$START_OUT" 'true'
case "$START_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in start' ;; esac

# Wait briefly for async recorder (foreground-friendly poll).
i=0
while [ ! -s "$CFST_MOCK_RUN_LOG" ] && [ "$i" -lt 40 ]; do
    # shellcheck disable=SC2016
    "$CFST_SLEEP_CMD" 2>/dev/null || true
    # real short sleep when available
    sleep 0.05 2>/dev/null || true
    i=$((i + 1))
done
# If still empty, the background job may have been lost; run a sync probe via direct env check.
if [ ! -s "$CFST_MOCK_RUN_LOG" ]; then
    # Fallback: invoke start path pieces are broken on this host — fail clearly.
    fail "start did not launch run recorder (log empty). start_out=$START_OUT"
fi
RUN_LOG="$(tr -d '\r' < "$CFST_MOCK_RUN_LOG")"
assert_contains "$RUN_LOG" 'test-only'
assert_contains "$RUN_LOG" 'manual'

: > "$CFST_MOCK_RUN_LOG"
START2_OUT="$(rpcd_call start '{"mode":"test-and-update"}')"
assert_contains "$START2_OUT" '"accepted"'
assert_contains "$START2_OUT" 'true'
i=0
while [ ! -s "$CFST_MOCK_RUN_LOG" ] && [ "$i" -lt 40 ]; do
    sleep 0.05 2>/dev/null || true
    i=$((i + 1))
done
[ -s "$CFST_MOCK_RUN_LOG" ] || fail 'test-and-update did not launch'
assert_contains "$(tr -d '\r' < "$CFST_MOCK_RUN_LOG")" 'test-and-update'

BAD_OUT="$(rpcd_call start '{"mode":"evil"}')"
case "$BAD_OUT" in *'"accepted":true'*) fail 'evil mode must not be accepted' ;; esac
assert_contains "$BAD_OUT" 'error'

# --- start rejects lock conflict ---
mkdir -p "$CFST_LOCK_DIR"
printf '%s\n' '4242' > "$CFST_LOCK_DIR/pid"
printf '%s\n' '1700000000' > "$CFST_LOCK_DIR/started_at"
printf '%s\n' 'cron' > "$CFST_LOCK_DIR/trigger"
export CFST_TEST_LIVE_PIDS='4242'
CONFLICT_OUT="$(rpcd_call start '{"mode":"test-only"}')"
case "$CONFLICT_OUT" in *'"accepted":true'*) fail 'conflict must not be accepted' ;; esac
assert_contains "$CONFLICT_OUT" 'TASK_ALREADY_RUNNING'
rm -rf "$CFST_LOCK_DIR"
export CFST_TEST_LIVE_PIDS=''

# --- stop ---
mkdir -p "$CFST_LOCK_DIR"
printf '%s\n' '4242' > "$CFST_LOCK_DIR/pid"
export CFST_TEST_LIVE_PIDS='4242'
STOP_OUT="$(rpcd_call stop '{}')"
case "$STOP_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in stop' ;; esac
[ ! -d "$CFST_LOCK_DIR" ] || fail 'stop did not clear lock'
export CFST_TEST_LIVE_PIDS=''

# --- validate ---
VAL_OUT="$(rpcd_call validate '{}')"
assert_contains "$VAL_OUT" '"valid"'
case "$VAL_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in validate' ;; esac

# --- logs capped at 65536 ---
# Build oversized log with pure shell (Python may not understand Git Bash paths on Windows).
i=0
: > "$CFST_LOG_FILE"
while [ "$i" -lt 70 ]; do
    # 1024 bytes of L per iteration => 71680 total
    printf '%s' "$(dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\0' 'L')" >> "$CFST_LOG_FILE"
    i=$((i + 1))
done
# Fallback if dd/tr produced nothing
if [ ! -s "$CFST_LOG_FILE" ]; then
    i=0
    while [ "$i" -lt 700 ]; do
        printf 'LLLLLLLLLL' >> "$CFST_LOG_FILE"
        i=$((i + 1))
    done
fi
[ "$(wc -c < "$CFST_LOG_FILE" | tr -d ' ')" -gt 65536 ] || fail 'failed to build oversized log fixture'
LOGS_OUT="$(rpcd_call logs '{}')"
case "$LOGS_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in logs' ;; esac
LOG_LEN="$(json_field_len "$LOGS_OUT" log)"
[ "$LOG_LEN" -le 65536 ] || fail "logs exceeded 65536 bytes: $LOG_LEN"
[ "$LOG_LEN" -gt 0 ] || fail 'logs returned empty for large file'

LOGS2_OUT="$(rpcd_call logs '{"bytes":999999}')"
LOG_LEN2="$(json_field_len "$LOGS2_OUT" log)"
[ "$LOG_LEN2" -le 65536 ] || fail "logs bytes param not capped: $LOG_LEN2"

# --- clear_logs ---
CLEAR_OUT="$(rpcd_call clear_logs '{}')"
[ ! -e "$CFST_LOG_FILE" ] || fail 'clear_logs left active log'
case "$CLEAR_OUT" in *"$SECRET_TOKEN"*) fail 'token leaked in clear_logs' ;; esac

# --- set_token ---
: > "$CFST_TEST_UCI_COMMIT_LOG"
: > "$CFST_TEST_CHMOD_LOG"

SET1="$(rpcd_call set_token '{}')"
case "$SET1" in *"$SECRET_TOKEN"*) fail 'token leaked in set_token response' ;; esac
token_now="$(uci -q get cloudflare-speedtest.cloudflare.api_token)"
assert_eq "$token_now" "$SECRET_TOKEN"

SET2="$(rpcd_call set_token '{"token":""}')"
token_now="$(uci -q get cloudflare-speedtest.cloudflare.api_token)"
assert_eq "$token_now" "$SECRET_TOKEN"

SET3="$(rpcd_call set_token '{"clear":true}')"
token_now="$(uci -q get cloudflare-speedtest.cloudflare.api_token 2>/dev/null || printf '')"
assert_eq "$token_now" ""
case "$SET3" in *"$SECRET_TOKEN"*) fail 'token leaked after clear' ;; esac

SET4="$(rpcd_call set_token "{\"token\":\"$NEW_TOKEN\"}")"
token_now="$(uci -q get cloudflare-speedtest.cloudflare.api_token)"
assert_eq "$token_now" "$NEW_TOKEN"
case "$SET4" in *"$NEW_TOKEN"*) fail 'new token leaked in set_token response' ;; esac
case "$SET4" in *"$SECRET_TOKEN"*) fail 'old token leaked in set_token response' ;; esac

COMMITS="$(tr -d '\r' < "$CFST_TEST_UCI_COMMIT_LOG")"
assert_contains "$COMMITS" 'cloudflare-speedtest'
while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    assert_eq "$line" 'cloudflare-speedtest'
done <<EOF
$COMMITS
EOF

CHMOD_LOG="$(tr -d '\r' < "$CFST_TEST_CHMOD_LOG")"
assert_contains "$CHMOD_LOG" '0600'
assert_contains "$CHMOD_LOG" 'cloudflare-speedtest'

ALL_OUT="$LIST_OUT$STATUS_OUT$RESULT_OUT$SUMMARY_OUT$START_OUT$START2_OUT$BAD_OUT$CONFLICT_OUT$STOP_OUT$VAL_OUT$LOGS_OUT$LOGS2_OUT$CLEAR_OUT$SET1$SET2$SET3$SET4"
case "$ALL_OUT" in *"$SECRET_TOKEN"*) fail 'SECRET_TOKEN appeared in some RPC output' ;; esac
case "$ALL_OUT" in *"$NEW_TOKEN"*) fail 'NEW_TOKEN appeared in some RPC output' ;; esac

printf 'test_rpcd.sh: ok\n'
