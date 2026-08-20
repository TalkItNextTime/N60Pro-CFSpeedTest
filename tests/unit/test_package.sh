#!/bin/sh
# Package metadata, pin file, and CFST build script contracts.
# Full ARM64 cross-compile via scripts/build-cfst.sh is for Linux/CI;
# on Windows hosts without go, this suite validates content only.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

PIN="$CFST_ROOT/upstream/cloudflare-speedtest.version"
MAKEFILE="$CFST_ROOT/package/cloudflare-speedtest/Makefile"
BUILD_SH="$CFST_ROOT/scripts/build-cfst.sh"
IP_TXT="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/ip.txt"
FILES_ROOT="$CFST_ROOT/package/cloudflare-speedtest/files"

# --- pin file exact values ---
assert_file_exists "$PIN"
# shellcheck disable=SC1090,SC1091
. "$PIN"
assert_eq "$CFST_VERSION" "2.3.5"
assert_eq "$CFST_COMMIT" "65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4"
assert_eq "$CFST_SOURCE_URL" "https://codeload.github.com/XIU2/CloudflareSpeedTest/tar.gz/65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4"
assert_eq "$CFST_SOURCE_SHA256" "ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32"

# --- Makefile exists and depends on required packages ---
assert_file_exists "$MAKEFILE"
mk_content="$(cat "$MAKEFILE")"
assert_contains "$mk_content" '+curl'
assert_contains "$mk_content" '+ca-bundle'
assert_contains "$mk_content" '+jsonfilter'
assert_contains "$mk_content" '+uci'
assert_contains "$mk_content" '+ubus'
assert_contains "$mk_content" '+rpcd'
assert_contains "$mk_content" '+procd'

# No separate cron package dependency
case "$mk_content" in
    *'+cron'*|*' cron '*|*'DEPENDS:='*'cron'*)
        # allow only if not a real dependency line; fail on +cron
        ;;
esac
printf '%s\n' "$mk_content" | grep -E 'DEPENDS.*\+cron([[:space:]]|$)' >/dev/null 2>&1 \
    && fail 'Makefile must not depend on +cron (BusyBox crond)'

# No PKGARCH hard-code
printf '%s\n' "$mk_content" | grep -E '^[[:space:]]*PKGARCH[[:space:]]*:?=' >/dev/null 2>&1 \
    && fail 'Makefile must not set PKGARCH manually'

# No floating unpinned refs in Makefile (URL/version tokens, not prose)
printf '%s\n' "$mk_content" | grep -E '(^|[^[:alnum:]_])(/latest|version=latest|ref=latest|/main|/master|@master|@main|COMMIT=HEAD|SOURCE.*=HEAD)([^[:alnum:]_]|$)' >/dev/null 2>&1 \
    && fail 'Makefile must not use floating latest/main/master/HEAD refs'
assert_contains "$mk_content" 'ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32'
assert_contains "$mk_content" '65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4'
assert_contains "$mk_content" 'golang-package.mk'
assert_contains "$mk_content" '/usr/bin/cfst'
assert_contains "$mk_content" 'conffiles'
assert_contains "$mk_content" '/etc/config/cloudflare-speedtest'
assert_contains "$mk_content" '/etc/cloudflare-speedtest/state.json'

# --- build-cfst.sh pin + arm64 flags ---
assert_file_exists "$BUILD_SH"
build_content="$(cat "$BUILD_SH")"
assert_contains "$build_content" 'ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32'
assert_contains "$build_content" 'GOARCH=arm64'
assert_contains "$build_content" 'CGO_ENABLED=0'
assert_contains "$build_content" 'GOOS=linux'
assert_contains "$build_content" '-trimpath'
assert_contains "$build_content" 'main.version='
assert_contains "$build_content" 'cloudflare-speedtest.version'
printf '%s\n' "$build_content" | grep -E '(^|[^[:alnum:]_])(/latest|version=latest|ref=latest)([^[:alnum:]_]|$)' >/dev/null 2>&1 \
    && fail 'build-cfst.sh must not reference floating latest artifacts'

# --- runtime files the package installs ---
for rel in \
    etc/config/cloudflare-speedtest \
    etc/init.d/cloudflare-speedtest \
    etc/hotplug.d/iface/95-cloudflare-speedtest \
    etc/uci-defaults/90-cloudflare-speedtest \
    usr/bin/cloudflare-speedtest \
    usr/libexec/cloudflare-speedtest/candidates.sh \
    usr/libexec/cloudflare-speedtest/config.sh \
    usr/libexec/cloudflare-speedtest/dns.sh \
    usr/libexec/cloudflare-speedtest/geoip.sh \
    usr/libexec/cloudflare-speedtest/lock.sh \
    usr/libexec/cloudflare-speedtest/log.sh \
    usr/libexec/cloudflare-speedtest/naming.sh \
    usr/libexec/cloudflare-speedtest/preferred.sh \
    usr/libexec/cloudflare-speedtest/result.sh \
    usr/libexec/cloudflare-speedtest/runner.sh \
    usr/libexec/cloudflare-speedtest/schedule.sh \
    usr/libexec/cloudflare-speedtest/state.sh \
    usr/share/cloudflare-speedtest/cities.tsv \
    usr/share/cloudflare-speedtest/providers.tsv \
    usr/share/cloudflare-speedtest/ip.txt
do
    assert_file_exists "$FILES_ROOT/$rel"
done

# Shell scripts must use LF only. BusyBox ash treats CRLF as literal tokens
# (for example, "\r: not found"), which can make an accepted RPC task exit
# before it reaches the testing phase.
for rel in \
    usr/bin/cloudflare-speedtest \
    usr/libexec/cloudflare-speedtest/candidates.sh \
    usr/libexec/cloudflare-speedtest/config.sh \
    usr/libexec/cloudflare-speedtest/dns.sh \
    usr/libexec/cloudflare-speedtest/geoip.sh \
    usr/libexec/cloudflare-speedtest/lock.sh \
    usr/libexec/cloudflare-speedtest/log.sh \
    usr/libexec/cloudflare-speedtest/naming.sh \
    usr/libexec/cloudflare-speedtest/preferred.sh \
    usr/libexec/cloudflare-speedtest/result.sh \
    usr/libexec/cloudflare-speedtest/runner.sh \
    usr/libexec/cloudflare-speedtest/schedule.sh \
    usr/libexec/cloudflare-speedtest/state.sh
 do
    if grep -q "$(printf '\r')" "$FILES_ROOT/$rel"; then
        fail "$rel must use LF line endings"
    fi
done

# --- ip.txt: bare IPv4 CIDR lines only (CFST does not accept comments) ---
assert_file_exists "$IP_TXT"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '') fail 'ip.txt must not contain blank lines' ;;
        \#*) fail "ip.txt must not contain comments: $line" ;;
    esac
    bare="$line"
    case "$bare" in
        *:* )
            fail "ip.txt must not contain IPv6: $bare"
            ;;
        [0-9]*.[0-9]*.[0-9]*.[0-9]*/[0-9]* )
            ;;
        *)
            fail "ip.txt line must be IPv4 CIDR: $line"
            ;;
    esac
done < "$IP_TXT"

# At least one real CIDR
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$IP_TXT" >/dev/null \
    || fail 'ip.txt must contain at least one IPv4 CIDR'

# --- luci.mk copies root/ verbatim, so the rpcd plugin needs its exec bit in git ---
# rpcd silently refuses to load a non-executable plugin, which takes the whole
# dashboard down. Check the index mode: working-tree bits are unreliable on
# hosts with core.fileMode=false.
RPCD_PLUGIN='package/luci-app-cloudflare-speedtest/root/usr/libexec/rpcd/cloudflare-speedtest'
if command -v git >/dev/null 2>&1 && [ -d "$CFST_ROOT/.git" ]; then
    mode="$(cd "$CFST_ROOT" && git ls-files -s "$RPCD_PLUGIN" | awk '{print $1}')"
    assert_eq "$mode" "100755"
    for data_file in \
        'package/luci-app-cloudflare-speedtest/root/usr/share/rpcd/acl.d/luci-app-cloudflare-speedtest.json' \
        'package/luci-app-cloudflare-speedtest/root/usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json'
    do
        mode="$(cd "$CFST_ROOT" && git ls-files -s "$data_file" | awk '{print $1}')"
        assert_eq "$mode" "100644"
    done
fi

printf 'OK test_package\n'
