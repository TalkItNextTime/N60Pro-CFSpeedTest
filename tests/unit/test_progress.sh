#!/bin/sh
# Parsing cfst's progress counter and rendering it as a status message.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

PROGRESS_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/progress.sh"
assert_file_exists "$PROGRESS_SH"

TMP="${TMPDIR:-/tmp}/cfst-progress-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/progress.sh
. "$PROGRESS_SH"

# --- progress_snapshot: last counter wins, carriage returns and all ---
# cfst redraws the bar in place, so the capture is one long line of \r-separated
# frames rather than many lines.
printf '0 / 2000 [___]\r120 / 2000 [#__]\r980 / 2000 [##_]' > "$TMP/latency.log"
assert_eq "$(progress_snapshot "$TMP/latency.log")" '980 2000'

# The download bar has the same shape with much smaller totals.
printf '开始下载测速\n0 / 10 [____]\r3 / 10 [#___]' > "$TMP/download.log"
assert_eq "$(progress_snapshot "$TMP/download.log")" '3 10'

# No counter yet, empty file and missing file must all stay quiet.
printf '# XIU2/CloudflareSpeedTest v2.3.5\n' > "$TMP/banner.log"
assert_eq "$(progress_snapshot "$TMP/banner.log")" ''
: > "$TMP/empty.log"
assert_status 1 progress_snapshot "$TMP/empty.log"
assert_status 1 progress_snapshot "$TMP/missing.log"

# --- progress_message: percentage plus a linear estimate ---
# 40 of 200 in 20s implies 80s left, which reads as minutes and seconds.
assert_eq "$(progress_message '正在测试延迟' 40 200 20)" '正在测试延迟 40/200（20%，预计剩余 1 分 20 秒）'
# Under a minute stays in seconds.
assert_eq "$(progress_message '正在测试延迟' 80 100 40)" '正在测试延迟 80/100（80%，预计剩余 10 秒）'
# Over a minute the estimate switches to minutes and seconds.
assert_eq "$(progress_message '正在测试延迟' 100 2000 30)" '正在测试延迟 100/2000（5%，预计剩余 9 分 30 秒）'
# Nothing finished yet: report position without inventing an estimate.
assert_eq "$(progress_message '正在测速' 0 10 5)" '正在测速 0/10（0%）'
# Complete: no estimate either.
assert_eq "$(progress_message '正在测速' 10 10 40)" '正在测速 10/10（100%）'
# A zero total degrades to the bare label rather than dividing by zero.
assert_eq "$(progress_message '正在测速' 0 0 5)" '正在测速'

printf 'progress tests passed\n'
