# 直连测速、旧 IP 复测与节点归属显示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让测速流量绕过路由器上的透明代理以取得真实延迟与速度，把上一轮的测速/发布 IP 复测后并入结果表并对已发布 IP 做粘滞选择，界面显示两个时间戳与 colo 中文归属。

**Architecture:** cfst 改由 `start-stop-daemon -c cfst` 以专用 uid 运行，独立 nftables 表给该 uid 的出站包打 `mark 0xff`，passwall2 现有的 `meta mark 0x000000ff ... return` 规则据此放行直连。测速阶段前先对 state 里的旧 IP 单独跑一次完整测速，产出的行与主测速结果合并成 `combined.csv` 后统一优选，选择时对已发布 IP 施加百分比粘滞。colo 中文名在 runner 写 state 时查表落库，前端只做展示与回退。

**Tech Stack:** BusyBox ash、awk、nftables、start-stop-daemon、OpenWrt UCI/procd、LuCI JS (form + rpcd ubus)。

**Spec:** `docs/superpowers/specs/2026-08-21-direct-speedtest-and-recheck-design.md`

**约定:** 仓库全部脚本必须是 LF 换行；`tests/run.sh` 是唯一测试入口，运行方式 `sh tests/run.sh`；单独跑某个文件需要 `CFST_ROOT="$PWD" sh tests/unit/<name>.sh`。

---

## File Structure

新建文件

- `package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv` — colo 代码到中文名的两列映射表，唯一数据源。
- `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh` — 只做一件事：查 colos.tsv。
- `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh` — 只做一件事：装/拆直连 nftables 规则并回答 cfst 该以哪个用户运行。
- `tests/unit/test_colo.sh`、`tests/unit/test_direct.sh` — 对应单元测试。
- `tests/helpers/mock-bin/nft`、`tests/helpers/mock-bin/start-stop-daemon` — 记录 argv 的桩。

修改文件

- `result.sh` — `select_best_result` 增加粘滞参数；新增 `result_merge_csv` 合并两份 CSV。
- `runner.sh` — 测速阶段包上 direct_enable/disable；新增复测段；改为合并后再优选。
- `config.sh`、`files/etc/config/cloudflare-speedtest`、`files/etc/uci-defaults/90-cloudflare-speedtest` — 两个新选项。
- `package/cloudflare-speedtest/Makefile` — 安装新文件、新增 postinst 建用户。
- `overview.js` — 两个时间戳行、colo 归属、两个表单项。

---

### Task 1: colo 代码查中文名

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv`
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh`
- Create: `tests/unit/test_colo.sh`
- Modify: `tests/run.sh`

- [ ] **Step 1: 写失败的测试**

`tests/unit/test_colo.sh`：

```sh
#!/bin/sh
# colo code to Chinese datacenter name lookup.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

COLO_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh"
assert_file_exists "$COLO_SH"
export CFST_COLOS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh
. "$COLO_SH"

assert_eq "$(colo_chinese_name LAX)" '美国 洛杉矶'
assert_eq "$(colo_chinese_name FRA)" '德国 法兰克福'
assert_eq "$(colo_chinese_name AMS)" '荷兰 阿姆斯特丹'
assert_eq "$(colo_chinese_name HKG)" '中国 香港'
# lowercase input is normalised
assert_eq "$(colo_chinese_name sin)" '新加坡'
# unknown, empty and N/A all yield an empty string; callers do the fallback
assert_eq "$(colo_chinese_name ZZZ)" ''
assert_eq "$(colo_chinese_name '')" ''
assert_eq "$(colo_chinese_name 'N/A')" ''
# a missing table must not error out
CFST_COLOS_FILE=/nonexistent/colos.tsv
assert_eq "$(colo_chinese_name LAX)" ''

printf 'colo tests passed\n'
```

- [ ] **Step 2: 运行确认失败**

Run: `cd <repo> && CFST_ROOT="$PWD" sh tests/unit/test_colo.sh`
Expected: FAIL，提示 `colo.sh` 不存在（`assert_file_exists` 失败）。

- [ ] **Step 3: 建映射表**

`colos.tsv`，两列以单个 tab 分隔，`#` 开头为注释。收录中国大陆常见落地机房与各洲主要节点；未收录的由调用方回退成原始代码。

```
# Cloudflare colo code -> Chinese name. Tab separated. Not exhaustive.
HKG	中国 香港
TPE	中国 台北
NRT	日本 东京
KIX	日本 大阪
ICN	韩国 首尔
SIN	新加坡
KUL	马来西亚 吉隆坡
BKK	泰国 曼谷
MNL	菲律宾 马尼拉
CGK	印尼 雅加达
BOM	印度 孟买
MAA	印度 金奈
DEL	印度 新德里
DXB	阿联酋 迪拜
TLV	以色列 特拉维夫
IST	土耳其 伊斯坦布尔
SYD	澳大利亚 悉尼
MEL	澳大利亚 墨尔本
AKL	新西兰 奥克兰
LAX	美国 洛杉矶
SJC	美国 圣何塞
SEA	美国 西雅图
DEN	美国 丹佛
DFW	美国 达拉斯
ORD	美国 芝加哥
IAD	美国 阿什本
EWR	美国 纽瓦克
ATL	美国 亚特兰大
MIA	美国 迈阿密
YYZ	加拿大 多伦多
YVR	加拿大 温哥华
MEX	墨西哥 墨西哥城
GRU	巴西 圣保罗
EZE	阿根廷 布宜诺斯艾利斯
SCL	智利 圣地亚哥
LHR	英国 伦敦
MAN	英国 曼彻斯特
AMS	荷兰 阿姆斯特丹
FRA	德国 法兰克福
MUC	德国 慕尼黑
DUS	德国 杜塞尔多夫
CDG	法国 巴黎
MRS	法国 马赛
MAD	西班牙 马德里
BCN	西班牙 巴塞罗那
MXP	意大利 米兰
FCO	意大利 罗马
ZRH	瑞士 苏黎世
VIE	奥地利 维也纳
ARN	瑞典 斯德哥尔摩
CPH	丹麦 哥本哈根
OSL	挪威 奥斯陆
HEL	芬兰 赫尔辛基
WAW	波兰 华沙
PRG	捷克 布拉格
BUD	匈牙利 布达佩斯
OTP	罗马尼亚 布加勒斯特
SOF	保加利亚 索非亚
ATH	希腊 雅典
LIS	葡萄牙 里斯本
DUB	爱尔兰 都柏林
KIV	摩尔多瓦 基希讷乌
JNB	南非 约翰内斯堡
CPT	南非 开普敦
LOS	尼日利亚 拉各斯
NBO	肯尼亚 内罗毕
CAI	埃及 开罗
```

- [ ] **Step 4: 实现 colo.sh**

```sh
#!/bin/sh
# Cloudflare colo code -> Chinese datacenter name.
#
# The table is a curated subset, not Cloudflare's full colo list. An unknown
# code returns an empty string; callers fall back to showing the raw code.

: "${CFST_COLOS_FILE:=/usr/share/cloudflare-speedtest/colos.tsv}"

colo_chinese_name() {
    code="$1"
    case "$code" in
        ''|'N/A'|*[!A-Za-z]*) return 0 ;;
    esac
    [ -f "$CFST_COLOS_FILE" ] || return 0
    printf '%s\n' "$code" | awk -v table="$CFST_COLOS_FILE" '
        {
            wanted = toupper($0)
            while ((getline line < table) > 0) {
                if (line ~ /^#/ || line == "") continue
                split(line, field, "\t")
                if (toupper(field[1]) == wanted) {
                    printf "%s", field[2]
                    break
                }
            }
            close(table)
        }
    '
}
```

`*[!A-Za-z]*` 同时挡掉了 `N/A` 之外的脏值，所以三位字母之外的输入一律返回空。

- [ ] **Step 5: 注册到测试入口**

在 `tests/run.sh` 的单元测试列表里加上 `test_colo.sh`。先看清该文件是显式列举还是通配目录：

Run: `grep -n "unit" tests/run.sh`

若是显式列举就按字母序插入 `tests/unit/test_colo.sh`；若已是 `tests/unit/*.sh` 通配则无需改动。

- [ ] **Step 6: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_colo.sh`
Expected: `colo tests passed`

Run: `sh tests/run.sh`
Expected: 全部通过，无 `FAIL` 行。

- [ ] **Step 7: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv \
        package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/colo.sh \
        tests/unit/test_colo.sh tests/run.sh
git commit -m "feat: add colo code to Chinese datacenter name lookup"
```

---

### Task 2: state 落库 colo_name

**Files:**
- Modify: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh`
- Modify: `package/cloudflare-speedtest/Makefile`
- Test: `tests/integration/test_runner.sh`

- [ ] **Step 1: 写失败的断言**

`tests/integration/test_runner.sh` 的 `reset_env()` 里，紧跟现有 `CFST_PROVIDERS_FILE` 那行加上：

```sh
    export CFST_COLOS_FILE="$CFST_ROOT/package/cloudflare-speedtest/files/usr/share/cloudflare-speedtest/colos.tsv"
```

在已有的 `--- test-only:` 用例里，`assert_eq "$status" "0"` 之后追加（`valid.csv` 的胜者 `104.18.2.10` 的 colo 是 `HKG`）：

```sh
# The Chinese colo name is resolved at test time and stored in state, so the
# frontend never has to read a data file.
st_state="$(state_text)"
assert_contains "$st_state" '"colo":"HKG"'
assert_contains "$st_state" '"colo_name":"中国 香港"'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/integration/test_runner.sh`
Expected: FAIL，缺少 `"colo_name":"中国 香港"`。

- [ ] **Step 3: runner 里 source colo.sh**

`runner_source_libs()` 中，`. "$CFST_LIB_DIR/result.sh"` 之后插入：

```sh
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/colo.sh"
```

- [ ] **Step 4: 两个 builder 写入 colo_name**

`runner_build_tested_json()` 中 `escaped_colo="$(json_escape "$colo")"` 之后插入：

```sh
    escaped_colo_name="$(json_escape "$(colo_chinese_name "$colo")")"
```

同一函数的两条 `printf` 都在 `\"colo\":\"%s\"` 之后插入 `,\"colo_name\":\"%s\"`，并在参数表中把 `"$escaped_colo"` 后面紧跟 `"$escaped_colo_name"`。改完后有 hostname 那条形如：

```sh
        printf '{"ip":"%s","latency_ms":%s,"loss_ratio":%s,"speed_mbps":%s,"colo":"%s","colo_name":"%s","hostname":"%s"%s}' \
            "$escaped_ip" "$latency" "$loss" "$speed" "$escaped_colo" "$escaped_colo_name" "$escaped_host" "$suffix"
```

`runner_build_published_json()` 做同样的三处改动：加一行 `escaped_colo_name`，`printf` 格式串里 `"colo":"%s"` 后加 `,"colo_name":"%s"`，参数表里 `"$escaped_colo"` 后加 `"$escaped_colo_name"`。

- [ ] **Step 5: Makefile 安装新文件**

`package/cloudflare-speedtest/Makefile` 的 `Package/cloudflare-speedtest/install` 里，`ip.txt` 那行之后加：

```make
	$(INSTALL_DATA) ./files/usr/share/cloudflare-speedtest/colos.tsv $(1)/usr/share/cloudflare-speedtest/
```

`colo.sh` 与 `direct.sh` 不需要单独加行——现有规则已是 `$(INSTALL_BIN) ./files/usr/libexec/cloudflare-speedtest/*.sh`，通配符会带上它们。

- [ ] **Step 6: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/integration/test_runner.sh`
Expected: `OK runner integration`

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 7: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh \
        package/cloudflare-speedtest/Makefile tests/integration/test_runner.sh
git commit -m "feat: store the Chinese colo name in state at test time"
```

---

### Task 3: 界面显示两个时间戳与 colo 归属

**Files:**
- Modify: `package/luci-app-cloudflare-speedtest/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js`
- Test: `tests/unit/test_luci.sh`

- [ ] **Step 1: 写失败的断言**

`tests/unit/test_luci.sh` 末尾的 `printf 'OK: luci dashboard contracts\n'` 之前插入：

```sh
# 优选节点 block must expose both timestamps and a colo-based ownership field.
assert_contains "$js" 'cfst-last-tested-at'
assert_contains "$js" 'cfst-last-published-at'
assert_contains "$js" '最近测速时间'
assert_contains "$js" '最近发布时间'
assert_contains "$js" 'function formatColo'
# The anycast registration address is misleading, so formatGeo must no longer
# drive the node ownership field.
printf '%s\n' "$js" | grep -F "formatGeo(preferredNode)" >/dev/null \
    && fail 'node ownership must use formatColo, not formatGeo'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_luci.sh`
Expected: FAIL，缺少 `cfst-last-tested-at`。

- [ ] **Step 3: 加 formatColo 与 fmtNodeTime**

`overview.js` 中 `formatGeo` 函数之后插入这两个函数。`formatGeo` 本身保留——`地区与 DNS` 卡片仍在用它。`fmtDateTime` 对空值返回「未安排」，那是给下次任务用的措辞，节点时间戳需要自己的空值表现：

```js
/* Node ownership comes from the colo the download actually landed in. The
 * ipinfo region of an anycast address is a registration address and does not
 * describe the datacenter, so it must not be used here. colo_name is written
 * into state at test time; state files from older versions lack it. */
function formatColo(obj) {
	if (!obj || typeof obj !== 'object')
		return _('未知');
	var code = String(obj.colo || '').trim();
	if (code === '' || code === 'N/A')
		return _('未知');
	var name = String(obj.colo_name || '').trim();
	return name ? code + ' / ' + name : code;
}

function fmtNodeTime(v) {
	if (v === null || v === undefined || v === '')
		return '—';
	return fmtDateTime(v);
}
```

- [ ] **Step 4: 卡片里加两行时间并换掉归属**

`renderStatusCards` 的 `cardNode` 中，`最近测速 IP` 那个 `cbi-value` 之后插入：

```js
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('最近测速时间')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-last-tested-at' }, fmtNodeTime(tested.tested_at))
		]),
```

`最近发布 IP` 那个 `cbi-value` 之后插入：

```js
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('最近发布时间')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-last-published-at' }, fmtNodeTime(published.published_at))
		]),
```

同一个 `cardNode` 里把归属那行的 `formatGeo(preferred)` 改成 `formatColo(preferred)`。

- [ ] **Step 5: 轮询更新同步**

`updateCardDom` 中 `setText('cfst-last-tested-ip', ...)` 之后加：

```js
	setText('cfst-last-tested-at', fmtNodeTime(tested.tested_at));
```

`setText('cfst-last-published-ip', ...)` 之后加：

```js
	setText('cfst-last-published-at', fmtNodeTime(published.published_at));
```

并把下面这两行

```js
	var preferredNode = published.region || published.city || published.isp ? published : tested;
	setText('cfst-preferred-geo', formatGeo(preferredNode));
```

替换为

```js
	var preferredNode = published.colo ? published : tested;
	setText('cfst-preferred-geo', formatColo(preferredNode));
```

- [ ] **Step 6: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_luci.sh`
Expected: `OK: luci dashboard contracts`

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 7: 提交**

```bash
git add package/luci-app-cloudflare-speedtest/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js \
        tests/unit/test_luci.sh
git commit -m "feat: show node timestamps and colo-based ownership on the dashboard"
```

---

### Task 4: 两个新 UCI 选项

**Files:**
- Modify: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh`
- Modify: `package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest`
- Modify: `package/cloudflare-speedtest/files/etc/uci-defaults/90-cloudflare-speedtest`
- Modify: `package/luci-app-cloudflare-speedtest/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js`
- Test: `tests/unit/test_config.sh`, `tests/unit/test_luci.sh`

- [ ] **Step 1: 写失败的测试**

`tests/unit/test_config.sh` 中默认值断言那一组（`assert_eq "$CFST_TEST_ALL" "0"` 附近）追加：

```sh
assert_eq "$CFST_DIRECT_MODE" "1"
assert_eq "$CFST_PUBLISH_SWITCH_MARGIN" "20"
```

同文件里照现有校验非法值的写法追加两组（先看一处现成例子确认变量名与 set +e 用法）：

```sh
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
```

`tests/unit/test_luci.sh` 末尾 `printf 'OK:` 之前追加：

```sh
assert_contains "$js" "'direct_mode'"
assert_contains "$js" "'publish_switch_margin'"
assert_contains "$js" 'and(uinteger,min(0),max(100))'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_config.sh`
Expected: FAIL，`CFST_DIRECT_MODE` 为空而非 `1`。

- [ ] **Step 3: config.sh 读取与校验**

`load_config()` 中 `CFST_TEST_ALL=` 那行之后加：

```sh
    CFST_DIRECT_MODE="$(cfst_config_get test direct_mode 1)"
    CFST_PUBLISH_SWITCH_MARGIN="$(cfst_config_get test publish_switch_margin 20)"
```

`validate_base_config()` 中 `CONFIG_TEST_ALL_INVALID` 那个 `case` 之后加：

```sh
    case "$CFST_DIRECT_MODE" in
        0|1) : ;;
        *) set_config_error CONFIG_DIRECT_MODE_INVALID '直连测速必须为 0 或 1'; return $? ;;
    esac
    validate_uint_range "$CFST_PUBLISH_SWITCH_MARGIN" 0 100 CONFIG_SWITCH_MARGIN_INVALID '切换阈值必须为 0 到 100' || return $?
```

- [ ] **Step 4: 默认配置与 uci-defaults**

`files/etc/config/cloudflare-speedtest` 的 `config test 'test'` 段内，`option test_all` 之后加：

```
        option direct_mode '1'
        option publish_switch_margin '20'
```

`files/etc/uci-defaults/90-cloudflare-speedtest` 中 `ensure_option test test_all 0` 之后加：

```sh
ensure_option test direct_mode 1
ensure_option test publish_switch_margin 20
```

- [ ] **Step 5: 界面表单项**

`overview.js` 中 `test_all` 那个 `form.Flag` 之后插入：

```js
	o = s.taboption('speedtest', form.Flag, 'direct_mode', _('测速走直连'));
	o.ucisection = 'test';
	o.default = '1';
	o.description = _('给测速进程的流量打 0xff 标记，绕过 passwall2 等透明代理。关闭后延迟测的是本地代理的响应时间，结果不可信。');

	o = s.taboption('speedtest', form.Value, 'publish_switch_margin', _('切换阈值（%）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(0),max(100))';
	o.default = '20';
	o.description = _('已发布 IP 复测仍合格时，新 IP 速度需高出该百分比才替换，用于减少 DNS 抖动。0 表示总是取最快。');
```

- [ ] **Step 6: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_config.sh && CFST_ROOT="$PWD" sh tests/unit/test_luci.sh`
Expected: 两个都无输出或输出各自的 OK 行，无 `FAIL`。

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 7: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh \
        package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest \
        package/cloudflare-speedtest/files/etc/uci-defaults/90-cloudflare-speedtest \
        package/luci-app-cloudflare-speedtest/htdocs/luci-static/resources/view/cloudflare-speedtest/overview.js \
        tests/unit/test_config.sh tests/unit/test_luci.sh
git commit -m "feat: add direct_mode and publish_switch_margin options"
```

---

### Task 5: 发布 IP 粘滞选择

**Files:**
- Modify: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh`
- Test: `tests/unit/test_result.sh`

- [ ] **Step 1: 写失败的测试**

`tests/unit/test_result.sh` 中 `--- result_reject_summary` 那一段之前插入。三行速度分别是 5.00、4.20、4.16 MB/s，`104.20.1.2` 扮演已发布 IP：

```sh
# --- select_best_result: published-IP stickiness ---
cat > "$TMP/sticky.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.1.1,10,10,0.00,40.0,5.00,LAX
104.20.1.2,10,10,0.00,45.0,4.20,FRA
104.20.1.3,10,10,0.00,50.0,4.16,AMS
EOF

# No sticky IP given: the fastest wins, exactly as before.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# 5.00 vs 4.20 is +19.05%, below the 20% bar, so the published IP is kept.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.2'

# 5.00 vs 4.16 is +20.19%, above the bar, so the faster IP takes over.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.3 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# margin 0 always takes the fastest.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 0)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# A sticky IP that is not in the qualified set is ignored.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 203.0.113.9 20)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.1.1'

# The sticky winner keeps its own metrics, not the fastest row's.
selected="$(select_best_result "$TMP/sticky.csv" 200 0.3 1 104.20.1.2 20)"
assert_eq "$selected" '{"ip":"104.20.1.2","latency_ms":45,"loss_ratio":0,"speed_mbps":33.6,"colo":"FRA"}'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_result.sh`
Expected: FAIL，第二个断言得到 `104.20.1.1`——多出来的两个参数目前被忽略。

- [ ] **Step 3: 实现粘滞**

`select_best_result()` 开头的参数区改为：

```sh
select_best_result() {
    file="$1"
    max_latency="$2"
    max_loss="$3"
    min_speed="$4"
    sticky_ip="${5:-}"
    margin_pct="${6:-0}"
```

同函数里那段 awk 的调用改为多传两个变量：

```sh
    best="$(awk -F, -v max_latency="$max_latency" -v max_loss="$max_loss" -v min_speed_mbps="$min_speed" \
        -v sticky_ip="$sticky_ip" -v margin_pct="$margin_pct" "
```

awk 里记录最优行的那段 `if (better) { ... }` 之后、`}` 之前插入对粘滞行的记录：

```awk
            if (sticky_ip != "" && ip == sticky_ip) {
                sticky_found = 1
                sticky_loss = loss
                sticky_latency = latency
                sticky_speed = speed
                sticky_colo = colo
            }
```

`END` 块整体替换为：

```awk
        END {
            if (best_ip == "") exit
            # Keep the currently published IP unless a candidate is faster by
            # more than the configured margin. Speed measurements carry enough
            # noise that always taking the maximum churns the DNS record.
            if (sticky_found && best_ip != sticky_ip &&
                best_speed + 0 <= (sticky_speed + 0) * (1 + (margin_pct + 0) / 100)) {
                printf "%s,%s,%s,%s,%s\n", sticky_ip, sticky_loss, sticky_latency, sticky_speed, sticky_colo
            } else {
                printf "%s,%s,%s,%s,%s\n", best_ip, best_loss, best_latency, best_speed, best_colo
            }
        }
```

同时更新函数上方的注释块，说明第 5、6 个参数可选：

```sh
# select_best_result FILE MAX_LATENCY MAX_LOSS MIN_SPEED [STICKY_IP] [MARGIN_PCT]
# Prints one compact JSON object for the best qualified candidate. When
# STICKY_IP is qualified it is retained unless another candidate exceeds it by
# more than MARGIN_PCT percent.
# Exit 50 RESULT_BAD_CSV or 51 RESULT_NO_QUALIFIED_IP on failure.
```

- [ ] **Step 4: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_result.sh`
Expected: 无输出（该文件通过时不打印内容），退出码 0。

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 5: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh tests/unit/test_result.sh
git commit -m "feat: keep the published IP unless a candidate beats it by the margin"
```

---

### Task 6: 合并两份 CSV

**Files:**
- Modify: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh`
- Test: `tests/unit/test_result.sh`

- [ ] **Step 1: 写失败的测试**

`tests/unit/test_result.sh` 末尾追加：

```sh
# --- result_merge_csv: one header, deduped by IP keeping the faster row ---
cat > "$TMP/merge-main.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.2.1,10,10,0.00,40.0,5.00,LAX
104.20.2.2,10,10,0.00,45.0,1.00,FRA
EOF
cat > "$TMP/merge-recheck.csv" <<'EOF'
IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码
104.20.2.2,10,10,0.00,44.0,9.00,FRA
104.20.2.9,10,10,0.00,60.0,2.00,AMS
EOF
result_merge_csv "$TMP/merged.csv" "$TMP/merge-main.csv" "$TMP/merge-recheck.csv"
assert_eq "$(awk 'END { print NR }' "$TMP/merged.csv")" '4'
assert_eq "$(awk 'NR==1' "$TMP/merged.csv")" 'IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码'
# 104.20.2.2 appears once, with the faster recheck row
assert_eq "$(grep -c '^104\.20\.2\.2,' "$TMP/merged.csv")" '1'
assert_contains "$(cat "$TMP/merged.csv")" '104.20.2.2,10,10,0.00,44.0,9.00,FRA'
assert_contains "$(cat "$TMP/merged.csv")" '104.20.2.9,10,10,0.00,60.0,2.00,AMS'

# A missing or empty second input degrades to a copy of the first.
result_merge_csv "$TMP/merged2.csv" "$TMP/merge-main.csv" "$TMP/does-not-exist.csv"
assert_eq "$(awk 'END { print NR }' "$TMP/merged2.csv")" '3'

# Selection over the merged file sees the recheck row.
selected="$(select_best_result "$TMP/merged.csv" 200 0.3 1)"
assert_eq "$(printf '%s' "$selected" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p')" '104.20.2.2'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_result.sh`
Expected: FAIL，`result_merge_csv: not found`。

- [ ] **Step 3: 实现 result_merge_csv**

`result.sh` 中 `select_best_result` 之前插入：

```sh
# result_merge_csv OUT FIRST [SECOND ...]
# Writes one CSV_HEADER line followed by the data rows of every readable input,
# deduplicated by IP keeping the row with the highest speed. Missing or empty
# inputs are skipped. Always exits 0 as long as OUT could be written.
result_merge_csv() {
    out="$1"
    shift
    printf '%s\n' "$CFST_CSV_HEADER" > "$out" || return 1
    for source_file in "$@"; do
        [ -s "$source_file" ] || continue
        awk -F, 'NR > 1 { sub(/\r$/, "", $0); if (NF == 7 && $1 != "") print }' "$source_file"
    done | awk -F, '
        {
            if (!($1 in best) || $6 + 0 > speed[$1] + 0) {
                best[$1] = $0
                speed[$1] = $6
                if (!($1 in seen)) { order[++n] = $1; seen[$1] = 1 }
            }
        }
        END { for (i = 1; i <= n; i++) print best[order[i]] }
    ' >> "$out"
}
```

- [ ] **Step 4: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_result.sh`
Expected: 退出码 0，无 `FAIL`。

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 5: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/result.sh tests/unit/test_result.sh
git commit -m "feat: merge speed test CSVs deduped by IP keeping the faster row"
```

---

### Task 7: 直连规则的装与拆

**Files:**
- Create: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh`
- Create: `tests/unit/test_direct.sh`
- Create: `tests/helpers/mock-bin/nft`
- Modify: `tests/run.sh`

- [ ] **Step 1: 写 nft 桩**

`tests/helpers/mock-bin/nft`，必须 `chmod +x` 并在 git 里保持 100755：

```sh
#!/bin/sh
# Host-test mock for nft. Records argv and obeys a scripted exit code.
set -eu
log_file="${CFST_MOCK_NFT_LOG:-}"
if [ -n "$log_file" ]; then
    { printf 'argv:'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\n'; } >> "$log_file"
fi
if [ -n "${CFST_MOCK_NFT_LIST_OUTPUT:-}" ] && [ "${1:-}" = "list" ]; then
    printf '%s\n' "$CFST_MOCK_NFT_LIST_OUTPUT"
fi
exit "${CFST_MOCK_NFT_EXIT:-0}"
```

- [ ] **Step 2: 写失败的测试**

`tests/unit/test_direct.sh`：

```sh
#!/bin/sh
# Direct-path marking: install/remove the nftables rule and pick the run user.
set -eu
. "$CFST_ROOT/tests/helpers/assert.sh"

DIRECT_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh"
LOG_SH="$CFST_ROOT/package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh"
assert_file_exists "$DIRECT_SH"

TMP="${TMPDIR:-/tmp}/cfst-direct-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
export CFST_LOG_FILE="$TMP/plugin.log"
export PATH="$CFST_ROOT/tests/helpers/mock-bin:$PATH"
export CFST_MOCK_NFT_LOG="$TMP/nft.args"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/log.sh
. "$LOG_SH"
# shellcheck source=../../package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh
. "$DIRECT_SH"

# --- disabled by config: no nft calls, cfst runs as root ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=0
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
direct_enable
assert_eq "$(wc -c < "$CFST_MOCK_NFT_LOG" | tr -d ' ')" '0'
assert_eq "$(direct_run_user)" ''

# --- enabled with a resolvable user: table, chain and rule are created ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_MODE=1
CFST_DIRECT_USER=nobody
direct_enable
args="$(tr -d '\r' < "$CFST_MOCK_NFT_LOG")"
assert_contains "$args" 'add table inet cfst_direct'
assert_contains "$args" 'add chain inet cfst_direct mark_out'
assert_contains "$args" 'meta skuid'
assert_contains "$args" 'meta mark set 0x000000ff'
assert_eq "$(direct_run_user)" 'nobody'

# --- idempotent: a second enable must not add a second rule ---
: > "$CFST_MOCK_NFT_LOG"
direct_enable
assert_eq "$(grep -c 'add rule' "$CFST_MOCK_NFT_LOG" || true)" '0'

# --- disable removes the whole table ---
: > "$CFST_MOCK_NFT_LOG"
direct_disable
assert_contains "$(cat "$CFST_MOCK_NFT_LOG")" 'delete table inet cfst_direct'

# --- unknown user: degrade to root, warn, no rule ---
: > "$CFST_MOCK_NFT_LOG"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=cfst-does-not-exist
CFST_DIRECT_UID=''
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode user missing'

# --- nft missing: degrade quietly, no crash ---
: > "$CFST_LOG_FILE"
CFST_DIRECT_STATE=''
CFST_DIRECT_USER=nobody
CFST_DIRECT_UID=65534
CFST_NFT_BIN=/nonexistent/nft
direct_enable
assert_eq "$(direct_run_user)" ''
assert_contains "$(cat "$CFST_LOG_FILE")" 'direct_mode nft unavailable'

printf 'direct tests passed\n'
```

- [ ] **Step 3: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_direct.sh`
Expected: FAIL，`direct.sh` 不存在。

- [ ] **Step 4: 实现 direct.sh**

```sh
#!/bin/sh
# shellcheck disable=SC2034
# Keep speed test traffic off the local transparent proxy.
#
# A transparent proxy that redirects all outbound TCP answers the TCP handshake
# locally, so cfst measures the proxy's accept time (~1 ms) instead of the real
# RTT and the download reports 0.00 MB/s with no colo. passwall2 keeps a
# `meta mark 0x000000ff ... return` rule for its own loop prevention; marking
# cfst's sockets with the same value is enough to be let out directly.
#
# The rule matches the dedicated uid only, so nothing else on the router
# changes behaviour while a test runs.

: "${CFST_NFT_BIN:=nft}"
: "${CFST_DIRECT_USER:=cfst}"
: "${CFST_DIRECT_TABLE:=cfst_direct}"
: "${CFST_DIRECT_MARK:=0x000000ff}"
# CFST_DIRECT_UID lets the host test suite skip the /etc/passwd lookup; on a
# router it stays unset and the uid is resolved from CFST_DIRECT_USER.

CFST_DIRECT_STATE=''

_direct_nft() {
    command -v "$CFST_NFT_BIN" >/dev/null 2>&1 || return 1
    "$CFST_NFT_BIN" "$@" >/dev/null 2>&1
}

# Prints the user cfst must run as, or nothing when it must stay root.
direct_run_user() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    printf '%s' "$CFST_DIRECT_USER"
}

direct_enable() {
    [ "${CFST_DIRECT_MODE:-1}" = "1" ] || return 0
    [ "${CFST_DIRECT_STATE:-}" != "active" ] || return 0

    if ! command -v "$CFST_NFT_BIN" >/dev/null 2>&1; then
        cfst_log warn 'direct_mode nft unavailable; speed test stays on the default path'
        return 0
    fi

    uid="${CFST_DIRECT_UID:-$(id -u "$CFST_DIRECT_USER" 2>/dev/null || true)}"
    case "$uid" in
        ''|*[!0-9]*)
            cfst_log warn "direct_mode user missing ($CFST_DIRECT_USER); speed test stays on the default path"
            return 0
            ;;
    esac

    _direct_nft add table inet "$CFST_DIRECT_TABLE" || {
        cfst_log warn 'direct_mode could not create the nftables table'
        return 0
    }
    _direct_nft add chain inet "$CFST_DIRECT_TABLE" mark_out \
        '{ type route hook output priority mangle ; policy accept ; }' || {
        cfst_log warn 'direct_mode could not create the nftables chain'
        _direct_nft delete table inet "$CFST_DIRECT_TABLE"
        return 0
    }
    _direct_nft add rule inet "$CFST_DIRECT_TABLE" mark_out \
        meta skuid "$uid" meta mark set "$CFST_DIRECT_MARK" || {
        cfst_log warn 'direct_mode could not install the marking rule'
        _direct_nft delete table inet "$CFST_DIRECT_TABLE"
        return 0
    }

    CFST_DIRECT_STATE=active
    cfst_log info "direct_mode active user=$CFST_DIRECT_USER uid=$uid mark=$CFST_DIRECT_MARK"
    return 0
}

direct_disable() {
    [ "${CFST_DIRECT_STATE:-}" = "active" ] || return 0
    CFST_DIRECT_STATE=''
    _direct_nft delete table inet "$CFST_DIRECT_TABLE" || true
    return 0
}
```

`direct_enable` 只要没能装上规则就把 `CFST_DIRECT_STATE` 留空，于是 `direct_run_user` 返回空、cfst 继续以 root 运行，任务不会失败。

- [ ] **Step 5: 注册测试并确认通过**

在 `tests/run.sh` 的单元测试列表里加 `test_direct.sh`（若已是通配则跳过）。桩要可执行：

```bash
chmod +x tests/helpers/mock-bin/nft
git update-index --add --chmod=+x tests/helpers/mock-bin/nft
```

Run: `CFST_ROOT="$PWD" sh tests/unit/test_direct.sh`
Expected: `direct tests passed`

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 6: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/direct.sh \
        tests/unit/test_direct.sh tests/helpers/mock-bin/nft tests/run.sh
git commit -m "feat: mark speed test sockets so a transparent proxy lets them out directly"
```

---

### Task 8: runner 接入直连与复测

**Files:**
- Modify: `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh`
- Create: `tests/helpers/mock-bin/start-stop-daemon`
- Test: `tests/integration/test_runner.sh`

- [ ] **Step 1: 写 start-stop-daemon 桩**

`tests/helpers/mock-bin/start-stop-daemon`，需要 100755。它把 `-x <prog> -- <args>` 还原成直接调用，从而继续命中已有的 cfst 桩：

```sh
#!/bin/sh
# Host-test mock for start-stop-daemon. Records argv, then execs the -x program
# with everything after the -- separator.
set -eu
log_file="${CFST_MOCK_SSD_LOG:-}"
if [ -n "$log_file" ]; then
    { printf 'argv:'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\n'; } >> "$log_file"
fi
program=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -x) program="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
[ -n "$program" ] || exit 2
exec "$program" "$@"
```

- [ ] **Step 2: 写失败的断言**

`tests/integration/test_runner.sh` 的 `reset_env()` 里加：

```sh
    export CFST_MOCK_NFT_LOG="$TMP/nft.args"
    export CFST_MOCK_SSD_LOG="$TMP/ssd.args"
    : > "$TMP/nft.args"
    : > "$TMP/ssd.args"
    export CFST_DIRECT_USER=nobody
    # Git Bash has no nobody account, so hand direct.sh the uid directly.
    export CFST_DIRECT_UID=65534
```

新增用例，放在现有 `--- no qualified result ---` 之前：

```sh
# --- direct mode: rule installed before testing, removed after, cfst dropped
#     to the dedicated user, and the previous IPs are rechecked first ---
reset_env
printf '%s\n' 'cloudflare-speedtest.test.direct_mode=1' >> "$CFST_TEST_UCI_FILE"
cat > "$CFST_STATE_FILE" <<'EOF'
{"schema_version":1,"last_published":{"ip":"104.18.2.10","published_at":1700000000},"last_tested":{"ip":"104.18.1.1","tested_at":1700000000},"geo_cache":null,"managed_record":null,"network_cache":null}
EOF
set +e
run_cli run --mode test-only --trigger manual
status="$?"
set -e
assert_eq "$status" "0"
nft_args="$(tr -d '\r' < "$TMP/nft.args")"
assert_contains "$nft_args" 'add table inet cfst_direct'
assert_contains "$nft_args" 'delete table inet cfst_direct'
assert_contains "$(tr -d '\r' < "$TMP/ssd.args")" '-c nobody'
log_text="$(tr -d '\r' < "$CFST_LOG_FILE")"
assert_contains "$log_text" 'recheck candidates=2'
# The recheck must run before the main pass.
recheck_line="$(grep -n 'recheck candidates=' "$CFST_LOG_FILE" | head -1 | cut -d: -f1)"
testing_line="$(grep -n 'phase=testing$' "$CFST_LOG_FILE" | head -1 | cut -d: -f1)"
[ "$recheck_line" -gt "$testing_line" ] || fail 'recheck must be logged inside the testing phase'
assert_contains "$log_text" 'select sticky'
```

- [ ] **Step 3: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/integration/test_runner.sh`
Expected: FAIL，`nft.args` 里没有 `add table inet cfst_direct`。

- [ ] **Step 4: source direct.sh 并让 cfst 降权运行**

`runner_source_libs()` 中 `. "$CFST_LIB_DIR/colo.sh"` 之后加：

```sh
    # shellcheck source=/dev/null
    . "$CFST_LIB_DIR/direct.sh"
```

`runner_run_cfst()` 里，四条 `"$CFST_CFST_BIN" ...` 分支现在要么以 root、要么经 `start-stop-daemon` 启动。与其复制四份，在四个分支之前先算出启动前缀，并把四条命令的 `"$CFST_CFST_BIN"` 换成 `$launcher "$CFST_CFST_BIN"`：

```sh
    # Discrete argument lists are kept below; only the launcher varies. The
    # words in $launcher come from a validated user name, never user input.
    launcher=''
    run_user="$(direct_run_user)"
    if [ -n "$run_user" ]; then
        chown "$run_user" "$prepared_ip" 2>/dev/null || true
        chown "$run_user" "${CFST_TASK_DIR:-/tmp}" 2>/dev/null || true
        launcher="start-stop-daemon -S -c $run_user -x"
    fi
```

四条分支里把

```sh
        "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
```

改成

```sh
        # shellcheck disable=SC2086
        $launcher "$CFST_CFST_BIN" -f "$prepared_ip" -o "$out_file" -p 0 \
```

`$launcher` 必须不加引号才能拆成多个词；为空时该行退化成原来的直接调用。

- [ ] **Step 5: 测速阶段包上 direct_enable / direct_disable**

`run_task()` 中 `state_set_phase testing '正在测速'` 之前插入：

```sh
    CFST_DIRECT_USER="${CFST_DIRECT_USER:-cfst}"
    direct_enable
```

`runner_cleanup()` 的开头插入，保证任务被杀也不留规则：

```sh
    direct_disable 2>/dev/null || true
```

主测速之后、`--- validating_result ---` 之前插入：

```sh
    direct_disable
```

- [ ] **Step 6: 复测旧 IP**

`run_task()` 中 `direct_enable` 之后、`ip_source_abs=` 之前插入：

```sh
    # Recheck the IPs from the previous round before sampling new candidates. A
    # still-usable address keeps the task from failing when this round's sample
    # happens to be bad, and feeds the stickiness comparison later.
    recheck_out=''
    recheck_ips="$CFST_TASK_DIR/recheck.txt"
    : > "$recheck_ips"
    for previous in "$(runner_json_field "${CFST_LAST_TESTED:-}" ip)" \
                    "$(runner_json_field "${CFST_LAST_PUBLISHED:-}" ip)"; do
        [ -n "$previous" ] || continue
        is_ipv4 "$previous" || continue
        grep -qx "$previous" "$recheck_ips" 2>/dev/null && continue
        printf '%s\n' "$previous" >> "$recheck_ips"
    done
    if [ -s "$recheck_ips" ]; then
        recheck_count="$(awk 'END { print NR }' "$recheck_ips")"
        cfst_log info "recheck candidates=$recheck_count"
        state_set_phase testing_recheck "正在复测上轮 IP（$recheck_count）"
        recheck_out="$CFST_TASK_DIR/recheck.csv"
        saved_download_count="$CFST_DOWNLOAD_COUNT"
        CFST_DOWNLOAD_COUNT="$recheck_count"
        set +e
        runner_run_cfst "$recheck_ips" "$recheck_out" 0
        recheck_status=$?
        set -e
        CFST_DOWNLOAD_COUNT="$saved_download_count"
        if [ "$recheck_status" -eq 130 ] || [ "${CFST_CANCELLED:-0}" = "1" ]; then
            state_write_status cancelled 'Task cancelled'
            return 130
        fi
        if [ "$recheck_status" -ne 0 ] || [ ! -s "$recheck_out" ]; then
            cfst_log info 'recheck produced no qualified row'
            recheck_out=''
        fi
    fi
```

注意 `runner_run_cfst` 失败时会调用 `runner_fail` 写入失败状态；复测失败属于正常情况，所以上面把非零返回吞掉，后续 `state_set_phase` 会覆盖状态文件。

- [ ] **Step 7: 合并后再优选，并记录粘滞走向**

`run_task()` 的 `--- validating_result ---` 段里，把现有的

```sh
    best_file="$CFST_TASK_DIR/best.json"
    set +e
    select_best_result "$out_abs" "$CFST_MAX_LATENCY_MS" "$CFST_MAX_LOSS_RATIO" "$CFST_MIN_SPEED_MBPS" > "$best_file"
    result_status=$?
    set -e
```

替换为

```sh
    best_file="$CFST_TASK_DIR/best.json"
    combined_abs="$out_abs"
    if [ -n "$recheck_out" ]; then
        combined_abs="$CFST_TASK_DIR/combined.csv"
        result_merge_csv "$combined_abs" "$out_abs" "$recheck_out"
    fi
    sticky_ip="$(runner_json_field "${CFST_LAST_PUBLISHED:-}" ip)"
    set +e
    select_best_result "$combined_abs" "$CFST_MAX_LATENCY_MS" "$CFST_MAX_LOSS_RATIO" \
        "$CFST_MIN_SPEED_MBPS" "$sticky_ip" "${CFST_PUBLISH_SWITCH_MARGIN:-20}" > "$best_file"
    result_status=$?
    set -e
```

同段里 `result_reject_summary` 那行的 `"$out_abs"` 两处改为 `"$combined_abs"`，让诊断统计的是真正参与优选的文件。

紧随其后、`selected_ip=` 之前插入粘滞日志：

```sh
    selected_ip="$(runner_json_field "$best" ip)"
    if [ -n "$sticky_ip" ] && [ "$selected_ip" = "$sticky_ip" ]; then
        cfst_log info "select sticky kept=$sticky_ip margin=${CFST_PUBLISH_SWITCH_MARGIN:-20}"
    elif [ -n "$sticky_ip" ]; then
        cfst_log info "select sticky switched from=$sticky_ip to=$selected_ip margin=${CFST_PUBLISH_SWITCH_MARGIN:-20}"
    fi
```

原有的 `selected_ip="$(runner_json_field "$best" ip)"` 那行随之删除，避免重复赋值。

- [ ] **Step 8: 运行确认通过**

```bash
chmod +x tests/helpers/mock-bin/start-stop-daemon
git update-index --add --chmod=+x tests/helpers/mock-bin/start-stop-daemon
```

Run: `CFST_ROOT="$PWD" sh tests/integration/test_runner.sh`
Expected: `OK runner integration`

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 9: 提交**

```bash
git add package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/runner.sh \
        tests/helpers/mock-bin/start-stop-daemon tests/integration/test_runner.sh
git commit -m "feat: recheck the previous IPs on the direct path and merge them into selection"
```

---

### Task 9: 安装时创建专用用户

**Files:**
- Modify: `package/cloudflare-speedtest/Makefile`
- Test: `tests/unit/test_package.sh`

- [ ] **Step 1: 写失败的断言**

`tests/unit/test_package.sh` 中 `printf 'OK test_package\n'` 之前插入：

```sh
# --- the dedicated speed test user must be created on install ---
# direct.sh matches this uid in nftables; without the account cfst keeps
# running as root and the direct path silently stops working.
assert_contains "$mk_content" 'define Package/cloudflare-speedtest/postinst'
assert_contains "$mk_content" 'cfst:x:6520:6520'
assert_contains "$mk_content" 'cfst:x:6520:'
assert_contains "$mk_content" '/etc/passwd'
assert_contains "$mk_content" '/etc/group'
```

- [ ] **Step 2: 运行确认失败**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_package.sh`
Expected: FAIL，缺少 `define Package/cloudflare-speedtest/postinst`。

- [ ] **Step 3: 加 postinst**

`package/cloudflare-speedtest/Makefile` 中 `Package/cloudflare-speedtest/install` 之后、`$(eval $(call GoPackage))` 之前插入：

```make
# The speed test runs as this account so nftables can match its traffic by uid.
# Image builds must not touch the host's /etc, hence the IPKG_INSTROOT guard.
define Package/cloudflare-speedtest/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if ! grep -q '^cfst:' /etc/passwd; then
	echo 'cfst:x:6520:6520:cfst:/var:/bin/false' >> /etc/passwd
fi
if ! grep -q '^cfst:' /etc/group; then
	echo 'cfst:x:6520:' >> /etc/group
fi
exit 0
endef
```

Makefile 里 `$$` 才是传给 shell 的 `$`，不要写成单个 `$`。

- [ ] **Step 4: 运行确认通过**

Run: `CFST_ROOT="$PWD" sh tests/unit/test_package.sh`
Expected: `OK test_package`

Run: `sh tests/run.sh`
Expected: 无 `FAIL` 行。

- [ ] **Step 5: 提交**

```bash
git add package/cloudflare-speedtest/Makefile tests/unit/test_package.sh
git commit -m "feat: create the dedicated cfst account on install"
```

---

### Task 10: 真机验收

**Files:** 无代码改动

- [ ] **Step 1: shellcheck**

Run: `make shellcheck`
Expected: 无输出。本机若没有 shellcheck 就跳过，CI 会跑。

- [ ] **Step 2: 部署到路由器**

新增文件必须以 LF 换行送上去，Windows 检出可能是 CRLF。逐个文件先 `tr -d '\r'` 再上传，然后：

```sh
chmod 0755 /usr/libexec/cloudflare-speedtest/*.sh
grep -q '^cfst:' /etc/passwd || echo 'cfst:x:6520:6520:cfst:/var:/bin/false' >> /etc/passwd
grep -q '^cfst:' /etc/group || echo 'cfst:x:6520:' >> /etc/group
for f in /usr/libexec/cloudflare-speedtest/*.sh; do sh -n "$f" || echo "SYNTAX $f"; done
```

- [ ] **Step 3: 跑一次 test-only 并核对**

```sh
/usr/bin/cloudflare-speedtest run --mode test-only --trigger manual
```

逐项确认：

- `nft list tables | grep cfst_direct` 在任务结束后为空。
- 日志有 `direct_mode active user=cfst`、`recheck candidates=`、`select sticky`。
- `/etc/cloudflare-speedtest/state.json` 里 `last_tested` 含 `colo_name`。
- 最新 `result.csv` 的延迟是真实量级（几十到几百毫秒），不再是 1 ms 上下；`地区码` 不是 `N/A`。

若 `result_reject` 显示 `latency_rejected` 占绝大多数，说明真实延迟普遍高于当前「最高延迟」，在界面上调高即可，不改代码默认值。

- [ ] **Step 4: 界面确认**

打开 服务 → Cloudflare 优选 IP，Ctrl+F5。优选节点块应显示两个时间戳与形如 `FRA / 德国 法兰克福` 的归属；测速设置里出现「测速走直连」与「切换阈值（%）」。

---

## 备注

- 直连生效依赖 passwall2 保留 `meta mark 0x000000ff ... return` 规则。若哪天 passwall2 改了这条，`direct_mode` 会静默失效——日志里的延迟又回到 1 ms 级就是信号。
- `mark 0xff` 与多 WAN 方案（如 mwan3）可能撞车。当前路由器的 `ip rule` 只对 `0x50535732` 做策略路由，不受影响；若以后引入 mwan3 需要复核。
- 复测让每轮多花至多 `2 × 单节点下载时间`。








