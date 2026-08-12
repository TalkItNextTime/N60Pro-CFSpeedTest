#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

NAMING_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/naming.sh"
assert_file_exists "$NAMING_SH"

TMP="${TMPDIR:-/tmp}/cfst-naming-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# Export mapping files BEFORE sourcing so defaults are overridden
export CFST_CITIES_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/cities.tsv"
export CFST_PROVIDERS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/providers.tsv"
assert_file_exists "$CFST_CITIES_FILE"
assert_file_exists "$CFST_PROVIDERS_FILE"

# shellcheck disable=SC1090,SC1091
. "$NAMING_SH"

# --- normalize_text ---
assert_eq "$(normalize_text "  深圳市  ")" "深圳"
assert_eq "$(normalize_text "Shenzhen")" "shenzhen"
assert_eq "$(normalize_text "  Beijing  ")" "beijing"
assert_eq "$(normalize_text "广州市")" "广州"
assert_eq "$(normalize_text "")" ""

# --- map_city ---
assert_eq "$(map_city "深圳市")" "sz"
assert_eq "$(map_city "Shenzhen")" "sz"
assert_eq "$(map_city "北京市")" "bj"
assert_eq "$(map_city "Beijing")" "bj"
assert_eq "$(map_city "上海市")" "sh"
assert_eq "$(map_city "Shanghai")" "sh"
assert_eq "$(map_city "广州市")" "gz"
assert_eq "$(map_city "Guangzhou")" "gz"
assert_eq "$(map_city "UnknownCity")" ""

# --- map_isp ---
assert_eq "$(map_isp "中国电信")" "ct"
assert_eq "$(map_isp "China Telecom")" "ct"
assert_eq "$(map_isp "CHINANET")" "ct"
assert_eq "$(map_isp "中国联通")" "cu"
assert_eq "$(map_isp "China Unicom")" "cu"
assert_eq "$(map_isp "中国移动")" "cm"
assert_eq "$(map_isp "China Mobile")" "cm"
assert_eq "$(map_isp "中国广电")" "cbn"
assert_eq "$(map_isp "China Broadnet")" "cbn"
assert_eq "$(map_isp "CERNET")" "cernet"
assert_eq "$(map_isp "教育网")" "cernet"
assert_eq "$(map_isp "UnknownISP")" ""

# --- choose_location_field priority: OVERRIDE > AUTO > CACHED > FALLBACK ---
assert_eq "$(choose_location_field "gz" "sz" "bj" "sh")" "gz"
assert_eq "$(choose_location_field "" "sz" "bj" "sh")" "sz"
assert_eq "$(choose_location_field "" "" "bj" "sh")" "bj"
assert_eq "$(choose_location_field "" "" "" "sh")" "sh"
assert_eq "$(choose_location_field "" "" "" "")" ""

# --- render_hostname ---
assert_eq "$(render_hostname "{city}{isp}.{zone}" "sz" "ct" "domain.com")" "szct.domain.com"
assert_eq "$(render_hostname "{isp}-{city}.{zone}" "sz" "ct" "domain.com")" "ct-sz.domain.com"
assert_eq "$(render_hostname "{zone}" "sz" "ct" "domain.com")" "domain.com"

# --- validate_hostname: valid ---
assert_status 0 validate_hostname "szct.domain.com"
assert_status 0 validate_hostname "a.b.c.domain.com"
assert_status 0 validate_hostname "sz-ct.domain.com"

# --- validate_hostname: invalid ---
assert_status 40 validate_hostname "SZCT.domain.com"
assert_status 40 validate_hostname "sz_ct.domain.com"
assert_status 40 validate_hostname ".domain.com"
assert_status 40 validate_hostname "domain.com."
long_label="$(awk 'BEGIN { for (i = 0; i < 64; i++) printf "a" }')"
assert_status 40 validate_hostname "${long_label}.domain.com"
long_fqdn="$(awk 'BEGIN { for (i = 0; i < 254; i++) printf "a" }')"
assert_status 40 validate_hostname "${long_fqdn}"

# --- render_hostname missing values → NAMING_UNRESOLVED ---
set +e
render_hostname "{city}{isp}.{zone}" "" "ct" "domain.com" >/dev/null
status="$?"
set -e
assert_eq "$status" "40"
assert_eq "$CFST_ERROR_CODE" "NAMING_UNRESOLVED"

set +e
render_hostname "{city}{isp}.{zone}" "sz" "" "domain.com" >/dev/null
status="$?"
set -e
assert_eq "$status" "40"
assert_eq "$CFST_ERROR_CODE" "NAMING_UNRESOLVED"

# --- unknown placeholder ---
set +e
render_hostname "{city}{isp}{unknown}.{zone}" "sz" "ct" "domain.com" >/dev/null
status="$?"
set -e
assert_eq "$status" "40"
assert_eq "$CFST_ERROR_CODE" "NAMING_UNRESOLVED"
