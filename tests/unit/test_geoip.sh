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

# --- UAPIS response parsing ---
cat > "$TMP/myip.json" <<'EOF'
{"ip":"119.123.53.235","region":"中国 广东 深圳","isp":"Chinanet","asn":"AS4134","llc":"电信"}
EOF
parsed="$(parse_uapi_network "$TMP/myip.json")"
assert_eq "$parsed" '{"ip":"119.123.53.235","region":"中国 广东 深圳","city":"深圳","isp":"Chinanet","asn":"AS4134","llc":"电信","source":"uapis.cn"}'
assert_status 1 parse_uapi_network "$CFST_ROOT/tests/fixtures/geoip/invalid.json"

# --- UAPIS-only myip request and city/ISP mapping ---
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
    *uapis.cn/api/v1/network/myip*)
        printf '%s\n' "$url" >> "${CFST_CURL_LOG:-/dev/null}"
        cat "$CFST_ROOT/tests/fixtures/geoip/uapis-myip-shenzhen.json" > "$outfile"
        exit 0
        ;;
    *uapis.cn/api/v1/network/ipinfo?ip=*)
        printf '%s\n' "$url" >> "${CFST_CURL_LOG:-/dev/null}"
        cat "$CFST_ROOT/tests/fixtures/geoip/uapis-myip-shenzhen.json" > "$outfile"
        exit 0
        ;;
    *ipapi.co*|*ipwho.is*)
        echo "unexpected legacy geo provider: $url" >&2
        exit 22
        ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export CFST_CURL_LOG="$TMP/curl.log"
: > "$CFST_CURL_LOG"
CFST_NETWORK_CACHE=''
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
assert_contains "$identity" '"ip":"119.123.53.235"'
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"uapis.cn"'
assert_contains "$(tr '\n' ' ' < "$CFST_CURL_LOG")" 'uapis.cn/api/v1/network/myip'

# --- fresh network cache avoids another myip request ---
CFST_NETWORK_CACHE='{"ip":"119.123.53.235","region":"中国 广东 深圳","city":"深圳","isp":"Chinanet","asn":"AS4134","llc":"电信","queried_at":1699999000}'
: > "$CFST_CURL_LOG"
identity="$(resolve_network_identity)"
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
[ ! -s "$CFST_CURL_LOG" ] || fail 'fresh network cache must not query myip'

# --- expired network cache: only UAPIS myip is attempted ---
CFST_NETWORK_CACHE='{"ip":"119.123.53.235","city":"sz","isp":"ct","queried_at":1600000000}'
identity="$(resolve_network_identity)"
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$(tr '\n' ' ' < "$CFST_CURL_LOG")" 'uapis.cn/api/v1/network/myip'

# --- manual overrides remain explicit configuration, not remote fallback ---
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
chmod +x "$TMP/bin/curl"
CFST_NETWORK_CACHE=''
CFST_CITY_OVERRIDE='sz'
CFST_ISP_OVERRIDE='ct'
identity="$(resolve_network_identity)"
assert_contains "$identity" '"city":"sz"'
assert_contains "$identity" '"isp":"ct"'
assert_contains "$identity" '"source":"override"'

printf '%s\n' 'geoip tests passed (UAPIS-only)'
