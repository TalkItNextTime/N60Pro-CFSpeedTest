#!/bin/sh
# shellcheck disable=SC1090,SC1091,SC2034,SC2089,SC2090
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

GEOIP_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh"
NAMING_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/naming.sh"
STATE_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh"
assert_file_exists "$GEOIP_SH"

TMP="${TMPDIR:-/tmp}/cfst-geoip-test.$$"
mkdir -p "$TMP/runtime" "$TMP/bin" "$TMP/etc"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CFST_CITIES_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/cities.tsv"
export CFST_PROVIDERS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/providers.tsv"
export CFST_RUNTIME_DIR="$TMP/runtime"
export CFST_STATUS_FILE="$CFST_RUNTIME_DIR/status.json"
export CFST_STATE_FILE="$TMP/etc/state.json"
export CFST_GEO_TIMEOUT=2
export CFST_GEO_CACHE_TTL_HOURS=72
export CFST_GEO_PROVIDERS='ipapi.co ipwho.is'
export CFST_AUTO_DETECT=1
export CFST_CITY_OVERRIDE=''
export CFST_ISP_OVERRIDE=''
export CFST_FALLBACK_CITY=''
export CFST_FALLBACK_ISP=''
export CFST_NOW=1700000000
export CFST_TASK_DIR="$TMP/runtime/task"
mkdir -p "$CFST_TASK_DIR"

# shellcheck disable=SC1090,SC1091
. "$NAMING_SH"
# shellcheck disable=SC1090,SC1091
. "$STATE_SH"
# shellcheck disable=SC1090,SC1091
. "$GEOIP_SH"

# --- validate_public_ipv4 ---
assert_status 0 validate_public_ipv4 '8.8.8.8'
assert_status 0 validate_public_ipv4 '1.1.1.1'
assert_status 0 validate_public_ipv4 '104.18.2.10'
assert_status 1 validate_public_ipv4 '10.0.0.1'
assert_status 1 validate_public_ipv4 '127.0.0.1'
assert_status 1 validate_public_ipv4 '192.168.1.1'
assert_status 1 validate_public_ipv4 '172.16.5.1'
assert_status 1 validate_public_ipv4 '169.254.1.1'
assert_status 1 validate_public_ipv4 '224.0.0.1'
assert_status 1 validate_public_ipv4 '0.1.2.3'
assert_status 1 validate_public_ipv4 '203.0.113.10'
assert_status 1 validate_public_ipv4 '198.51.100.1'
assert_status 1 validate_public_ipv4 '192.0.2.1'
assert_status 1 validate_public_ipv4 'not-an-ip'
assert_status 1 validate_public_ipv4 ''

# --- parse_ipapi ---
parsed="$(parse_ipapi "$CFST_ROOT/tests/fixtures/geoip/ipapi-shenzhen-telecom.json")"
assert_eq "$parsed" '{"ip":"203.0.113.10","city":"深圳","isp":"中国电信","source":"ipapi.co"}'

set +e
parse_ipapi "$CFST_ROOT/tests/fixtures/geoip/invalid.json" >/dev/null
status="$?"
set -e
assert_eq "$status" "1"

# --- parse_ipwhois ---
parsed="$(parse_ipwhois "$CFST_ROOT/tests/fixtures/geoip/ipwhois-shenzhen-telecom.json")"
assert_eq "$parsed" '{"ip":"203.0.113.10","city":"深圳","isp":"中国电信","source":"ipwho.is"}'

set +e
parse_ipwhois "$CFST_ROOT/tests/fixtures/geoip/invalid.json" >/dev/null
status="$?"
set -e
assert_eq "$status" "1"

# --- mock curl: provider one fails, provider two succeeds ---
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
# record args
printf '%s\n' "$*" >> "${CFST_CURL_LOG:-/dev/null}"
# honor noproxy and cleared proxies expectations by always succeeding for second host
url=''
outfile=''
prev=''
for arg in "$@"; do
    case "$prev" in
        --url) url="$arg" ;;
        --output|-o) outfile="$arg" ;;
    esac
    case "$arg" in
        http://*|https://*) url="$arg" ;;
    esac
    prev="$arg"
done
case "$url" in
    *ipapi.co*)
        exit 22
        ;;
    *ipwho.is*|*ipwhois*)
        if [ -n "$outfile" ]; then
            cat "$CFST_ROOT/tests/fixtures/geoip/ipwhois-public.json" > "$outfile"
        else
            cat "$CFST_ROOT/tests/fixtures/geoip/ipwhois-public.json"
        fi
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export CFST_CURL_LOG="$TMP/curl.log"
: > "$CFST_CURL_LOG"

CFST_GEO_CACHE=''
CFST_CITY_OVERRIDE=''
CFST_ISP_OVERRIDE=''
CFST_FALLBACK_CITY=''
CFST_FALLBACK_ISP=''
set +e
identity="$(resolve_network_identity)"
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$identity" '"ip":"1.1.1.1"'
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"ipwho.is"'
# curl must clear proxies / use noproxy
assert_contains "$(tr '\n' ' ' < "$CFST_CURL_LOG")" '--noproxy'

# --- all providers fail → GEO_ALL_PROVIDERS_FAILED without override/cache/fallback ---
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$TMP/bin/curl"
CFST_GEO_CACHE=''
set +e
resolve_network_identity >/dev/null
status="$?"
set -e
assert_eq "$status" "41"
assert_eq "$CFST_ERROR_CODE" "GEO_ALL_PROVIDERS_FAILED"

# --- manual field overrides allow success without providers ---
CFST_CITY_OVERRIDE='sz'
CFST_ISP_OVERRIDE='ct'
set +e
identity="$(resolve_network_identity)"
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"override"'

# --- unexpired cache fallback ---
CFST_CITY_OVERRIDE=''
CFST_ISP_OVERRIDE=''
# cached_at within TTL of CFST_NOW=1700000000 (72h = 259200s)
CFST_GEO_CACHE='{"ip":"8.8.4.4","city":"sz","isp":"ct","source":"cache","cached_at":1699990000}'
set +e
identity="$(resolve_network_identity)"
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"cache"'

# --- expired cache + fallback labels ---
CFST_GEO_CACHE='{"ip":"8.8.4.4","city":"sz","isp":"ct","source":"cache","cached_at":1600000000}'
CFST_FALLBACK_CITY='bj'
CFST_FALLBACK_ISP='cm'
set +e
identity="$(resolve_network_identity)"
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$identity" '"city":"bj"'
assert_contains "$identity" '"isp":"cm"'
assert_contains "$identity" '"source":"fallback"'

# --- provider one success with public IP fixture ---
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
url=''
outfile=''
prev=''
for arg in "$@"; do
    case "$prev" in
        --url) url="$arg" ;;
        --output|-o) outfile="$arg" ;;
    esac
    case "$arg" in
        http://*|https://*) url="$arg" ;;
    esac
    prev="$arg"
done
case "$url" in
    *ipapi.co*)
        if [ -n "$outfile" ]; then
            cat "$CFST_ROOT/tests/fixtures/geoip/ipapi-public.json" > "$outfile"
        else
            cat "$CFST_ROOT/tests/fixtures/geoip/ipapi-public.json"
        fi
        exit 0
        ;;
    *)
        exit 22
        ;;
esac
EOF
chmod +x "$TMP/bin/curl"
CFST_GEO_CACHE=''
CFST_CITY_OVERRIDE=''
CFST_ISP_OVERRIDE=''
CFST_FALLBACK_CITY=''
CFST_FALLBACK_ISP=''
set +e
identity="$(resolve_network_identity)"
status="$?"
set -e
assert_eq "$status" "0"
assert_contains "$identity" '"ip":"8.8.8.8"'
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"ipapi.co"'
