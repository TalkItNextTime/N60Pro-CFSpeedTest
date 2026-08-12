#!/bin/sh
# Reproducible ARM64 CloudflareSpeedTest (cfst) build from pinned upstream.
# Full download/cross-compile is intended for Linux/CI. On hosts without go,
# content/pin validation is covered by tests/unit/test_package.sh.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
PIN_FILE="$ROOT/upstream/cloudflare-speedtest.version"
# shellcheck disable=SC1090,SC1091
. "$PIN_FILE"

# Defense-in-depth: pin file must still carry the reviewed codeload checksum.
EXPECTED_PIN_SHA256='ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32'
if [ "$CFST_SOURCE_SHA256" != "$EXPECTED_PIN_SHA256" ]; then
    printf 'error: pin file SHA256 drifted from reviewed value %s\n' "$EXPECTED_PIN_SHA256" >&2
    exit 1
fi

OUTPUT_DIR="${1:-}"
if [ -z "$OUTPUT_DIR" ]; then
    printf 'usage: %s OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

mkdir -p "$OUTPUT_DIR"
WORKDIR="${TMPDIR:-/tmp}/cfst-build-$$"
mkdir -p "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

ARCHIVE="$WORKDIR/CloudflareSpeedTest-${CFST_COMMIT}.tar.gz"
SRC_DIR="$WORKDIR/src"

printf 'Downloading pinned CFST %s (%s)...\n' "$CFST_VERSION" "$CFST_COMMIT"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$ARCHIVE" "$CFST_SOURCE_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$ARCHIVE" "$CFST_SOURCE_URL"
else
    printf 'error: need curl or wget to download source\n' >&2
    exit 1
fi

# Verify SHA256 (sha256sum on Linux, shasum on macOS, certutil fallback noted)
actual=""
if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
elif command -v openssl >/dev/null 2>&1; then
    actual="$(openssl dgst -sha256 "$ARCHIVE" | awk '{print $NF}')"
else
    printf 'error: no sha256 tool available (sha256sum/shasum/openssl)\n' >&2
    exit 1
fi

if [ "$actual" != "$CFST_SOURCE_SHA256" ]; then
    printf 'error: SHA256 mismatch\n  expected: %s\n  actual:   %s\n' \
        "$CFST_SOURCE_SHA256" "$actual" >&2
    exit 1
fi
printf 'SHA256 OK (%s)\n' "$CFST_SOURCE_SHA256"

mkdir -p "$SRC_DIR"
tar -xzf "$ARCHIVE" -C "$SRC_DIR"
# codeload extracts to CloudflareSpeedTest-<commit>
extract_root="$(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$extract_root" ] || {
    printf 'error: empty source archive\n' >&2
    exit 1
}

if ! command -v go >/dev/null 2>&1; then
    printf 'error: go toolchain not found (full build requires Linux/CI with Go)\n' >&2
    exit 1
fi

(
    cd "$extract_root"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
        -trimpath -ldflags "-s -w -X main.version=$CFST_VERSION" \
        -o "$OUTPUT_DIR/cfst" .
)

# file check for AArch64 ELF (soft-fail if file(1) missing; hard-fail on wrong type)
if command -v file >/dev/null 2>&1; then
    info="$(file "$OUTPUT_DIR/cfst")"
    printf '%s\n' "$info"
    case "$info" in
        *ARM\ aarch64*|*AArch64*|*aarch64*)
            ;;
        *)
            printf 'error: expected AArch64 ELF, got: %s\n' "$info" >&2
            exit 1
            ;;
    esac
    case "$info" in
        *statically\ linked*|*static-pie*|*static\ *)
            ;;
        *)
            # Go linux/arm64 with CGO_ENABLED=0 is typically static; accept ELF aarch64
            printf 'warning: file(1) did not explicitly say statically linked\n' >&2
            ;;
    esac
else
    printf 'warning: file(1) not available; skipping ELF architecture check\n' >&2
fi

# Stage LICENSE, source archive, and ip.txt for release/GPL compliance
cp "$extract_root/LICENSE" "$OUTPUT_DIR/LICENSE" 2>/dev/null \
    || cp "$extract_root/license" "$OUTPUT_DIR/LICENSE" 2>/dev/null \
    || printf 'warning: upstream LICENSE not found in extract\n' >&2
cp "$ARCHIVE" "$OUTPUT_DIR/CloudflareSpeedTest-${CFST_COMMIT}.tar.gz"
cp "$ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/ip.txt" \
    "$OUTPUT_DIR/ip.txt"

printf 'Built %s (version pin %s)\n' "$OUTPUT_DIR/cfst" "$CFST_VERSION"
