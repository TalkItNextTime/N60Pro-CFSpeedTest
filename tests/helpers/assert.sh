#!/bin/sh
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected [$2], got [$1]"; }
assert_contains() { case "$1" in *"$2"*) : ;; *) fail "[$1] lacks [$2]" ;; esac; }
assert_file_exists() { [ -f "$1" ] || fail "missing file: $1"; }
assert_status() {
    expected="$1"; shift
    set +e; "$@"; actual="$?"; set -e
    assert_eq "$actual" "$expected"
}
