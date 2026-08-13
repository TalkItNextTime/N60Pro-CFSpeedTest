#!/bin/sh
# Versioned IPK installer for N60 Pro / aarch64_cortex-a53 OpenWrt.
# Preserves existing UCI conffiles on upgrade. Never uses --force-depends.
set -eu

VERSION=""
BASE_URL=""
# Minimum free overlay space in KiB (both IPKs + opkg overhead).
MIN_OVERLAY_KB=4096

usage() {
	printf 'usage: %s --version vX.Y.Z [--base-url URL]\n' "$0" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--version)
			[ $# -ge 2 ] || usage
			VERSION="$2"
			shift 2
			;;
		--base-url)
			[ $# -ge 2 ] || usage
			BASE_URL="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			printf 'error: unknown argument: %s\n' "$1" >&2
			usage
			;;
	esac
done

[ -n "$VERSION" ] || usage

# Normalize version tag (accept v1.0.0 or 1.0.0)
case "$VERSION" in
	v*) TAG="$VERSION" ;;
	*) TAG="v$VERSION" ;;
esac

if [ -z "$BASE_URL" ]; then
	BASE_URL="https://github.com/TalkItNextTime/N60Pro-CFSpeedTest/releases/download/${TAG}"
fi

# Architecture gate: only N60 Pro target arch is supported.
if [ ! -f /etc/openwrt_release ]; then
	printf 'error: /etc/openwrt_release not found (not an OpenWrt system?)\n' >&2
	exit 1
fi
# shellcheck disable=SC1091
. /etc/openwrt_release

if [ "${DISTRIB_ARCH:-}" != "aarch64_cortex-a53" ]; then
	printf 'error: unsupported architecture (expected aarch64_cortex-a53, got %s)\n' \
		"${DISTRIB_ARCH:-unknown}" >&2
	exit 1
fi

# Free overlay space check
overlay_avail=""
if command -v df >/dev/null 2>&1; then
	# Prefer /overlay; fall back to rootfs when overlay is not mounted separately.
	if df -k /overlay >/dev/null 2>&1; then
		overlay_avail="$(df -k /overlay | awk 'NR==2 {print $4}')"
	elif df -k / >/dev/null 2>&1; then
		overlay_avail="$(df -k / | awk 'NR==2 {print $4}')"
	fi
fi
if [ -n "$overlay_avail" ]; then
	case "$overlay_avail" in
		''|*[!0-9]*)
			printf 'warning: could not parse free /overlay space\n' >&2
			;;
		*)
			if [ "$overlay_avail" -lt "$MIN_OVERLAY_KB" ]; then
				printf 'error: insufficient free /overlay space (%s KiB available, need %s KiB)\n' \
					"$overlay_avail" "$MIN_OVERLAY_KB" >&2
				exit 1
			fi
			;;
	esac
else
	printf 'warning: could not determine free /overlay space\n' >&2
fi

TMPDIR_INSTALL="/tmp/cfst-install-$$"
mkdir -p "$TMPDIR_INSTALL"
cleanup() { rm -rf "$TMPDIR_INSTALL"; }
trap cleanup EXIT INT TERM

download() {
	url="$1"
	out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		printf 'error: need curl or wget to download release artifacts\n' >&2
		exit 1
	fi
}

sha256_file() {
	f="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$f" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$f" | awk '{print $NF}'
	else
		printf 'error: no sha256 tool available\n' >&2
		exit 1
	fi
}

# Download versioned checksums and both IPKs to /tmp
SUMS_URL="${BASE_URL}/SHA256SUMS"
SUMS_FILE="$TMPDIR_INSTALL/SHA256SUMS"
printf 'Downloading versioned checksums: %s\n' "$SUMS_URL"
download "$SUMS_URL" "$SUMS_FILE"

# Resolve IPK filenames from SHA256SUMS (must list both packages)
CORE_IPK_NAME="$(awk '/cloudflare-speedtest_.*\.ipk$/ && $2 !~ /luci-app/ {print $2; exit}' "$SUMS_FILE")"
LUCI_IPK_NAME="$(awk '/luci-app-cloudflare-speedtest_.*\.ipk$/ {print $2; exit}' "$SUMS_FILE")"
# Strip optional leading ./ from checksum paths
CORE_IPK_NAME="${CORE_IPK_NAME#./}"
LUCI_IPK_NAME="${LUCI_IPK_NAME#./}"

if [ -z "$CORE_IPK_NAME" ] || [ -z "$LUCI_IPK_NAME" ]; then
	printf 'error: SHA256SUMS missing cloudflare-speedtest or luci-app-cloudflare-speedtest IPK entries\n' >&2
	exit 1
fi

CORE_IPK="$TMPDIR_INSTALL/$CORE_IPK_NAME"
LUCI_IPK="$TMPDIR_INSTALL/$LUCI_IPK_NAME"

printf 'Downloading %s\n' "$CORE_IPK_NAME"
download "${BASE_URL}/${CORE_IPK_NAME}" "$CORE_IPK"
printf 'Downloading %s\n' "$LUCI_IPK_NAME"
download "${BASE_URL}/${LUCI_IPK_NAME}" "$LUCI_IPK"

# Verify both IPKs against versioned SHA256SUMS
verify_one() {
	name="$1"
	path="$2"
	expected="$(awk -v n="$name" '$2 == n || $2 == "./"n {print $1; exit}' "$SUMS_FILE")"
	[ -n "$expected" ] || {
		printf 'error: no checksum entry for %s\n' "$name" >&2
		exit 1
	}
	actual="$(sha256_file "$path")"
	if [ "$actual" != "$expected" ]; then
		printf 'error: SHA256 mismatch for %s\n  expected: %s\n  actual:   %s\n' \
			"$name" "$expected" "$actual" >&2
		exit 1
	fi
	printf 'SHA256 OK: %s\n' "$name"
}
verify_one "$CORE_IPK_NAME" "$CORE_IPK"
verify_one "$LUCI_IPK_NAME" "$LUCI_IPK"

# Note: opkg preserves conffiles (/etc/config/cloudflare-speedtest) on upgrade
# by default. Do not use --force-reinstall or --force-depends.
printf 'Updating package lists (opkg update)...\n'
opkg update || printf 'warning: opkg update failed; continuing with local IPKs\n' >&2

printf 'Installing core package (preserves existing UCI conffiles on upgrade)...\n'
opkg install "$CORE_IPK"

printf 'Installing LuCI package...\n'
opkg install "$LUCI_IPK"

# Restart rpcd/uhttpd only if they are running (refresh menus/ACLs)
if [ -x /etc/init.d/rpcd ]; then
	if /etc/init.d/rpcd enabled 2>/dev/null || pgrep -x rpcd >/dev/null 2>&1; then
		/etc/init.d/rpcd restart 2>/dev/null || true
	fi
fi
if [ -x /etc/init.d/uhttpd ]; then
	if /etc/init.d/uhttpd enabled 2>/dev/null || pgrep -x uhttpd >/dev/null 2>&1; then
		/etc/init.d/uhttpd restart 2>/dev/null || true
	fi
fi

# Enable and start the service
if [ -x /etc/init.d/cloudflare-speedtest ]; then
	/etc/init.d/cloudflare-speedtest enable 2>/dev/null || true
	/etc/init.d/cloudflare-speedtest start 2>/dev/null || true
fi

printf '\nInstallation complete.\n'
printf 'LuCI menu path: admin/services/cloudflare-speedtest\n'
printf '  (Services → Cloudflare 优选 IP)\n'
printf 'Configure Token and Zone before running a test.\n'
printf 'Existing UCI config at /etc/config/cloudflare-speedtest is preserved on upgrade.\n'
