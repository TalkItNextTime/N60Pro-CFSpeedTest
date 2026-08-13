#!/bin/sh
# Content contracts for SDK build, installer, and release CI.
# Full SDK download/compile is for Linux CI only; host tests validate script content.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

BUILD_SDK="$CFST_ROOT/scripts/build-sdk.sh"
INSTALL_SH="$CFST_ROOT/scripts/install.sh"
WORKFLOW="$CFST_ROOT/.github/workflows/build-openwrt.yml"

SDK_URL_PIN='https://downloads.openwrt.org/releases/24.10.2/targets/mediatek/filogic/openwrt-sdk-24.10.2-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst'
SDK_SHA_PIN='df288284baa46d37cbc71812130b72617333f886f5c93c11f0548e28f0bb8309'

# --- scripts and workflow exist ---
assert_file_exists "$BUILD_SDK"
assert_file_exists "$INSTALL_SH"
assert_file_exists "$WORKFLOW"

build_content="$(cat "$BUILD_SDK")"
install_content="$(cat "$INSTALL_SH")"
wf_content="$(cat "$WORKFLOW")"

# --- build-sdk.sh: pinned SDK URL/SHA as defaults, overridable ---
assert_contains "$build_content" "$SDK_URL_PIN"
assert_contains "$build_content" "$SDK_SHA_PIN"
assert_contains "$build_content" 'SDK_URL='
assert_contains "$build_content" 'SDK_SHA256='
# Defaults must allow env override (SDK_URL="${SDK_URL:-...}" pattern)
assert_contains "$build_content" '${SDK_URL:-'
assert_contains "$build_content" '${SDK_SHA256:-'

# Download + SHA verification
assert_contains "$build_content" 'curl'
assert_contains "$build_content" 'sha256'
assert_contains "$build_content" 'expected'
assert_contains "$build_content" 'actual'

# Feed both packages into the SDK
assert_contains "$build_content" 'package/cloudflare-speedtest'
assert_contains "$build_content" 'package/luci-app-cloudflare-speedtest'
assert_contains "$build_content" './scripts/feeds update -a'
assert_contains "$build_content" './scripts/feeds install -a'

# Package selections (module build)
assert_contains "$build_content" 'CONFIG_PACKAGE_cloudflare-speedtest=m'
assert_contains "$build_content" 'CONFIG_PACKAGE_luci-app-cloudflare-speedtest=m'

# Compile both packages
assert_contains "$build_content" 'make defconfig'
assert_contains "$build_content" 'make package/cloudflare-speedtest/compile V=sc'
assert_contains "$build_content" 'make package/luci-app-cloudflare-speedtest/compile V=sc'

# Output artifacts
assert_contains "$build_content" 'SHA256SUMS'
assert_contains "$build_content" 'LICENSE'
assert_contains "$build_content" 'cloudflare-speedtest.version'
assert_contains "$build_content" '.ipk'

# Must fail if IPKs missing
assert_contains "$build_content" 'missing'
case "$build_content" in
	*'.ipk'*) : ;;
	*) fail 'build-sdk.sh must reference IPK outputs' ;;
esac

# No floating latest SDK refs
printf '%s\n' "$build_content" | grep -E '(^|[^[:alnum:]_])(/latest|version=latest|ref=latest)([^[:alnum:]_]|$)' >/dev/null 2>&1 \
	&& fail 'build-sdk.sh must not reference floating latest artifacts'

# --- install.sh: versioned install, arch gate, no force-depends ---
assert_contains "$install_content" '--version'
assert_contains "$install_content" '--base-url'
assert_contains "$install_content" 'TalkItNextTime/N60Pro-CFSpeedTest/releases/download'
assert_contains "$install_content" '/etc/openwrt_release'
assert_contains "$install_content" 'DISTRIB_ARCH'
assert_contains "$install_content" 'aarch64_cortex-a53'
assert_contains "$install_content" 'unsupported architecture'

# Overlay free space check
assert_contains "$install_content" '/overlay'

# Versioned checksums + both IPKs to /tmp
assert_contains "$install_content" 'SHA256SUMS'
assert_contains "$install_content" '/tmp'
assert_contains "$install_content" 'cloudflare-speedtest'
assert_contains "$install_content" 'luci-app-cloudflare-speedtest'
assert_contains "$install_content" 'sha256'

# opkg order: update, core, then LuCI
assert_contains "$install_content" 'opkg update'
# Two sequential opkg install calls; core ($CORE_IPK) before LuCI ($LUCI_IPK)
core_line="$(printf '%s\n' "$install_content" | grep -n 'opkg install "\$CORE_IPK"' | head -n 1 | cut -d: -f1)"
luci_line="$(printf '%s\n' "$install_content" | grep -n 'opkg install "\$LUCI_IPK"' | head -n 1 | cut -d: -f1)"
[ -n "$core_line" ] || fail 'install.sh must opkg install $CORE_IPK (core package)'
[ -n "$luci_line" ] || fail 'install.sh must opkg install $LUCI_IPK (LuCI package)'
[ "$core_line" -lt "$luci_line" ] || fail 'core package must be installed before LuCI'
assert_contains "$install_content" 'CORE_IPK'
assert_contains "$install_content" 'LUCI_IPK'

# Never --force-depends / --force-reinstall as opkg arguments (mentions in
# "do not use" comments are fine; reject actual opkg invocations with those flags)
printf '%s\n' "$install_content" | grep -E 'opkg[[:space:]]+[^
]*--force-depends' >/dev/null 2>&1 \
	&& fail 'install.sh must never use --force-depends'
printf '%s\n' "$install_content" | grep -E 'opkg[[:space:]]+[^
]*--force-reinstall' >/dev/null 2>&1 \
	&& fail 'install.sh must not force-reinstall (preserve UCI conffiles)'

# Service + LuCI refresh
assert_contains "$install_content" 'rpcd'
assert_contains "$install_content" 'uhttpd'
assert_contains "$install_content" 'enable'
assert_contains "$install_content" 'start'
assert_contains "$install_content" 'admin/services/cloudflare-speedtest'

# Preserve UCI on upgrade (conffiles / no wipe)
assert_contains "$install_content" 'conffiles'
assert_contains "$install_content" '/etc/config/cloudflare-speedtest'

# --- GitHub Actions workflow ---
assert_contains "$wf_content" 'workflow_dispatch'
assert_contains "$wf_content" 'tags:'
assert_contains "$wf_content" 'v*'
assert_contains "$wf_content" "$SDK_URL_PIN"
assert_contains "$wf_content" "$SDK_SHA_PIN"
assert_contains "$wf_content" 'make test'
assert_contains "$wf_content" 'build-sdk.sh'
assert_contains "$wf_content" 'upload-artifact'
assert_contains "$wf_content" 'softprops/action-gh-release' || assert_contains "$wf_content" 'upload-release' || assert_contains "$wf_content" 'gh release'

printf 'OK test_release_scripts\n'
