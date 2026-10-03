#!/bin/sh
# Direct channel: install/remove the nftables rules, pick the run user, and
# route the plugin's own curl calls around transparent proxies.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

DIRECT_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh"
LOG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh"
assert_file_exists "$DIRECT_SH"

TMP="${TMPDIR:-/tmp}/cfst-direct-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
export CFST_LOG_FILE="$TMP/plugin.log"
export PATH="$CFST_ROOT/tests/helpers/mock-bin:$PATH"
export CFST_MOCK_NFT_LOG="$TMP/nft.args"
printf 'root:x:0:\nnogroup:x:65534:\n' > "$TMP/group"
export CFST_GROUP_FILE="$TMP/group"
# No real DNS lookups from the host test suite.
export CFST_DIRECT_DNS=''
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh
. "$LOG_SH"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh
. "$DIRECT_SH"

# --- disabled by config: no nft calls, cfst runs as root ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=0
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
direct_enable
assert_eq "$(wc -c < "$CFST_MOCK_NFT_LOG" | tr -d ' ')" '0'
assert_eq "$(direct_run_user)" ''

# --- enabled with a resolvable user: set, chains and rules are created ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=1
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
direct_enable
args="$(tr -d '\r' < "$CFST_MOCK_NFT_LOG")"
assert_contains "$args" 'add table inet cfst_direct'
assert_contains "$args" 'add set inet cfst_direct dst4'
assert_contains "$args" 'add chain inet cfst_direct mark_out'
assert_contains "$args" 'meta skuid'
assert_contains "$args" 'meta mark set 0x000000ff'
assert_contains "$args" 'ip daddr @dst4 meta mark set 0x000000ff'
# identity DNAT ahead of every proxy redirect chain
assert_contains "$args" 'add chain inet cfst_direct nat_out'
assert_contains "$args" 'priority -190'
assert_contains "$args" 'meta skuid 65534 meta nfproto ipv4 meta l4proto tcp dnat ip to ip daddr'
assert_contains "$args" 'ip daddr @dst4 meta l4proto tcp dnat ip to ip daddr'
# OpenClash exempts gid 65534, so cfst runs with group nogroup when it exists
assert_eq "$(direct_run_user)" 'nobody:nogroup'

# --- idempotent: a second enable must not add a second rule ---
: > "$CFST_MOCK_NFT_LOG"
direct_enable
assert_eq "$(grep -c 'add rule' "$CFST_MOCK_NFT_LOG" || true)" '0'

# --- direct_curl: IP-literal targets join the destination set ---
cat > "$TMP/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CFST_TEST_CURL_LOG"
EOF
chmod +x "$TMP/curl"
export CFST_TEST_CURL_LOG="$TMP/curl.args"
PATH="$TMP:$PATH"
: > "$CFST_MOCK_NFT_LOG"
: > "$CFST_TEST_CURL_LOG"
direct_curl --silent --url 'https://1.2.3.4/x'
assert_contains "$(cat "$CFST_MOCK_NFT_LOG")" 'add element inet cfst_direct dst4 { 1.2.3.4 }'
assert_contains "$(cat "$CFST_TEST_CURL_LOG")" '--silent --url https://1.2.3.4/x'

# --- direct_curl: loopback targets bypass the channel entirely ---
: > "$CFST_MOCK_NFT_LOG"
direct_curl --url 'http://127.0.0.1:8080/client/v4/zones'
assert_eq "$(wc -c < "$CFST_MOCK_NFT_LOG" | tr -d ' ')" '0'

# --- direct_curl: unresolvable host degrades to plain curl with a warning ---
: > "$CFST_TEST_CURL_LOG"
direct_curl --url 'https://api.example.test/v4'
assert_eq "$(tail -n 1 "$CFST_TEST_CURL_LOG")" '--url https://api.example.test/v4'
assert_contains "$(cat "$CFST_LOG_FILE")" 'could not resolve api.example.test'

# --- direct_curl: resolved host is pinned with --resolve on the right port ---
_direct_resolve() { printf '104.19.193.29'; }
: > "$CFST_MOCK_NFT_LOG"
: > "$CFST_TEST_CURL_LOG"
direct_curl -o /dev/null --url 'https://api.cloudflare.com/client/v4/zones?name=a.b'
assert_contains "$(cat "$CFST_TEST_CURL_LOG")" '--resolve api.cloudflare.com:443:104.19.193.29 -o /dev/null'
assert_contains "$(cat "$CFST_MOCK_NFT_LOG")" 'dst4 { 104.19.193.29 }'
: > "$CFST_TEST_CURL_LOG"
direct_curl --url 'http://preferred.test:8080/ct'
assert_contains "$(cat "$CFST_TEST_CURL_LOG")" '--resolve preferred.test:8080:104.19.193.29'

# --- _direct_resolve: fake-ip answers are never trusted as the real address ---
# shellcheck disable=SC1090
. "$DIRECT_SH"   # restore the real _direct_resolve
cat > "$TMP/nslookup" <<'EOF'
#!/bin/sh
printf 'Server:\t\t%s\nAddress:\t%s:53\n\nName:\t%s\n' "$2" "$2" "$1"
case "$2" in
    9.9.9.9) printf 'Address: 198.18.0.5\n' ;;
    *) printf 'Address: 104.16.1.2\n' ;;
esac
EOF
chmod +x "$TMP/nslookup"
CFST_DIRECT_DNS='9.9.9.9'
assert_eq "$(_direct_resolve api.cloudflare.com || true)" ''
CFST_DIRECT_DNS='9.9.9.9 223.5.5.5'
assert_eq "$(_direct_resolve api.cloudflare.com)" '104.16.1.2'
CFST_DIRECT_DNS=''
CFST_DIRECT_STATE=active

# --- disable removes the whole table; curl then goes out untouched ---
: > "$CFST_MOCK_NFT_LOG"
direct_disable
assert_contains "$(cat "$CFST_MOCK_NFT_LOG")" 'delete table inet cfst_direct'
: > "$CFST_TEST_CURL_LOG"
direct_curl --url 'https://api.cloudflare.com/x'
assert_eq "$(cat "$CFST_TEST_CURL_LOG")" '--url https://api.cloudflare.com/x'

# --- no nogroup group: run as the user alone ---
printf 'root:x:0:\n' > "$TMP/group"
CFST_DIRECT_STATE=active
assert_eq "$(direct_run_user)" 'nobody'
CFST_DIRECT_STATE=''

# --- unknown user: degrade to root, warn, no rule ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=cfst-does-not-exist
CFST_DIRECT_UID=''
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode user missing'

# --- nft missing: degrade quietly, no crash ---
: > "$CFST_LOG_FILE"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
CFST_NFT_BIN=/nonexistent/nft
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode nft unavailable'

printf 'direct tests passed\n'
