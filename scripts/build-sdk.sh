#!/bin/sh
# Reproducible OpenWrt SDK package build for mediatek/filogic (N60 Pro).
# Full SDK download/compile is intended for Linux/CI. Host tests validate content.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

# Pinned OpenWrt 24.10.2 mediatek/filogic SDK (override via env when intentional).
SDK_URL="${SDK_URL:-https://downloads.openwrt.org/releases/24.10.2/targets/mediatek/filogic/openwrt-sdk-24.10.2-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst}"
SDK_SHA256="${SDK_SHA256:-df288284baa46d37cbc71812130b72617333f886f5c93c11f0548e28f0bb8309}"

OUTPUT_DIR="${1:-}"
if [ -z "$OUTPUT_DIR" ]; then
	printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
	exit 2
fi

# Resolve relative output against caller CWD before any cd.
case "$OUTPUT_DIR" in
	/*) ;;
	*) OUTPUT_DIR="$(pwd)/$OUTPUT_DIR" ;;
esac
mkdir -p "$OUTPUT_DIR"

WORKDIR="${TMPDIR:-/tmp}/cfst-sdk-build-$$"
mkdir -p "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

sdk_archive="$WORKDIR/openwrt-sdk.tar.zst"

printf 'Downloading OpenWrt SDK...\n  %s\n' "$SDK_URL"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL -o "$sdk_archive" "$SDK_URL"
else
	printf 'error: curl is required to download the SDK\n' >&2
	exit 1
fi

actual=""
if command -v sha256sum >/dev/null 2>&1; then
	actual="$(sha256sum "$sdk_archive" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
	actual="$(shasum -a 256 "$sdk_archive" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
	actual="$(openssl dgst -sha256 "$sdk_archive" | awk '{print $NF}')"
else
	printf 'error: no sha256 tool available (sha256sum/shasum/openssl)\n' >&2
	exit 1
fi

if [ "$actual" != "$SDK_SHA256" ]; then
	printf 'error: SDK SHA256 mismatch\n  expected: %s\n  actual:   %s\n' \
		"$SDK_SHA256" "$actual" >&2
	exit 1
fi
printf 'SDK SHA256 OK (%s)\n' "$SDK_SHA256"

extract_dir="$WORKDIR/sdk"
mkdir -p "$extract_dir"
if command -v tar >/dev/null 2>&1; then
	# OpenWrt ships .tar.zst; require zstd-capable tar or zstd binary.
	if tar --help 2>&1 | grep -q zstd; then
		tar -xf "$sdk_archive" -C "$extract_dir"
	elif command -v zstd >/dev/null 2>&1; then
		zstd -d -c "$sdk_archive" | tar -xf - -C "$extract_dir"
	else
		printf 'error: need tar with zstd support or zstd binary to extract SDK\n' >&2
		exit 1
	fi
else
	printf 'error: tar is required to extract the SDK\n' >&2
	exit 1
fi

SDK_ROOT="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$SDK_ROOT" ] || {
	printf 'error: empty SDK archive\n' >&2
	exit 1
}

# Feed both repository packages into the SDK package tree.
pkg_dst="$SDK_ROOT/package"
mkdir -p "$pkg_dst"
rm -rf "$pkg_dst/cloudflare-speedtest" "$pkg_dst/luci-app-cloudflare-speedtest"
cp -a "$ROOT/package/cloudflare-speedtest" "$pkg_dst/cloudflare-speedtest"
cp -a "$ROOT/package/luci-app-cloudflare-speedtest" "$pkg_dst/luci-app-cloudflare-speedtest"

(
	cd "$SDK_ROOT"
	./scripts/feeds update -a
	./scripts/feeds install -a

	# Select both packages as modules, then defconfig + compile.
	{
		printf 'CONFIG_PACKAGE_cloudflare-speedtest=m\n'
		printf 'CONFIG_PACKAGE_luci-app-cloudflare-speedtest=m\n'
	} >>.config

	make defconfig
	make package/cloudflare-speedtest/compile V=sc
	make package/luci-app-cloudflare-speedtest/compile V=sc
)

# Collect IPKs (bin/packages/<arch>/.../*.ipk or bin/targets/.../packages)
ipk_core="$(find "$SDK_ROOT" -type f -name 'cloudflare-speedtest_*.ipk' ! -name '*luci*' | head -n 1)"
ipk_luci="$(find "$SDK_ROOT" -type f -name 'luci-app-cloudflare-speedtest_*.ipk' | head -n 1)"

if [ -z "$ipk_core" ] || [ -z "$ipk_luci" ]; then
	printf 'error: missing IPK artifacts after SDK build\n' >&2
	printf '  core: %s\n' "${ipk_core:-<missing>}" >&2
	printf '  luci: %s\n' "${ipk_luci:-<missing>}" >&2
	exit 1
fi

cp -f "$ipk_core" "$OUTPUT_DIR/"
cp -f "$ipk_luci" "$OUTPUT_DIR/"

# Package manifests if present next to IPKs
for ipk in "$ipk_core" "$ipk_luci"; do
	base="$(basename "$ipk" .ipk)"
	dir="$(dirname "$ipk")"
	for ext in manifest pkginfo; do
		if [ -f "$dir/$base.$ext" ]; then
			cp -f "$dir/$base.$ext" "$OUTPUT_DIR/"
		fi
	done
done
# Also copy Packages index snippets when available
find "$SDK_ROOT/bin" -type f \( -name 'Packages' -o -name 'Packages.gz' \) 2>/dev/null \
	| head -n 4 \
	| while IFS= read -r idx; do
		[ -n "$idx" ] || continue
		cp -f "$idx" "$OUTPUT_DIR/$(basename "$(dirname "$idx")")-$(basename "$idx")" 2>/dev/null || true
	done

# Source pin, GPL license, and upstream source archive for release compliance
cp -f "$ROOT/upstream/cloudflare-speedtest.version" "$OUTPUT_DIR/cloudflare-speedtest.version"
if [ -f "$ROOT/LICENSE" ]; then
	cp -f "$ROOT/LICENSE" "$OUTPUT_DIR/LICENSE"
else
	printf 'error: missing project LICENSE (GPL)\n' >&2
	exit 1
fi

# shellcheck disable=SC1090,SC1091
. "$ROOT/upstream/cloudflare-speedtest.version"
src_archive="$OUTPUT_DIR/CloudflareSpeedTest-${CFST_COMMIT}.tar.gz"
if command -v curl >/dev/null 2>&1; then
	curl -fsSL -o "$src_archive" "$CFST_SOURCE_URL"
else
	printf 'error: curl required to fetch upstream source archive\n' >&2
	exit 1
fi
src_actual=""
if command -v sha256sum >/dev/null 2>&1; then
	src_actual="$(sha256sum "$src_archive" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
	src_actual="$(shasum -a 256 "$src_archive" | awk '{print $1}')"
else
	src_actual="$(openssl dgst -sha256 "$src_archive" | awk '{print $NF}')"
fi
if [ "$src_actual" != "$CFST_SOURCE_SHA256" ]; then
	printf 'error: upstream source SHA256 mismatch\n  expected: %s\n  actual:   %s\n' \
		"$CFST_SOURCE_SHA256" "$src_actual" >&2
	exit 1
fi

# Generate SHA256SUMS for all staged release files (exclude the sums file itself)
(
	cd "$OUTPUT_DIR"
	if command -v sha256sum >/dev/null 2>&1; then
		find . -type f ! -name 'SHA256SUMS' -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
	else
		: >SHA256SUMS
		for f in $(find . -type f ! -name 'SHA256SUMS' | sort); do
			sum="$(shasum -a 256 "$f" | awk '{print $1}')"
			printf '%s  %s\n' "$sum" "${f#./}" >>SHA256SUMS
		done
	fi
)

printf 'SDK build complete. Artifacts in %s\n' "$OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
