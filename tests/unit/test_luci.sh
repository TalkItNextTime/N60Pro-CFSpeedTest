#!/bin/sh
# Static contract tests for luci-app-cloudflare-speedtest dashboard.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

LUCI_ROOT="$CFST_ROOT/package/luci-app-cloudflare-speedtest"
VIEW_JS="$LUCI_ROOT/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js"
MENU_JSON="$LUCI_ROOT/root/usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json"
MAKEFILE="$LUCI_ROOT/Makefile"
ACL_JSON="$LUCI_ROOT/root/etc/acl.d/luci-app-cloudflare-speedtest.json"

assert_file_exists "$VIEW_JS"
assert_file_exists "$MENU_JSON"
assert_file_exists "$MAKEFILE"
assert_file_exists "$ACL_JSON"

js="$(tr -d '\r' < "$VIEW_JS")"
menu="$(tr -d '\r' < "$MENU_JSON")"
mk="$(tr -d '\r' < "$MAKEFILE")"

# --- imports: only LuCI modules ---
assert_contains "$js" "'require view'"
assert_contains "$js" "'require form'"
assert_contains "$js" "'require rpc'"
assert_contains "$js" "'require uci'"
assert_contains "$js" "'require poll'"
assert_contains "$js" "'require ui'"
assert_contains "$js" "'require dom'"

# No non-LuCI require modules beyond the allowed set
printf '%s\n' "$js" | grep -E "'require [^']+'" | while IFS= read -r line; do
	case "$line" in
		*"'require view'"*|*"'require form'"*|*"'require rpc'"*|*"'require uci'"*|*"'require poll'"*|*"'require ui'"*|*"'require dom'"*)
			: ;;
		*)
			fail "disallowed require: $line"
			;;
	esac
done

# --- nine RPC declarations matching Task 12 ---
for method in status result start stop validate logs clear_logs config_summary set_token; do
	assert_contains "$js" "method: '$method'"
done
assert_contains "$js" "object: 'cloudflare-speedtest'"

# --- three status cards ---
assert_contains "$js" 'status-card'
# Expect three card containers
card_count="$(printf '%s\n' "$js" | grep -c 'status-card' || true)"
[ "$card_count" -ge 3 ] || fail "expected at least 3 status-card markers, got $card_count"

# --- action labels ---
assert_contains "$js" 'test-and-update'
assert_contains "$js" 'test-only'
assert_contains "$js" 'stop'
assert_contains "$js" '立即测速并更新 DNS'
assert_contains "$js" '仅测速'
assert_contains "$js" '停止当前任务'

# --- Token password + set_token path ---
assert_contains "$js" "form.Value, '_api_token'"
assert_contains "$js" "s.taboption('basic', form.Value, '_api_token'"
assert_contains "$js" 'o.password = true;'
# The log controls live only in the logs tab, and the view exposes LuCI's save footer.
assert_contains "$js" "'_logs_panel'"
assert_contains "$js" 'renderLogsPanel(view)'
assert_contains "$js" "form.ListValue, 'proxied'"
assert_contains "$js" "o.value('0'"
assert_contains "$js" "o.value('1'"
assert_contains "$js" 'handleSaveApply: function'
assert_contains "$js" 'handleSave: function'
assert_contains "$js" 'handleReset: function'
assert_contains "$js" 'function bindPreferredOption(option)'
assert_contains "$js" "uci.get('cloudflare-speedtest', 'preferred'"
assert_contains "$js" "uci.set('cloudflare-speedtest', 'preferred'"
# Preferred URL edits must stage changes in cloudflare-speedtest.preferred,
# not in the visual main section used to render the tabbed form.
assert_contains "$js" "bindPreferredOption(s.taboption('speedtest', form.Value, 'url_ct'"
assert_contains "$js" "bindPreferredOption(s.taboption('speedtest', form.Value, 'url_cu'"
assert_contains "$js" "bindPreferredOption(s.taboption('speedtest', form.Value, 'url_cmcc'"
assert_contains "$js" "bindPreferredOption(s.taboption('speedtest', form.Value, 'url_custom'"
if printf '%s\n' "$js" | grep -F "var logs = renderLogsPanel(view)" >/dev/null 2>&1; then
	fail 'runtime logs must not be rendered below the configuration map'
fi
# LuCI 24.10 form.Map.render() is async; never insert its Promise as a DOM child.
assert_contains "$js" 'Promise.resolve(map.render())'
if printf '%s\n' "$js" | grep -E '\[ map\.render\(\) \]' >/dev/null 2>&1; then
	fail 'map.render() must be resolved before DOM insertion'
fi
assert_contains "$js" '已配置；留空保持不变'
assert_contains "$js" 'set_token'
# Must not load secret via ordinary UCI of api_token into form as plain value
printf '%s\n' "$js" | grep -E "option\(['\"]api_token['\"]\)" >/dev/null 2>&1 \
	&& fail 'api_token must not be a normal UCI form option'
assert_contains "$js" 'token_configured'

# --- poll intervals: 3s active, 15s idle ---
assert_contains "$js" 'poll.add'
assert_contains "$js" '3000'
assert_contains "$js" '15000'

# --- buttons disable during conflicting phases ---
assert_contains "$js" 'disabled'
assert_contains "$js" 'phase'

# --- error code notifications (Chinese) ---
for code in CONFIG_TOKEN_MISSING GEO_ALL_PROVIDERS_FAILED CFST_TIMEOUT RESULT_NO_QUALIFIED_IP CF_API_FORBIDDEN DNS_MULTIPLE_RECORDS TASK_ALREADY_RUNNING; do
	assert_contains "$js" "$code"
done
assert_contains "$js" 'error_code'
assert_contains "$js" 'ui.addNotification'
assert_contains "$js" 'addDismissibleNotification'
assert_contains "$js" 'testing: true'
assert_contains "$js" '_startPending'

# --- form.Map with five tabs ---
assert_contains "$js" "form.Map('cloudflare-speedtest'"
assert_contains "$js" 'tab('
assert_contains "$js" 'basic'
assert_contains "$js" 'Cloudflare'
# speed test / naming / logs tab labels
assert_contains "$js" '测速'
assert_contains "$js" '命名'
assert_contains "$js" '日志'

# --- numeric datatypes matching config.sh ranges ---
assert_contains "$js" 'uinteger'
assert_contains "$js" 'and(uinteger,min(1),max(24))'   # interval_hours
assert_contains "$js" 'and(uinteger,min(0),max(3600))' # startup_delay
assert_contains "$js" 'and(uinteger,min(1),max(100))'  # threads
assert_contains "$js" 'and(uinteger,min(1),max(20))'   # attempts
assert_contains "$js" 'and(uinteger,min(1),max(50))'   # download_count
assert_contains "$js" 'and(uinteger,min(1),max(120))'  # download_seconds
assert_contains "$js" 'and(uinteger,min(1),max(65535))' # port
assert_contains "$js" 'and(uinteger,min(30),max(7200))' # task_timeout
assert_contains "$js" 'and(min(1),max(10000))'         # max_latency_ms
assert_contains "$js" 'and(min(0),max(1))'             # max_loss_ratio
assert_contains "$js" 'min(0)'                         # min_speed_mbps

# --- orange-cloud proxying disabled explanation ---
assert_contains "$js" '灰云'
assert_contains "$js" '橙云'

# --- last_tested vs last_published ---
assert_contains "$js" 'last_tested'
assert_contains "$js" 'last_published'
assert_contains "$js" 'network_cache'
assert_contains "$js" 'localNetwork'
assert_contains "$js" 'formatLocalGeo'
assert_contains "$js" 'city_override'
assert_contains "$js" 'isp_override'
assert_contains "$js" 'fallback_city'
assert_contains "$js" 'fallback_isp'
assert_contains "$js" '\u81ea\u52a8\u8bc6\u522b\u57ce\u5e02'
assert_contains "$js" '\u57ce\u5e02\u8986\u76d6'
assert_contains "$js" '\u8fd0\u8425\u5546\u8986\u76d6'
assert_contains "$js" '\u56de\u9000\u57ce\u5e02\u4ee3\u7801'
assert_contains "$js" '\u56de\u9000\u8fd0\u8425\u5546\u4ee3\u7801'

# --- logs: bounded + clear_logs only (no arbitrary file/shell) ---
assert_contains "$js" 'clear_logs'
assert_contains "$js" '65536'
# Logs panel present
assert_contains "$js" 'logs'

# --- forbidden patterns ---
printf '%s\n' "$js" | grep -F 'fetch(' >/dev/null 2>&1 \
	&& fail 'overview.js must not use fetch('
printf '%s\n' "$js" | grep -E 'https?://' >/dev/null 2>&1 \
	&& fail 'overview.js must not contain external URLs'
printf '%s\n' "$js" | grep -F 'localStorage' >/dev/null 2>&1 \
	&& fail 'overview.js must not use localStorage'
printf '%s\n' "$js" | grep -F 'sessionStorage' >/dev/null 2>&1 \
	&& fail 'overview.js must not use sessionStorage'
printf '%s\n' "$js" | grep -F 'fs.exec' >/dev/null 2>&1 \
	&& fail 'overview.js must not use fs.exec'
printf '%s\n' "$js" | grep -E "(L\.fs|'require fs'|require fs)" >/dev/null 2>&1 \
	&& fail 'overview.js must not use fs module'
# Direct shell / system exec patterns
printf '%s\n' "$js" | grep -E '(exec\(|system\(|/bin/sh|shell\.|uci\.exec)' >/dev/null 2>&1 \
	&& fail 'overview.js must not invoke shell/exec directly'

# --- menu contract ---
assert_contains "$menu" 'admin/services/cloudflare-speedtest'
assert_contains "$menu" 'Cloudflare 优选 IP'
assert_contains "$menu" '"order": 60'
assert_contains "$menu" '"action"'
assert_contains "$menu" '"type": "view"'
assert_contains "$menu" 'cloudflare-speedtest/overview'
assert_contains "$menu" 'luci-app-cloudflare-speedtest'
# ACL group dependency
assert_contains "$menu" 'depends'
assert_contains "$menu" 'acl'

# --- Makefile / luci.mk packaging ---
assert_contains "$mk" 'luci.mk'
assert_contains "$mk" 'luci-app-cloudflare-speedtest'
assert_contains "$mk" '+luci-base'
assert_contains "$mk" '+rpcd'
assert_contains "$mk" '+cloudflare-speedtest'
assert_contains "$mk" 'LUCI_TITLE'
assert_contains "$mk" 'LUCI_DEPENDS'

printf 'OK: luci dashboard contracts\n'
