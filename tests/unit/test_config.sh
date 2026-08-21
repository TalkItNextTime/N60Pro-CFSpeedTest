#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

CONFIG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh"
DEFAULT_CONFIG="$CFST_ROOT/package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest"
assert_file_exists "$CONFIG_SH"
assert_file_exists "$DEFAULT_CONFIG"
# shellcheck disable=SC1090,SC1091
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh
. "$CONFIG_SH"

TMP="${TMPDIR:-/tmp}/cfst-config-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
export CFST_TEST_UCI_FILE="$TMP/uci"

: > "$CFST_TEST_UCI_FILE"
load_config
assert_eq "$CFST_ENABLED" "1"
assert_eq "$CFST_INTERVAL_HOURS" "6"
assert_eq "$CFST_THREADS" "50"
assert_eq "$CFST_DOWNLOAD_COUNT" "10"
assert_eq "$CFST_TEST_URL" "https://speed.cloudflare.com/__down?bytes=99000000"
assert_eq "$CFST_MIN_SPEED_MBPS" "0.01"
assert_eq "$CFST_NAMING_TEMPLATE" "cf"
assert_eq "$CFST_IP_SOURCE" "cidr"
assert_eq "$CFST_CANDIDATE_COUNT" "0"
assert_eq "$CFST_TEST_ALL" "0"
assert_eq "$CFST_DIRECT_MODE" "1"
assert_eq "$CFST_PUBLISH_SWITCH_MARGIN" "20"
assert_eq "$CFST_SPEED_WEIGHT" "60"

set +e
validate_publish_config
status="$?"
set -e
assert_eq "$status" "20"
assert_eq "$CFST_ERROR_CODE" "CONFIG_TOKEN_MISSING"

cat > "$CFST_TEST_UCI_FILE" <<'EOF'
cloudflare-speedtest.cloudflare.api_token=test-token
cloudflare-speedtest.cloudflare.zone=bad_zone
EOF
load_config
set +e
validate_publish_config
status="$?"
set -e
assert_eq "$status" "21"
assert_eq "$CFST_ERROR_CODE" "CONFIG_ZONE_INVALID"

cat > "$CFST_TEST_UCI_FILE" <<'EOF'
cloudflare-speedtest.cloudflare.api_token=test-token
cloudflare-speedtest.cloudflare.zone=domain.com
cloudflare-speedtest.test.threads=101
EOF
load_config
set +e
validate_publish_config
status="$?"
set -e
assert_eq "$status" "21"
assert_eq "$CFST_ERROR_CODE" "CONFIG_THREADS_INVALID"

cat > "$CFST_TEST_UCI_FILE" <<'EOF'
cloudflare-speedtest.cloudflare.api_token=test-token
cloudflare-speedtest.cloudflare.zone=domain.com
cloudflare-speedtest.test.max_loss_ratio=1.01
EOF
load_config
set +e
validate_publish_config
status="$?"
set -e
assert_eq "$status" "21"
assert_eq "$CFST_ERROR_CODE" "CONFIG_LOSS_INVALID"

: > "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.test.direct_mode=2' >> "$CFST_TEST_UCI_FILE"
load_config
set +e
validate_base_config
status="$?"
set -e
assert_eq "$status" "21"
assert_eq "$CFST_ERROR_CODE" "CONFIG_DIRECT_MODE_INVALID"

: > "$CFST_TEST_UCI_FILE"
printf '%s\n' 'cloudflare-speedtest.test.publish_switch_margin=101' >> "$CFST_TEST_UCI_FILE"
load_config
set +e
validate_base_config
status="$?"
set -e
assert_eq "$status" "21"
assert_eq "$CFST_ERROR_CODE" "CONFIG_SWITCH_MARGIN_INVALID"

cat > "$CFST_TEST_UCI_FILE" <<'EOF'
cloudflare-speedtest.cloudflare.api_token=test-token
cloudflare-speedtest.cloudflare.zone=domain.com
cloudflare-speedtest.test.threads=4
cloudflare-speedtest.test.max_loss_ratio=0.2
EOF
load_config
validate_publish_config
assert_eq "$CFST_ERROR_CODE" ""
assert_eq "$CFST_ERROR_MESSAGE" ""
