#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

SCHEDULE_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/schedule.sh"
assert_file_exists "$SCHEDULE_SH"
# shellcheck disable=SC1090,SC1091
. "$SCHEDULE_SH"

TMP="${TMPDIR:-/tmp}/cfst-schedule-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CFST_CRONTAB_FILE="$TMP/root"
export CFST_CRON_RELOAD_CMD="$TMP/reload.sh"
export CFST_HOTPLUG_STAMP_FILE="$TMP/hotplug.stamp"
export CFST_HOTPLUG_DELAY=300
export CFST_WAN_INTERFACE=wan
export CFST_HOTPLUG_RUN_CMD="$TMP/hotplug-run.sh"
export CFST_NOW=1700000000

: > "$CFST_CRONTAB_FILE"
printf '#!/bin/sh\necho reload >> "%s/reload.log"\n' "$TMP" > "$CFST_CRON_RELOAD_CMD"
chmod +x "$CFST_CRON_RELOAD_CMD"
printf '#!/bin/sh\necho "run $*" >> "%s/hotplug-run.log"\n' "$TMP" > "$CFST_HOTPLUG_RUN_CMD"
chmod +x "$CFST_HOTPLUG_RUN_CMD"
: > "$TMP/reload.log"
: > "$TMP/hotplug-run.log"

# --- schedule_minute is deterministic ---
m1="$(schedule_minute host46)"
m2="$(schedule_minute host46)"
assert_eq "$m1" "$m2"
assert_eq "$m1" "17"
m_other="$(schedule_minute host0)"
[ "$m_other" != "$m1" ] || fail 'different hostnames should usually differ (host0 vs host46)'

# --- write_cron for 6h produces expected line with minute from schedule_minute ---
CFST_ENABLED=1
CFST_INTERVAL_HOURS=6
CFST_HOSTNAME=host46
export CFST_ENABLED CFST_INTERVAL_HOURS CFST_HOSTNAME
write_cron
content="$(cat "$CFST_CRONTAB_FILE")"
assert_contains "$content" '17 */6 * * * /usr/bin/cloudflare-speedtest run --mode test-and-update --trigger cron'
assert_contains "$content" 'cloudflare-speedtest'
line_count="$(grep -c 'cloudflare-speedtest' "$CFST_CRONTAB_FILE" || true)"
assert_eq "$line_count" "1"
assert_eq "$(cat "$TMP/reload.log")" "reload"

# --- mode 0644 ---
mode="$(stat -c '%a' "$CFST_CRONTAB_FILE" 2>/dev/null || stat -f '%OLp' "$CFST_CRONTAB_FILE")"
case "$mode" in
    *644) : ;;
    *) fail "expected mode 0644, got $mode" ;;
esac

# --- invalid interval rejected ---
CFST_INTERVAL_HOURS=5
set +e
write_cron
status="$?"
set -e
[ "$status" -ne 0 ] || fail 'interval 5 should be rejected'
CFST_INTERVAL_HOURS=6

# --- preserves other crontab lines ---
printf '0 * * * * /bin/true\n' > "$CFST_CRONTAB_FILE"
: > "$TMP/reload.log"
write_cron
content="$(cat "$CFST_CRONTAB_FILE")"
assert_contains "$content" '0 * * * * /bin/true'
assert_contains "$content" '17 */6 * * * /usr/bin/cloudflare-speedtest run --mode test-and-update --trigger cron'

# --- idempotent re-apply (no extra lines, reload only on change) ---
: > "$TMP/reload.log"
write_cron
line_count="$(grep -c 'cloudflare-speedtest' "$CFST_CRONTAB_FILE" || true)"
assert_eq "$line_count" "1"
[ ! -s "$TMP/reload.log" ] || fail 'reload should not run when content unchanged'

# --- disabled removes only marked cron line ---
CFST_ENABLED=0
export CFST_ENABLED
: > "$TMP/reload.log"
remove_cron
content="$(cat "$CFST_CRONTAB_FILE")"
assert_contains "$content" '0 * * * * /bin/true'
case "$content" in
    *cloudflare-speedtest*) fail 'marked cron line should be removed' ;;
esac
assert_eq "$(cat "$TMP/reload.log")" "reload"

# re-remove is idempotent
: > "$TMP/reload.log"
remove_cron
[ ! -s "$TMP/reload.log" ] || fail 'reload should not run when already removed'

# --- hotplug ignores non-WAN ---
: > "$TMP/hotplug-run.log"
rm -f "$CFST_HOTPLUG_STAMP_FILE"
hotplug_schedule ifup lan
[ ! -s "$TMP/hotplug-run.log" ] || fail 'non-WAN ifup should be ignored'
[ ! -f "$CFST_HOTPLUG_STAMP_FILE" ] || fail 'non-WAN should not stamp'

# --- hotplug ignores ifdown ---
hotplug_schedule ifdown wan
[ ! -s "$TMP/hotplug-run.log" ] || fail 'ifdown should be ignored'

# --- hotplug schedules delayed background (not inline) ---
: > "$TMP/hotplug-run.log"
CFST_STARTUP_DELAY=120
export CFST_STARTUP_DELAY
# mock sleep+background runner via CFST_HOTPLUG_BG_CMD
export CFST_HOTPLUG_BG_CMD="$TMP/bg.sh"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "bg delay=$1" >> "%s/hotplug-run.log"\necho "bg cmd=$2" >> "%s/hotplug-run.log"\n' "$TMP" "$TMP" > "$CFST_HOTPLUG_BG_CMD"
chmod +x "$CFST_HOTPLUG_BG_CMD"
hotplug_schedule ifup wan
assert_file_exists "$CFST_HOTPLUG_STAMP_FILE"
bg_log="$(cat "$TMP/hotplug-run.log")"
assert_contains "$bg_log" 'bg delay=120'
assert_contains "$bg_log" 'hotplug'

# --- hotplug debounce within 300s ---
: > "$TMP/hotplug-run.log"
CFST_NOW=1700000100
export CFST_NOW
hotplug_schedule ifup wan
[ ! -s "$TMP/hotplug-run.log" ] || fail 'hotplug within debounce window should be ignored'

# after debounce window, allow again
: > "$TMP/hotplug-run.log"
CFST_NOW=1700000400
export CFST_NOW
hotplug_schedule ifup wan
bg_log="$(cat "$TMP/hotplug-run.log")"
assert_contains "$bg_log" 'bg delay=120'

printf 'schedule tests passed\n'
