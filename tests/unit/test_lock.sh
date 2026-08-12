#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

LOCK_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/lock.sh"
assert_file_exists "$LOCK_SH"
# shellcheck disable=SC1090,SC1091
. "$LOCK_SH"

TMP="${TMPDIR:-/tmp}/cfst-lock-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

CFST_LOCK_DIR="$TMP/lock"
CFST_SELF_PID=1234
CFST_NOW=1700000000
CFST_TEST_LIVE_PIDS='1234 4321'
CFST_KILL_CMD="$CFST_ROOT/tests/helpers/mock-bin/cfst-kill"
export CFST_LOCK_DIR CFST_SELF_PID CFST_NOW CFST_TEST_LIVE_PIDS CFST_KILL_CMD

acquire_lock manual
assert_file_exists "$CFST_LOCK_DIR/pid"
assert_eq "$(read_lock pid)" "1234"
assert_eq "$(read_lock trigger)" "manual"

set +e
acquire_lock cron
status="$?"
set -e
assert_eq "$status" "30"
assert_eq "$CFST_ERROR_CODE" "TASK_ALREADY_RUNNING"

CFST_SELF_PID=4321
export CFST_SELF_PID
set +e
release_lock
status="$?"
set -e
assert_eq "$status" "31"
assert_file_exists "$CFST_LOCK_DIR/pid"

CFST_SELF_PID=1234
export CFST_SELF_PID
release_lock
[ ! -d "$CFST_LOCK_DIR" ] || fail 'owner failed to release lock'

mkdir -p "$CFST_LOCK_DIR"
printf '%s\n' '9999' > "$CFST_LOCK_DIR/pid"
printf '%s\n' '1600000000' > "$CFST_LOCK_DIR/started_at"
printf '%s\n' 'cron' > "$CFST_LOCK_DIR/trigger"
CFST_TEST_LIVE_PIDS='1234'
export CFST_TEST_LIVE_PIDS
acquire_lock hotplug
assert_eq "$(read_lock pid)" "1234"
assert_eq "$(read_lock trigger)" "hotplug"
