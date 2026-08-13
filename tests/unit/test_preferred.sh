#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"
LIB="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest"
TMP="${TMPDIR:-/tmp}/cfst-preferred-test.$$"
mkdir -p "$TMP/bin" "$TMP/runtime"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CFST_ROOT
export CFST_TASK_DIR="$TMP/runtime"
export CFST_SLEEP_CMD=true
export CFST_PREFERRED_PROVIDER=auto
export CFST_PREFERRED_URL_CT='https://example.test/ct?ips=20'
export CFST_PREFERRED_URL_CU='https://example.test/cu?ips=20'
export CFST_PREFERRED_URL_CMCC='https://example.test/cmcc?ips=20'
export CFST_PREFERRED_TIMEOUT=1

cat > "$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
# Minimal JSON field reader for this unit test.
case "$*" in
  *'@.isp'*)
    printf '%s\n' "${CFST_TEST_ISP:-}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
url=''
out=''
prev=''
for arg in "$@"; do
    case "$prev" in
        --url) url="$arg" ;;
        --output|-o) out="$arg" ;;
    esac
    case "$arg" in
        http://*|https://*) url="$arg" ;;
    esac
    prev="$arg"
done
count_file="${CFST_TEST_CURL_COUNT_FILE:?}"
count=0
[ -f "$count_file" ] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ] && [ "${CFST_TEST_RETRY:-0}" = 1 ]; then
    exit 22
fi
case "$url" in
  *'/ct?ips=20')
    printf '162.159.38.245#CF 电信优选\n8.35.211.130#CF 电信优选\n' > "$out"
    ;;
  *)
    exit 22
    ;;
esac
EOF
chmod +x "$TMP/bin/jsonfilter" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export CFST_TEST_CURL_COUNT_FILE="$TMP/curl.count"

. "$LIB/geoip.sh"
. "$LIB/preferred.sh"

export CFST_TEST_ISP='中国电信'
assert_eq "$(preferred_provider_from_identity '{"isp":"中国电信"}')" ct
export CFST_TEST_ISP='中国联通'
assert_eq "$(preferred_provider_from_identity '{"isp":"中国联通"}')" cu
export CFST_TEST_ISP='中国移动'
assert_eq "$(preferred_provider_from_identity '{"isp":"中国移动"}')" cmcc

export CFST_TEST_ISP='中国电信'
export CFST_TEST_RETRY=1
preferred_prepare_ip_file '{"isp":"中国电信"}' "$TMP/ips"
assert_eq "$(wc -l < "$TMP/ips" | tr -d ' ')" 2
assert_eq "$(cat "$TMP/curl.count")" 2
assert_eq "$CFST_PREFERRED_SELECTED_PROVIDER" ct
true

export CFST_TEST_ISP=''
set +e
preferred_prepare_ip_file '{}' "$TMP/no-ips"
status="$?"
set -e
assert_eq "$status" 1
assert_eq "$CFST_ERROR_CODE" PREFERRED_PROVIDER_UNRESOLVED
assert_eq "$CFST_ERROR_MESSAGE" '无法根据本地运营商选择优选反代地址'
case "$CFST_ERROR_MESSAGE" in *'???'*) fail 'preferred error message contains replacement question marks' ;; esac

printf 'preferred tests passed\n'
