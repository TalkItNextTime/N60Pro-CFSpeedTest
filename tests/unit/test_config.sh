#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"
assert_file_exists "$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh"
