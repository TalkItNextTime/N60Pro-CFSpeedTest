# N60 Pro CloudflareSpeedTest OpenWrt Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build installable OpenWrt packages for N60 Pro/XploreWrt 24.10 that periodically select a qualified Cloudflare IPv4 node, map the WAN location and ISP to a hostname such as `szct.domain.com`, safely update Cloudflare DNS, and expose configuration, status, manual actions, and logs in LuCI.

**Architecture:** A BusyBox `ash` control plane owns configuration validation, GeoIP normalization, naming, CSV result selection, Cloudflare API calls, state, logging, and the end-to-end runner. Cron is the only periodic scheduler; procd/rpcd expose asynchronous actions and cancellation. A separate LuCI JavaScript package talks only to the constrained rpcd interface and never reads secrets or invokes arbitrary commands.

**Tech Stack:** OpenWrt 24.10 package Makefiles, BusyBox `ash`, UCI, procd, cron, ubus/rpcd, `curl`, `jsonfilter`, LuCI JavaScript views, POSIX host-side shell tests, Python standard-library mock HTTP server, GitHub Actions, OpenWrt SDK, upstream XIU2/CloudflareSpeedTest built with Go.

---

## Scope and delivery slices

This is one product but should be implemented in four independently verifiable slices. Slice 1 delivers the host-tested control libraries. Slice 2 delivers DNS synchronization and the complete runner. Slice 3 packages the service and LuCI application. Slice 4 adds reproducible SDK builds, release artifacts, installation documentation, and N60 Pro acceptance.

Do not start LuCI before the control layer has stable commands and JSON schemas. Do not call the real Cloudflare API in automated tests. Do not make a release until the target package architecture is confirmed as `aarch64_cortex-a53` and both IPKs install on the router.

## File structure

```text
N60Pro-CFSpeedTest/
├── .github/workflows/
│   ├── test.yml                         # Host tests and static validation
│   └── build-openwrt.yml                # SDK build and release artifacts
├── LICENSE                              # GPL-3.0 project license
├── Makefile                             # Developer test/lint entry points
├── README.md                            # User installation and operation guide
├── docs/
│   ├── superpowers/specs/2026-08-12-n60pro-cloudflare-speedtest-openwrt-design.md
│   ├── superpowers/plans/2026-08-12-n60pro-cloudflare-speedtest-openwrt.md
│   └── acceptance-n60pro.md             # Exact target-device checklist
├── package/
│   ├── cloudflare-speedtest/
│   │   ├── Makefile                     # Core OpenWrt package definition
│   │   └── files/
│   │       ├── etc/config/cloudflare-speedtest
│   │       ├── etc/hotplug.d/iface/95-cloudflare-speedtest
│   │       ├── etc/init.d/cloudflare-speedtest
│   │       ├── etc/uci-defaults/90-cloudflare-speedtest
│   │       ├── usr/bin/cloudflare-speedtest
│   │       ├── usr/libexec/cloudflare-speedtest/
│   │       │   ├── config.sh            # UCI loading and validation
│   │       │   ├── dns.sh               # Cloudflare API and managed-record rules
│   │       │   ├── geoip.sh             # Public IPv4 and provider adapters
│   │       │   ├── lock.sh              # Atomic directory lock
│   │       │   ├── log.sh               # Bounded plugin/system logging
│   │       │   ├── naming.sh            # City/ISP mapping and FQDN validation
│   │       │   ├── result.sh            # CFST CSV validation and selection
│   │       │   ├── runner.sh            # State machine and orchestration
│   │       │   ├── schedule.sh          # Cron generation and hotplug debounce
│   │       │   └── state.sh             # Runtime/persistent JSON state
│   │       └── usr/share/cloudflare-speedtest/
│   │           ├── cities.tsv
│   │           ├── ip.txt
│   │           └── providers.tsv
│   └── luci-app-cloudflare-speedtest/
│       ├── Makefile
│       ├── htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js
│       └── root/
│           ├── etc/acl.d/luci-app-cloudflare-speedtest.json
│           ├── etc/config/rpcd
│           ├── usr/libexec/rpcd/cloudflare-speedtest
│           └── usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json
├── scripts/
│   ├── build-cfst.sh                    # Reproducible upstream ARM64 build
│   ├── build-sdk.sh                     # OpenWrt SDK package build
│   └── install.sh                       # Versioned IPK installer
├── tests/
│   ├── fixtures/
│   │   ├── cloudflare/*.json
│   │   ├── geoip/*.json
│   │   └── results/*.csv
│   ├── helpers/
│   │   ├── assert.sh
│   │   ├── mock-bin/*                   # curl, jsonfilter, uci, logger stubs
│   │   └── mock_http.py
│   ├── integration/
│   │   ├── test_dns.sh
│   │   ├── test_rpcd.sh
│   │   └── test_runner.sh
│   ├── unit/
│   │   ├── test_config.sh
│   │   ├── test_lock.sh
│   │   ├── test_log.sh
│   │   ├── test_naming.sh
│   │   ├── test_result.sh
│   │   ├── test_schedule.sh
│   │   └── test_state.sh
│   └── run.sh
└── upstream/
    └── cloudflare-speedtest.version      # Pinned tag, commit, archive SHA-256
```

The shell libraries use a shared convention: success returns `0`; expected operational failure returns a stable nonzero code; machine-readable functions print one compact JSON object; human-readable details go through `cfst_log`. No library executes work when sourced.

### Task 1: Establish the test harness and repository quality gates

**Files:**
- Create: `Makefile`
- Create: `tests/run.sh`
- Create: `tests/helpers/assert.sh`
- Create: `tests/helpers/mock-bin/logger`
- Create: `tests/helpers/mock-bin/jsonfilter`
- Create: `.github/workflows/test.yml`
- Create: `LICENSE`

- [ ] **Step 1: Write a failing smoke test for the empty implementation**

Create `tests/run.sh`:

```sh
#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export CFST_ROOT="$ROOT"
export PATH="$ROOT/tests/helpers/mock-bin:$PATH"

failed=0
for test_file in "$ROOT"/tests/unit/test_*.sh "$ROOT"/tests/integration/test_*.sh; do
    [ -f "$test_file" ] || continue
    printf '==> %s\n' "${test_file#$ROOT/}"
    if ! sh "$test_file"; then
        failed=1
    fi
done
exit "$failed"
```

Create `tests/helpers/assert.sh`:

```sh
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
```

Create `tests/unit/test_config.sh` with the first intentionally failing assertion:

```sh
#!/bin/sh
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"
assert_file_exists "$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh"
```

- [ ] **Step 2: Run the harness and verify the expected failure**

Run: `sh tests/run.sh`

Expected: exit code `1` and `missing file: .../config.sh`.

- [ ] **Step 3: Add developer and CI entry points**

Create root `Makefile`:

```make
.PHONY: test shellcheck

test:
	sh tests/run.sh

shellcheck:
	shellcheck -s sh $$(find package scripts tests -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/usr/libexec/*' \))
```

Create minimal mock commands:

```sh
# tests/helpers/mock-bin/logger
#!/bin/sh
printf '%s\n' "$*" >> "${CFST_TEST_LOGGER_FILE:-/dev/null}"
```

```sh
# tests/helpers/mock-bin/jsonfilter
#!/bin/sh
exec python3 "$CFST_ROOT/tests/helpers/jsonfilter_mock.py" "$@"
```

Add `tests/helpers/jsonfilter_mock.py` as a deliberately narrow test adapter supporting `-i FILE -e '@.path'` and `-s JSON -e '@.path'`; walk dot-separated object keys, print scalar values, and exit `1` for missing values. It must not be installed into the OpenWrt package.

Create `.github/workflows/test.yml`:

```yaml
name: test
on: [push, pull_request]
jobs:
  host-tests:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: make test
      - run: make shellcheck
```

Copy the GPL-3.0 text into `LICENSE`, matching upstream licensing obligations.

- [ ] **Step 4: Run static checks**

Run: `chmod +x tests/run.sh tests/helpers/mock-bin/* && make test`

Expected: the same single intentional missing-`config.sh` failure; the harness itself must not crash.

Run: `make shellcheck`

Expected: PASS for files created so far.

- [ ] **Step 5: Commit the harness**

```bash
git add Makefile LICENSE tests .github/workflows/test.yml
git commit -m "test: add portable shell test harness"
```

### Task 2: Define and validate the UCI configuration contract

**Files:**
- Create: `package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest`
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh`
- Modify: `tests/unit/test_config.sh`

- [ ] **Step 1: Replace the smoke test with failing validation tests**

Use a mock `uci` binary controlled by `CFST_TEST_UCI_FILE`. Add cases proving that defaults load, a missing Token produces `CONFIG_TOKEN_MISSING`, an invalid Zone produces `CONFIG_ZONE_INVALID`, and numeric bounds reject threads above `100` or a loss ratio outside `0..1`.

The test contract is:

```sh
load_config
assert_eq "$CFST_ENABLED" "1"
assert_eq "$CFST_INTERVAL_HOURS" "6"
assert_eq "$CFST_THREADS" "50"
assert_eq "$CFST_DOWNLOAD_COUNT" "5"
assert_status 20 validate_publish_config
assert_eq "$CFST_ERROR_CODE" "CONFIG_TOKEN_MISSING"
```

After setting `CFST_API_TOKEN=test-token`, `CFST_ZONE=domain.com`, and valid test values, `validate_publish_config` must return `0`.

- [ ] **Step 2: Run the focused test and verify failure**

Run: `CFST_ROOT="$PWD" PATH="$PWD/tests/helpers/mock-bin:$PATH" sh tests/unit/test_config.sh`

Expected: FAIL because `load_config` and validation functions do not exist.

- [ ] **Step 3: Add the default UCI file**

Create `/etc/config/cloudflare-speedtest` source file with named sections:

```uci
config main 'main'
        option enabled '1'
        option interval_hours '6'
        option startup_delay '120'
        option log_level 'info'

config cloudflare 'cloudflare'
        option api_token ''
        option zone ''
        option ttl '1'

config naming 'naming'
        option template '{city}{isp}.{zone}'
        option auto_detect '1'
        option city_override ''
        option isp_override ''
        option fallback_city ''
        option fallback_isp ''

config test 'test'
        option threads '50'
        option attempts '4'
        option download_count '5'
        option download_seconds '10'
        option port '443'
        option test_url 'https://cf.xiu2.xyz/url'
        option max_latency_ms '200'
        option max_loss_ratio '0.2'
        option min_speed_mbps '0.01'
        option task_timeout_seconds '900'
        option ip_file '/usr/share/cloudflare-speedtest/ip.txt'

config geo 'geo'
        option provider_order 'ipapi.co ipwho.is'
        option request_timeout '8'
        option cache_ttl_hours '72'
```

- [ ] **Step 4: Implement configuration loading and validation**

`config.sh` must expose `cfst_config_get SECTION OPTION DEFAULT`, `load_config`, `validate_base_config`, and `validate_publish_config`. `cfst_config_get` is implemented as:

```sh
cfst_config_get() {
    uci -q get "cloudflare-speedtest.$1.$2" 2>/dev/null || printf '%s' "$3"
}
```

`load_config` assigns every option from the UCI sections to the matching `CFST_*` variable by calling `cfst_config_get` explicitly for each field; it must not use `eval` or dynamically generated variable names.

- [ ] **Step 5: Run tests and static checks**

Run: `make test && make shellcheck`

Expected: all current tests PASS.

- [ ] **Step 6: Commit configuration contract**

```bash
git add package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh tests
git commit -m "feat: define validated UCI configuration"
```

### Task 3: Implement atomic runtime state and bounded logging

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh`
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh`
- Create: `tests/unit/test_state.sh`
- Create: `tests/unit/test_log.sh`

- [ ] **Step 1: Write failing state tests**

Test `state_init`, `state_set_phase`, `state_fail`, `state_save_persistent`, and recovery from malformed persistent JSON. Use temporary paths through `CFST_RUNTIME_DIR`, `CFST_STATE_FILE`, and `CFST_LOG_FILE`.

Required status JSON after `state_set_phase testing_latency "Testing candidates"`:

```json
{"phase":"testing_latency","message":"Testing candidates","updated_at":1700000000}
```

Tests may set `CFST_NOW=1700000000` for deterministic output. A malformed persistent file must set `CFST_STATE_CORRUPT=1` and must not expose a managed record for deletion.

- [ ] **Step 2: Write failing logging tests**

Set `CFST_LOG_MAX_BYTES=120` and `CFST_LOG_ROTATIONS=2`; write enough lines to rotate. Assert the active log exists, no log exceeds the configured bound by more than one line, `cloudflare-speedtest.log.1` exists, and text matching `Bearer secret-token` is replaced with `[REDACTED]`.

- [ ] **Step 3: Run focused tests and verify failures**

Run: `make test`

Expected: FAIL because state and logging functions are missing.

- [ ] **Step 4: Implement atomic state**

`state.sh` must define fixed defaults:

```sh
: "${CFST_RUNTIME_DIR:=/tmp/cloudflare-speedtest}"
: "${CFST_STATUS_FILE:=$CFST_RUNTIME_DIR/status.json}"
: "${CFST_STATE_FILE:=/etc/cloudflare-speedtest/state.json}"
```

Implement `json_escape` without external Python, `atomic_write` using a same-directory temporary file plus `mv`, `state_init`, `state_set_phase`, `state_fail`, `state_success`, `state_load_persistent`, and `state_save_persistent`. Persistent state schema version `1` contains `last_published`, `last_tested`, `geo_cache`, and `managed_record`. Refuse managed-record deletion data when parsing fails.

- [ ] **Step 5: Implement bounded and redacted logging**

`log.sh` must expose `cfst_log LEVEL MESSAGE`, `rotate_log_if_needed`, `redact_text`, `read_log_bytes LIMIT`, and `clear_plugin_logs`. Write one timestamped line to the plugin file and `logger -t cloudflare-speedtest`. Redact Authorization values and configured Token before either destination. Reject a log read limit over `65536` bytes.

- [ ] **Step 6: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/state.sh package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh tests/unit
git commit -m "feat: add atomic state and bounded logs"
```

### Task 4: Implement lock ownership and stale-lock recovery

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/lock.sh`
- Create: `tests/unit/test_lock.sh`

- [ ] **Step 1: Write failing lock tests**

Test first acquisition, second acquisition returning `30` with `TASK_ALREADY_RUNNING`, release by owner, refusal to release by another PID, and stale lock recovery when the recorded PID does not exist.

Use `CFST_LOCK_DIR="$TMP/lock"`, `CFST_SELF_PID=1234`, and a mock `kill` command so tests do not depend on host PIDs.

- [ ] **Step 2: Run focused tests**

Run: `make test`

Expected: FAIL due to missing `acquire_lock`.

- [ ] **Step 3: Implement atomic directory locking**

`lock.sh` exposes `acquire_lock TRIGGER`, `release_lock`, and `read_lock`. Acquisition uses `mkdir "$CFST_LOCK_DIR"`, then writes `pid`, `started_at`, and `trigger`. If `mkdir` fails, read the PID and use `kill -0`; remove and retry only when the PID is numeric and no longer alive. Register `trap 'release_lock' EXIT INT TERM` only in the runner, not when this library is sourced.

- [ ] **Step 4: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/lock.sh tests/unit/test_lock.sh tests/helpers/mock-bin
git commit -m "feat: prevent concurrent speed tests"
```

### Task 5: Implement deterministic city, ISP, and hostname mapping

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/naming.sh`
- Create: `package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/cities.tsv`
- Create: `package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/providers.tsv`
- Create: `tests/unit/test_naming.sh`

- [ ] **Step 1: Write failing mapping tests**

Cover `深圳市 -> sz`, `Shenzhen -> sz`, `中国电信/China Telecom/CHINANET -> ct`, China Unicom `-> cu`, China Mobile `-> cm`, China Broadnet `-> cbn`, CERNET `-> cernet`, and unknown input `->` empty.

Test field priority with manual city `gz`, automatic ISP `ct`, and cached values. Test template rendering `{city}{isp}.{zone}` to `szct.domain.com`. Reject uppercase output, underscores, empty labels, labels over 63 bytes, an FQDN over 253 bytes, and a template containing `{unknown}`.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because mapping functions are missing.

- [ ] **Step 3: Add mapping data**

`cities.tsv` uses `code<TAB>alias1|alias2...`, including all Chinese provincial capitals, Shenzhen, major municipalities, and common English spellings. `providers.tsv` contains the five confirmed ISP codes and conservative aliases. Keep data separate from code so later additions do not alter control flow.

- [ ] **Step 4: Implement naming functions**

Expose:

```sh
normalize_text INPUT
map_city INPUT
map_isp INPUT
choose_location_field OVERRIDE AUTO CACHED FALLBACK
render_hostname TEMPLATE CITY ISP ZONE
validate_hostname FQDN
```

Normalization lowercases ASCII, strips province/city suffixes where safe, and removes surrounding whitespace. `render_hostname` only accepts `{city}`, `{isp}`, and `{zone}` and returns `40` with `NAMING_UNRESOLVED` when a required value is empty.

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/naming.sh package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest tests/unit/test_naming.sh
git commit -m "feat: map network location to DNS names"
```

### Task 6: Implement public IPv4 and GeoIP provider adapters

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh`
- Create: `tests/fixtures/geoip/ipapi-shenzhen-telecom.json`
- Create: `tests/fixtures/geoip/ipwhois-shenzhen-telecom.json`
- Create: `tests/fixtures/geoip/invalid.json`
- Create: `tests/unit/test_geoip.sh`

- [ ] **Step 1: Write failing adapter and fallback tests**

Test parsers against fixed fixtures. Both providers must normalize to:

```json
{"ip":"203.0.113.10","city":"深圳","isp":"中国电信","source":"ipapi.co"}
```

Use documentation-range addresses in fixtures, but make `validate_public_ipv4` reject private, loopback, link-local, multicast, `0.0.0.0/8`, and documentation ranges when processing live results. Test provider one failure followed by provider two success, all-provider failure, manual field overrides, and unexpired cache fallback.

- [ ] **Step 2: Run tests and verify failure**

Run: `make test`

Expected: FAIL because GeoIP functions are absent.

- [ ] **Step 3: Implement provider adapters**

Expose `validate_public_ipv4`, `parse_ipapi`, `parse_ipwhois`, `query_geo_provider`, and `resolve_network_identity`. Production requests use `curl --noproxy '*' --fail-with-body --silent --show-error --connect-timeout "$CFST_GEO_TIMEOUT" --max-time "$CFST_GEO_TIMEOUT"`. Do not inherit proxy environment variables; clear `http_proxy`, `https_proxy`, and `all_proxy` for the child command.

`resolve_network_identity` tries providers in configured order, validates the returned IP, maps city/ISP, applies field-level overrides, then uses unexpired cache or configured fallback. Return `41 GEO_ALL_PROVIDERS_FAILED` if no safe hostname fields can be resolved.

- [ ] **Step 4: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh tests/fixtures/geoip tests/unit/test_geoip.sh
git commit -m "feat: detect WAN location with provider fallback"
```

### Task 7: Parse and select qualified CloudflareSpeedTest results

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh`
- Create: `tests/fixtures/results/valid.csv`
- Create: `tests/fixtures/results/no-qualified.csv`
- Create: `tests/fixtures/results/bad-header.csv`
- Create: `tests/unit/test_result.sh`

- [ ] **Step 1: Write failing CSV tests**

Use the exact upstream header:

```csv
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
```

Include candidates that prove ordering is download speed descending, then latency ascending, then loss ascending. Include malformed numbers, a private IP, zero received packets, excessive latency/loss, and speed under `0.01` MB/s. Assert the selected result schema:

```json
{"ip":"104.18.2.10","latency_ms":38.1,"loss_ratio":0,"speed_mbps":46.7,"colo":"HKG"}
```

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL due to missing `select_best_result`.

- [ ] **Step 3: Implement strict CSV parsing**

Expose `validate_cfst_header FILE`, `is_ipv4`, `candidate_is_qualified`, and `select_best_result FILE MAX_LATENCY MAX_LOSS MIN_SPEED`. Strip a possible UTF-8 BOM only from the header. Reject an unexpected column count or header with `50 RESULT_BAD_CSV`. Parse rows with `awk -F,` because upstream fields are numeric/simple and do not contain quoted commas; document this contract in the function. Sort using `sort -t, -k6,6nr -k5,5n -k4,4n` after qualification.

- [ ] **Step 4: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh tests/fixtures/results tests/unit/test_result.sh
git commit -m "feat: validate and select speed test results"
```

### Task 8: Implement Cloudflare API synchronization and managed-record safety

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/dns.sh`
- Create: `tests/helpers/mock_http.py`
- Create: `tests/fixtures/cloudflare/*.json`
- Create: `tests/integration/test_dns.sh`

- [ ] **Step 1: Write failing API integration scenarios**

Start the Python standard-library mock server on an ephemeral localhost port. Script responses for Token verification, Zone lookup, record not found then create, same-value idempotence, changed-value update, duplicate records, 401, 403, 429 with `Retry-After: 0`, transient 500 then success, and old-record deletion refusal when managed metadata no longer matches.

Assert that requests contain an `Authorization` header using the configured test Token, JSON bodies always set `"type":"A"` and `"proxied":false`, and the Token never appears in captured plugin logs.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because DNS functions are missing.

- [ ] **Step 3: Implement the API request primitive**

`dns.sh` exposes:

```sh
cf_api METHOD PATH BODY
cf_verify_token
cf_find_zone_id ZONE
cf_get_a_records ZONE_ID FQDN
cf_upsert_a_record ZONE_ID FQDN IP TTL
cf_delete_managed_record ZONE_ID RECORD_ID EXPECTED_NAME EXPECTED_IP
cf_sync_dns FQDN IP
```

`cf_api` writes response headers/body to the task temporary directory, records the HTTP status separately, and parses `.success`, `.errors[0].code`, and IDs using `jsonfilter`. Retry at most three times for 429/5xx with delays `1,2,4`, capped by a test-overridable sleep command. Return stable codes: `60 CF_API_UNAUTHORIZED`, `61 CF_API_FORBIDDEN`, `62 CF_API_RATE_LIMITED`, `63 CF_API_TEMPORARY`, `64 DNS_MULTIPLE_RECORDS`, `65 DNS_VERIFY_FAILED`.

- [ ] **Step 4: Implement safe upsert and cleanup ordering**

`cf_sync_dns` queries exactly one Zone, refuses multiple same-name A records, creates or updates the new record, re-reads it, saves the new managed metadata, and only then considers deletion of the previous managed record. Cleanup requires matching local schema version, record ID, expected hostname, type A, and the previously published IP. If cleanup fails after publication, return partial-success code `66` without rolling back the new record.

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS for all mock scenarios.

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/dns.sh tests/helpers/mock_http.py tests/fixtures/cloudflare tests/integration/test_dns.sh
git commit -m "feat: safely synchronize Cloudflare DNS"
```

### Task 9: Build the end-to-end runner and command interface

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh`
- Create: `package/cloudflare-speedtest/files/usr/bin/cloudflare-speedtest`
- Create: `tests/helpers/mock-bin/cfst`
- Create: `tests/integration/test_runner.sh`

- [ ] **Step 1: Write failing orchestration tests**

Test `test-only` and `test-and-update`. The mock `cfst` copies a selected fixture to the path following `-o` and records arguments. Assert the production call includes absolute `-f`, absolute `-o`, `-p 0`, `-n 50`, `-t 4`, `-dn 5`, `-dt 10`, `-tp 443`, `-tl 200`, and `-tlr 0.2`.

Test these state transitions: preparation, network detection, speed test, result validation, DNS update, success. Assert `test-only` never invokes the Cloudflare endpoint. Cover lock conflict, timeout, cancellation, no result, GeoIP failure with a usable manual override, DNS failure preserving prior persistent publication, and new publication plus cleanup failure producing `partial_success`.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because the runner does not exist.

- [ ] **Step 3: Implement the public command**

`/usr/bin/cloudflare-speedtest` accepts only:

```text
run --mode test-only|test-and-update --trigger manual|cron|hotplug
stop
status
result
validate
logs [bytes]
clear-logs
apply-schedule
```

Reject every unknown command or argument with exit `2`. `status`, `result`, and `logs` are read-only. `stop` reads the owned runner PID, sends TERM, waits five seconds, then KILL only if the same PID still owns the lock.

- [ ] **Step 4: Implement runner orchestration**

Source libraries by absolute directory. Load and validate configuration before acquiring external resources. Create `/tmp/cloudflare-speedtest/run.$$`, acquire lock, write PID, install cleanup traps, and invoke `/usr/bin/cfst` through `nice -n 10` with the exact arguments asserted by the integration test. Implement a portable timeout watchdog: launch the child, launch `(sleep "$CFST_TASK_TIMEOUT"; kill -TERM "$child")`, wait for the child, then cancel and reap the watchdog.

Always persist `last_tested` after a qualified result. Persist `last_published` only after verified DNS success. Return `0` success, `66` partial success, and each library's stable failure code otherwise.

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/usr/bin package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh tests/helpers/mock-bin/cfst tests/integration/test_runner.sh
git commit -m "feat: orchestrate testing and DNS publication"
```

### Task 10: Add cron, procd, hotplug, and upgrade-safe defaults

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/schedule.sh`
- Create: `package/cloudflare-speedtest/files/etc/init.d/cloudflare-speedtest`
- Create: `package/cloudflare-speedtest/files/etc/hotplug.d/iface/95-cloudflare-speedtest`
- Create: `package/cloudflare-speedtest/files/etc/uci-defaults/90-cloudflare-speedtest`
- Create: `tests/unit/test_schedule.sh`

- [ ] **Step 1: Write failing schedule tests**

Assert six-hour configuration creates exactly:

```cron
17 */6 * * * /usr/bin/cloudflare-speedtest run --mode test-and-update --trigger cron
```

Use an off-minute derived deterministically from the device hostname to avoid fleet concentration. Disabled configuration removes the cron file. Re-applying is idempotent. Hotplug ignores non-WAN interfaces, ignores `ifdown`, debounces events within 300 seconds, and schedules one delayed background request rather than running CFST inline.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL due to missing schedule implementation.

- [ ] **Step 3: Implement schedule generation**

`schedule.sh` exposes `schedule_minute HOSTNAME`, `write_cron`, `remove_cron`, and `hotplug_schedule`. Validate interval as one of `1,2,3,4,6,8,12,24`; write through a temporary file, set mode `0644`, and signal `/etc/init.d/cron reload` only when content changes.

- [ ] **Step 4: Add service lifecycle files**

The init script uses `USE_PROCD=1` but does not start a permanent speed-test process. `start_service` creates runtime directories and applies the cron file; `stop_service` removes cron and stops an active owned runner; `reload_service` validates and reapplies the schedule. Triggers watch the `cloudflare-speedtest` UCI package.

The hotplug script checks `ACTION=ifup` and the configured WAN logical interface, then calls `hotplug_schedule`. The UCI defaults script creates only missing sections/options, sets `/etc/config/cloudflare-speedtest` mode `0600`, enables the init service, applies schedule, and exits `0` so OpenWrt removes it.

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/cloudflare-speedtest/files/etc package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/schedule.sh tests/unit/test_schedule.sh
git commit -m "feat: schedule tests with OpenWrt lifecycle hooks"
```

### Task 11: Define the core OpenWrt package and reproducible CFST binary input

**Files:**
- Create: `upstream/cloudflare-speedtest.version`
- Create: `scripts/build-cfst.sh`
- Create: `package/cloudflare-speedtest/Makefile`
- Copy: `package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/ip.txt`
- Create: `tests/unit/test_package.sh`

- [ ] **Step 1: Pin the upstream source**

Pin the reviewed upstream release `v2.3.5` in `upstream/cloudflare-speedtest.version`:

```sh
CFST_VERSION='2.3.5'
CFST_COMMIT='65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4'
CFST_SOURCE_URL='https://codeload.github.com/XIU2/CloudflareSpeedTest/tar.gz/65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4'
CFST_SOURCE_SHA256='ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32'
```

The commit comes from the `v2.3.5` tag and the checksum is for the exact codeload archive above. Never replace these values with `latest` or a branch name during an ordinary build; updating upstream is a separate reviewed change with a regenerated checksum.

- [ ] **Step 2: Write failing package metadata tests**

Assert the core package depends on `+curl +ca-bundle +jsonfilter +uci +ubus +rpcd +procd`, installs all runtime files, and never downloads an unpinned `latest` artifact. Do not add a separate `cron` dependency: XploreWrt/OpenWrt runs `crond` from BusyBox. Assert `ip.txt` contains only IPv4 CIDR lines and comments. The built IPK architecture is verified from the OpenWrt SDK output as `aarch64_cortex-a53`, rather than hard-coding `PKGARCH` in the package Makefile.

- [ ] **Step 3: Implement reproducible ARM64 build helper**

`scripts/build-cfst.sh` loads the pin file, downloads and verifies source, then runs:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
  -trimpath -ldflags "-s -w -X main.version=$CFST_VERSION" \
  -o "$OUTPUT_DIR/cfst" .
```

Run `file` and fail unless output is a statically linked AArch64 ELF. The script also copies upstream `LICENSE`, source archive, and `ip.txt` into the release staging directory.

- [ ] **Step 4: Implement the package Makefile**

Use OpenWrt `golang-package.mk` and build from the pinned source for GPL compliance and reproducibility. The package installs `cfst` as `/usr/bin/cfst`, shell files as mode `0755`, data as `0644`, UCI config as `0600`, and init/hotplug files with executable modes. Add `conffiles` for `/etc/config/cloudflare-speedtest` and `/etc/cloudflare-speedtest/state.json`. Do not set `PKGARCH` manually; the `mediatek/filogic` SDK emits the correct target architecture metadata.

- [ ] **Step 5: Verify and commit**

Run: `make test && make shellcheck`

Expected: PASS.

Run: `sh scripts/build-cfst.sh /tmp/cfst-build`

Expected: `/tmp/cfst-build/cfst` is reported by `file` as an ELF 64-bit ARM AArch64 statically linked executable, and `cfst -v` reports version `2.3.5`.

```bash
git add upstream scripts/build-cfst.sh package/cloudflare-speedtest tests/unit/test_package.sh
git commit -m "build: package pinned ARM64 CloudflareSpeedTest"
```

### Task 12: Implement the constrained rpcd API

**Files:**
- Create: `package/luci-app-cloudflare-speedtest/root/usr/libexec/rpcd/cloudflare-speedtest`
- Create: `package/luci-app-cloudflare-speedtest/root/etc/acl.d/luci-app-cloudflare-speedtest.json`
- Create: `tests/integration/test_rpcd.sh`

- [ ] **Step 1: Write failing rpcd protocol tests**

Invoke the executable with rpcd's `list` and `call` protocol. Assert listed methods and schemas for `status`, `result`, `start`, `stop`, `validate`, `logs`, `clear_logs`, `config_summary`, and `set_token`.

Assert `config_summary` returns `token_configured: true` but never returns the Token. Assert `start` accepts only `test-only` and `test-and-update`, returns immediately with `{"accepted":true}`, and rejects a conflict. Assert log length is capped at 65536.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because rpcd executable is absent.

- [ ] **Step 3: Implement rpcd methods**

Use `/usr/share/libubox/jshn.sh` to parse request JSON and build response JSON. Never interpolate unvalidated request values into shell commands. Launch accepted work with `/usr/bin/cloudflare-speedtest run ... >/dev/null 2>&1 &` and return the PID only as an informational value. `set_token` treats missing/empty input as “unchanged” unless `clear=true`; update via `uci set`, commit only that package, and reset mode `0600`.

- [ ] **Step 4: Add least-privilege ACL**

The ACL grants read access to the plugin ubus object's read methods and UCI read for its package; write access grants only plugin action methods and UCI write for its package. Do not grant generic `file`, `exec`, or unrestricted UCI permissions.

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS and no Token appears in test output.

```bash
git add package/luci-app-cloudflare-speedtest/root tests/integration/test_rpcd.sh
git commit -m "feat: expose safe rpcd management API"
```

### Task 13: Build the LuCI single-page dashboard

**Files:**
- Create: `package/luci-app-cloudflare-speedtest/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js`
- Create: `package/luci-app-cloudflare-speedtest/root/usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json`
- Create: `package/luci-app-cloudflare-speedtest/Makefile`
- Create: `tests/unit/test_luci.sh`

- [ ] **Step 1: Write failing static LuCI contract tests**

Assert the view imports only LuCI modules (`view`, `form`, `rpc`, `uci`, `poll`, `ui`, `dom`), declares the nine RPC calls, renders three status cards, contains action labels for test-and-update/test-only/stop, uses a password option for Token, and does not contain `fetch(`, external URLs, `localStorage`, `sessionStorage`, `fs.exec`, or direct shell commands.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because LuCI files do not exist.

- [ ] **Step 3: Add menu and package metadata**

Menu path is `admin/services/cloudflare-speedtest`, title `Cloudflare 优选 IP`, order `60`, action `view`, dependency on the ACL group. The LuCI package depends on `+luci-base +rpcd +cloudflare-speedtest` and follows standard `luci.mk` packaging.

- [ ] **Step 4: Implement the dashboard skeleton and polling**

`overview.js` renders responsive status cards using LuCI's existing classes, not an external framework. `poll.add()` refreshes status every three seconds while active and every fifteen seconds while idle. Buttons disable during conflicting phases. Notifications translate stable error codes into concise Chinese messages while preserving the backend message for diagnostics.

- [ ] **Step 5: Implement configuration sections**

Use one `form.Map('cloudflare-speedtest')` with tabs for basic, Cloudflare, speed test, naming, and logs. Apply numeric datatypes and ranges matching `config.sh`. The Token field is password type with placeholder “已配置；留空保持不变”; save it through `set_token`, not ordinary UCI load. Display a fixed explanation that orange-cloud proxying is disabled because it defeats selected-IP DNS resolution.

The logs panel reads bounded logs, supports manual/automatic refresh, and calls only `clear_logs`. The result panel visually distinguishes `last_tested` from `last_published`.

- [ ] **Step 6: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add package/luci-app-cloudflare-speedtest tests/unit/test_luci.sh
git commit -m "feat: add LuCI speed test dashboard"
```

### Task 14: Add SDK build, artifact validation, and installer

**Files:**
- Create: `scripts/build-sdk.sh`
- Create: `scripts/install.sh`
- Create: `.github/workflows/build-openwrt.yml`
- Create: `tests/unit/test_release_scripts.sh`

- [ ] **Step 1: Write failing release-script tests**

Assert SDK URL/version and SHA are explicit inputs, build script verifies archive SHA, feeds both packages into the SDK, selects `CONFIG_PACKAGE_cloudflare-speedtest=m` and `CONFIG_PACKAGE_luci-app-cloudflare-speedtest=m`, and fails unless both IPKs exist. Assert installer checks `DISTRIB_ARCH=aarch64_cortex-a53`, downloads a versioned checksum file, verifies both IPKs, installs core before LuCI, and never uses `--force-depends`.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because scripts are absent.

- [ ] **Step 3: Implement SDK build script**

Accept optional `SDK_URL` and `SDK_SHA256` overrides, defaulting to:

```sh
SDK_URL='https://downloads.openwrt.org/releases/24.10.2/targets/mediatek/filogic/openwrt-sdk-24.10.2-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst'
SDK_SHA256='df288284baa46d37cbc71812130b72617333f886f5c93c11f0548e28f0bb8309'
```

Download with `curl`, verify the exact checksum, extract, symlink/copy repository package directories into `package/`, run `./scripts/feeds update -a`, `./scripts/feeds install -a`, write the two package selections, then run:

```sh
make defconfig
make package/cloudflare-speedtest/compile V=sc
make package/luci-app-cloudflare-speedtest/compile V=sc
```

Copy IPKs, package manifests, source pin file, upstream source archive, GPL license, and `SHA256SUMS` to the output directory.

- [ ] **Step 4: Implement installer**

`install.sh` accepts `--version vX.Y.Z` and optional `--base-url`. Read `/etc/openwrt_release`, reject other architectures with an exact message, check free `/overlay` space, download release checksums and both IPKs to `/tmp`, verify, run `opkg update`, install core then LuCI, restart rpcd/uhttpd only if required, enable/start the service, and print the LuCI menu path. Preserve existing UCI config on upgrade.

- [ ] **Step 5: Add GitHub Actions build**

Trigger manually and on `v*` tags. Use a pinned OpenWrt 24.10 SDK URL and SHA for `mediatek/filogic`. Run host tests first, then SDK build. Upload artifact bundle on every run; on tags, attach IPKs, checksums, licenses, and source bundle to a GitHub Release.

- [ ] **Step 6: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

Run with the pinned defaults: `sh scripts/build-sdk.sh dist`

To override intentionally: `SDK_URL="$SDK_URL" SDK_SHA256="$SDK_SHA256" sh scripts/build-sdk.sh dist`

Expected: two IPKs and a valid `dist/SHA256SUMS`.

```bash
git add scripts .github/workflows/build-openwrt.yml tests/unit/test_release_scripts.sh
git commit -m "build: produce verified OpenWrt release artifacts"
```

### Task 15: Document installation, Cloudflare permissions, operation, and recovery

**Files:**
- Create: `README.md`
- Create: `docs/acceptance-n60pro.md`
- Modify: `.gitignore`

- [ ] **Step 1: Write documentation acceptance assertions**

Add a simple `tests/unit/test_docs.sh` that checks README contains the exact target architecture, Cloudflare permissions `Zone:Read` and `DNS:Edit`, gray-cloud explanation, proxy bypass warning, install/upgrade/uninstall commands, LuCI path, CLI diagnostics, and Token storage warning.

- [ ] **Step 2: Run and verify failure**

Run: `make test`

Expected: FAIL because README content is absent.

- [ ] **Step 3: Write user documentation**

README sequence must be: supported device/firmware, features, security model, Token creation, release installation, LuCI first-run configuration, manual validation, scheduling, logs, CLI troubleshooting, upgrade, uninstall, DNS cleanup policy, build-from-source, GPL/source availability.

Document that GeoIP and CFST requests must bypass transparent proxying; a suspicious `0.xx ms` result indicates proxy interception. State explicitly that uninstall does not delete remote DNS records and that the UCI Token is protected by filesystem permissions but not encrypted at rest.

- [ ] **Step 4: Write exact N60 Pro acceptance checklist**

`docs/acceptance-n60pro.md` records commands and expected observations for firmware identity, package install, dependency presence, LuCI menu load, Token redaction, `test-only`, `test-and-update`, DNS lookup, Cloudflare dashboard confirmation, location override, managed old-record cleanup, task conflict, cancellation, router reboot, three scheduled runs, log rotation, CPU/memory observation, and uninstall/reinstall.

Use commands including:

```sh
opkg print-architecture
ubus call system board
ubus call cloudflare-speedtest status
logread -e cloudflare-speedtest
nslookup szct.domain.com 1.1.1.1
ps w | grep '[c]fst'
```

- [ ] **Step 5: Run and commit**

Run: `make test && make shellcheck`

Expected: PASS.

```bash
git add README.md docs/acceptance-n60pro.md .gitignore tests/unit/test_docs.sh
git commit -m "docs: add installation and N60 Pro acceptance guide"
```

### Task 16: Perform complete host, package, and target-device verification

**Files:**
- Modify only files required by defects discovered during verification
- Update: `docs/acceptance-n60pro.md` with actual tested firmware/release values

- [ ] **Step 1: Run the full host suite from a clean checkout**

Run:

```bash
git clean -xfd
make test
make shellcheck
```

Expected: all tests PASS and shellcheck reports no findings. Recreate only ignored build artifacts after cleaning.

- [ ] **Step 2: Build release artifacts from the pinned SDK**

Run: `sh scripts/build-sdk.sh dist` using the pinned OpenWrt 24.10.2 `mediatek/filogic` SDK defaults.

Expected: core and LuCI IPKs for `aarch64_cortex-a53`, source/license bundle, manifests, and matching SHA256SUMS.

Inspect:

```bash
sha256sum -c dist/SHA256SUMS
for p in dist/*.ipk; do tar -tf "$p" >/dev/null; done
```

Expected: every checksum is OK and every IPK archive is readable.

- [ ] **Step 3: Install on the N60 Pro and run acceptance**

Copy the release bundle to `/tmp/cfst-release` on the router and execute every item in `docs/acceptance-n60pro.md`. Use a Cloudflare Token restricted to the test Zone. First use a disposable hostname or test Zone; move to the production `domain.com` Zone only after the disposable run passes.

Expected: `szct.domain.com` is a gray-cloud A record pointing to the published CFST result; `test-only` does not change DNS; failures preserve the previous record; Token is absent from ubus output, logs, and `ps`; LuCI remains responsive during testing.

- [ ] **Step 4: Verify resource and flash behavior**

Before, during, and after a run capture:

```sh
free
uptime
df -h /overlay
top -b -n 1 | head -20
du -k /tmp/cloudflare-speedtest /var/log/cloudflare-speedtest* 2>/dev/null
```

Expected: no OOM, no management outage, temporary files are removed after completion, and persistent plugin logs remain within configured bounds.

- [ ] **Step 5: Fix discovered defects with regression tests**

For each defect, first add a failing host test or a narrowly scoped device reproduction, make the smallest fix, rerun the focused test, then rerun `make test && make shellcheck`. Do not bundle unrelated cleanup.

- [ ] **Step 6: Commit verified release readiness**

```bash
git add .
git commit -m "test: verify OpenWrt plugin on N60 Pro"
```

- [ ] **Step 7: Push and create a version tag only after all checks pass**

```bash
git push origin main
git tag -a v0.1.0 -m "N60 Pro CloudflareSpeedTest v0.1.0"
git push origin v0.1.0
```

Expected: GitHub Actions host tests and OpenWrt build complete successfully, and the release contains both IPKs, SHA256SUMS, upstream source, and license files.

## Final plan self-review

The plan covers every design-spec subsystem: UCI validation, state and bounded logs, locking, city/ISP mapping, two-provider GeoIP fallback, strict CFST CSV parsing, safe Cloudflare synchronization, orchestration and cancellation, cron/procd/hotplug lifecycle, pinned ARM64 source build, constrained rpcd/ACL, LuCI single-page UI, SDK/CI, installation documentation, and N60 Pro verification. The interfaces named by later tasks are introduced in earlier tasks, and automated tests avoid real DNS mutations. No implementation step permits deletion of an unmanaged DNS record or exposure of the Token.
