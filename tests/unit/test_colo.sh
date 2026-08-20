#!/bin/sh
# colo code to Chinese datacenter name lookup.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

COLO_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh"
assert_file_exists "$COLO_SH"
export CFST_COLOS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh
. "$COLO_SH"

assert_eq "$(colo_chinese_name LAX)" '美国 洛杉矶'
assert_eq "$(colo_chinese_name FRA)" '德国 法兰克福'
assert_eq "$(colo_chinese_name AMS)" '荷兰 阿姆斯特丹'
assert_eq "$(colo_chinese_name HKG)" '中国 香港'
# lowercase input is normalised
assert_eq "$(colo_chinese_name sin)" '新加坡'
# unknown, empty and N/A all yield an empty string; callers do the fallback
assert_eq "$(colo_chinese_name ZZZ)" ''
assert_eq "$(colo_chinese_name '')" ''
assert_eq "$(colo_chinese_name 'N/A')" ''
# a missing table must not error out
CFST_COLOS_FILE=/nonexistent/colos.tsv
assert_eq "$(colo_chinese_name LAX)" ''

printf 'colo tests passed\n'
