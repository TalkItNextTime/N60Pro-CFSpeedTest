# N60 Pro CloudflareSpeedTest OpenWrt 插件 — 会话交接

更新时间：2026-08-12（实地安装与 LuCI 路径修复之后）

---

## 1. 项目目标（不变）

为 Netcore N60 Pro（XploreWrt 24.10-SNAPSHOT，`mediatek/filogic`，`aarch64_cortex-a53`，2 GB RAM，512 MB SPI NAND）提供原生 OpenWrt 插件：

- 定时运行 XIU2/CloudflareSpeedTest，选出低延迟、可下载的 Cloudflare IPv4
- 按公网出口识别城市/运营商（如东莞电信 → `dgct`）
- 发布为 Cloudflare **灰云** A 记录（如 `dgct.yourdomain.com`）
- LuCI「服务」菜单单页：状态、配置、手动测速、DNS 更新、停止、日志

仓库：https://github.com/TalkItNextTime/N60Pro-CFSpeedTest.git
上游：https://github.com/XIU2/CloudflareSpeedTest（pin v2.3.5 / commit `65b43aa…`）

规格与计划：

- `docs/superpowers/specs/2026-08-12-n60pro-cloudflare-speedtest-openwrt-design.md`
- `docs/superpowers/plans/2026-08-12-n60pro-cloudflare-speedtest-openwrt.md`
- 实机清单：`docs/acceptance-n60pro.md`

---

## 2. Git 状态（下一会话先核对）

```text
分支: feature/openwrt-plugin-implementation
相对 origin/feature/... : ahead 12（本地未 push）
```

近期关键提交：

```text
a30d78c docs: record N60 Pro field acceptance results
e204243 fix: harden production path from N60 Pro field testing
8eed7c8 docs: add installation and N60 Pro acceptance guide
edb92b6 build: produce verified OpenWrt release artifacts
e548666 feat: add LuCI speed test dashboard
87c1da9 feat: expose safe rpcd management API
…（Task 6–14 均已提交）
```

未提交/未跟踪（注意）：

- `M README.md`、`M LICENSE`、`M tests/unit/test_docs.sh`（文档/许可证小改，可择机整理）
- `?? dist/` — 含本机交叉编译的 ARM64 `cfst`（约 7.7MB），**不要误 commit 大二进制**，除非发布流程明确要求

**不要 push、不要打 tag**，除非用户明确要求。

---

## 3. 已完成（主机）

| 模块 | 状态 |
|------|------|
| Task 1–5 脚手架/config/state/log/lock/naming | 完成并提交 |
| Task 6 GeoIP | 完成；后续实地加固（见 §5） |
| Task 7 result CSV | 完成 |
| Task 8 DNS API | 完成（mock 集成测） |
| Task 9 runner + CLI | 完成；实地加固 |
| Task 10 cron/procd/hotplug | 完成；cksum 回退 |
| Task 11 包 + pin CFST | 完成 |
| Task 12 rpcd + ACL | 完成 |
| Task 13 LuCI overview.js | 完成 |
| Task 14 build/install/CI 脚本 | 完成（Windows 无法跑完整 SDK） |
| Task 15 README + acceptance | 完成 |

主机测试：

- 全量 `sh tests/run.sh` 在 Windows 上易因后台 `sleep 900` 看门狗残留被工具 kill
- 已加 **`CFST_DISABLE_WATCHDOG=1`**（仅测试环境）：`reset_env` 默认开启；超时用例显式 `unset`
- 快速验证可用：`tests/unit/*` + `test_dns` + `test_rpcd` + 手动 debug runner
- 正式 CI 应在 Linux 上跑完整 suite（含超时/取消）

本机 Go 1.26.5 已用于交叉编译：

```text
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build → dist/cfst
GOPROXY=https://goproxy.cn,direct
SHA256 pin 与 upstream/cloudflare-speedtest.version 一致
```

---

## 4. 已完成（路由器实地）

### 4.1 设备与连接

```text
主机: 192.168.6.1
端口: 22
用户: root
密码：（不记录于仓库；使用用户本地保存的密码）
```

本机工具（已下载到用户 Temp，可复用）：

```text
C:\Users\Admin\AppData\Local\Temp\opencode\plink.exe
C:\Users\Admin\AppData\Local\Temp\opencode\pscp.exe
hostkey: SHA256:TjpRkoCTjJUpsn860PfLMcd2u26vIVChkUWSNIxXiTk
```

示例：

```powershell
$plink = "C:\Users\Admin\AppData\Local\Temp\opencode\plink.exe"
$hk = "SHA256:TjpRkoCTjJUpsn860PfLMcd2u26vIVChkUWSNIxXiTk"
& $plink -ssh -P 22 -pw "<ROUTER_PASSWORD>" -hostkey $hk -batch root@192.168.6.1 "ubus call system board"
```

固件：

```text
XploreWrt 24.10-SNAPSHOT r0-b3f5438
mediatek/filogic, aarch64_cortex-a53, kernel 6.6.95
Netcore N60 Pro Modded (2G RAM, SPI NAND 512MB)
```

### 4.2 安装方式（当前）

**不是 opkg IPK**，而是 **文件级安装**（Windows 无 OpenWrt SDK）：

- 最新一次：`/tmp/cfst-install.tgz` + `/tmp/install-on-router.sh`
- 关键点：
  - JS 必须装到 **`/www/luci-static/resources/view/cloudflare-speedtest/overview.js`**
  - 早期错误装到 `/htdocs/...`（已 `rm -rf /htdocs`）
  - ACL 必须在 **`/usr/share/rpcd/acl.d/luci-app-cloudflare-speedtest.json`**（本机固件不从 `/etc/acl.d` 加载）
  - 同时保留 `/etc/acl.d/` 副本无害

安装后应存在：

```text
/usr/bin/cfst
/usr/bin/cloudflare-speedtest
/usr/libexec/cloudflare-speedtest/*.sh
/usr/share/cloudflare-speedtest/{ip.txt,cities.tsv,providers.tsv}
/etc/config/cloudflare-speedtest
/etc/init.d/cloudflare-speedtest
/usr/libexec/rpcd/cloudflare-speedtest
/usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json
/usr/share/rpcd/acl.d/luci-app-cloudflare-speedtest.json
/www/luci-static/resources/view/cloudflare-speedtest/overview.js
```

服务：`/etc/init.d/cloudflare-speedtest enable` + restart；`rpcd` / `uhttpd` 已 restart。

### 4.3 实地功能结果

| 项 | 结果 |
|----|------|
| test-only | **成功**，例：`104.16.1.1` / LAX，有延迟与速度 |
| GeoIP | ipwho.is → 东莞电信 → **`dg`/`ct`** |
| hostname | 配 zone 后 **`dgct.domain.com`** |
| 无 Token 的 test-and-update | **`CONFIG_TOKEN_MISSING`**，不改 DNS |
| Token 脱敏 | logs / `config_summary` 仅 `token_configured` |
| Cron | **`14 */6 * * * ... # cloudflare-speedtest`** |
| CLI validate/status/result | 正常 |
| rpcd list/call | 正常 |

UCI 在最近一次安装中已清成「首配」状态，便于用户在 LuCI 填 Token：

```text
cloudflare.api_token 空
cloudflare.zone 空
main.enabled=1
geo.provider_order='ipwho.is ipapi.co'
```

### 4.4 用户当前意图（重要）

用户要求：

1. **先安装好**（已完成文件级安装 + LuCI 路径修复）
2. **自己在 LuCI 设置页**提交 CF Token、zone 等
3. 提交成功后再通知 AI **继续** DNS 发布与剩余验收

下一会话：**先等用户确认已在页面保存配置**，或 SSH 检查 `uci show cloudflare-speedtest.cloudflare` 是否已有 token/zone；不要擅自要 Token 明文写入仓库。

LuCI 入口（预期）：

```text
http://192.168.6.1  →  服务 → Cloudflare 优选 IP
```

若菜单不可见：再 `rpcd`/`uhttpd` restart，硬刷新浏览器；确认 root 会话 ACL。

---

## 5. 实地修复清单（已进代码 `e204243`）

1. **`ip.txt` 仅裸 IPv4 CIDR** — CFST 不认 `#` 注释；runner 另有 `runner_prepare_ip_file` 防御清洗
2. **runner 传 `-url`** — 使用 UCI `test_url`
3. **超时判定** — 用 `timed_out_flag`，勿把 cfst 立即失败误报为 TIMEOUT
4. **watchdog 用真 `sleep`**，不用 `CFST_SLEEP_CMD`；测试可用 `CFST_DISABLE_WATCHDOG=1`
5. **`schedule_minute`** — 无 `cksum` 时用 `md5sum`/`od`/固定 17
6. **ipwho.is** — `connection.isp` 有时是门牌；像地址时改用 `connection.org`
7. **ISP 映射** — 长 org 子串匹配（alias 长度 ≥ 4），如 `CHINANET Guangdong province network` → `ct`
8. **默认 Geo 顺序** — `ipwho.is` 先于 `ipapi.co`（国内 ipapi 常被 CF 人机页拦）
9. **cities.tsv** — 补东莞 `dg` 等城市
10. **LuCI 安装路径** — `/www/...` + `/usr/share/rpcd/acl.d/`（见 §4.2）

---

## 6. 安全与正确性底线（必须继续遵守）

- Token 不得进命令行参数、进程列表、日志、ubus 明文、LuCI 回显
- 自动化测试不得打真实 Cloudflare API
- 测速/Geo 失败不得改 DNS
- 新记录成功校验后再清旧 managed 记录
- state 损坏禁止自动删历史 DNS
- 多条同名 A 记录停止并人工处理
- 仅 A + 灰云；不做橙云/AAAA
- 外部字符串不可信；禁止 `eval`；正确引用
- 公网/测速请求绕过透明代理；`0.xx ms` 常为代理污染
- 安装不用 `--force-depends`
- 不打版本 tag，除非主机测 + SDK + 实机全过且用户要求

---

## 7. 下一会话建议任务（按优先级）

### P0 — 等用户 LuCI 配置后

1. SSH 确认配置（**不要**把 token 打进 handoff/commit）：
   ```sh
   uci get cloudflare-speedtest.cloudflare.zone
   # token 只查是否非空：
   [ -n "$(uci -q get cloudflare-speedtest.cloudflare.api_token)" ] && echo token_set
   /usr/bin/cloudflare-speedtest validate
   ```
2. 跑：
   ```sh
   /usr/bin/cloudflare-speedtest run --mode test-and-update --trigger manual
   /usr/bin/cloudflare-speedtest result
   /usr/bin/cloudflare-speedtest status
   logread -e cloudflare-speedtest   # 或 tail 插件日志
   nslookup <hostname> 1.1.1.1
   ```
3. 确认灰云 A、managed_record、旧记录清理策略符合设计
4. 更新 `docs/acceptance-n60pro.md` 勾选 DNS 相关项

### P1 — LuCI 交互验收

- 菜单可见、表单保存 UCI、Token 用 set_token/密码框不回显
- 仅测速 / 测速并更新 / 停止 / 日志 / 校验配置
- 轮询状态卡（active 3s / idle 15s）

### P2 — 剩余实地项

- 并发冲突、停止取消、重启持久化、多轮 cron、CPU/内存、卸载重装

### P3 — 正式 IPK 与发布

- 在 **Linux** 或 GitHub Actions 跑：
  ```sh
  sh scripts/build-cfst.sh /tmp/cfst-build
  sh scripts/build-sdk.sh dist
  sha256sum -c dist/SHA256SUMS
  ```
- 用 `opkg install` 两包，验证 uci-defaults、conffiles、卸载行为
- 用户明确要求后再 push / 开 PR / 打 tag

### P4 — 清理

- 决定是否 commit README/LICENSE/test_docs 残留
- `dist/cfst` 是否进 `.gitignore`（建议 ignore，CI 产物不进 git）
- 提醒用户路由器 root 密码已在聊天中出现，建议改密

---

## 8. 接手时首组命令

```sh
git branch --show-current
git status -sb
git log --oneline -12

# 主机快速测（Windows）
export CFST_ROOT="$PWD"
export PATH="$PWD/tests/helpers/mock-bin:$PATH"
# 勿盲目全量 run.sh；先 unit + dns/rpcd
for t in tests/unit/test_*.sh; do sh "$t" || exit 1; done
sh tests/integration/test_dns.sh
sh tests/integration/test_rpcd.sh
```

路由器：

```sh
# 经 plink，见 §4.1
ubus call system board
ls -la /www/luci-static/resources/view/cloudflare-speedtest/overview.js
ls -la /usr/share/rpcd/acl.d/luci-app-cloudflare-speedtest.json
/usr/bin/cloudflare-speedtest validate
echo '{}' | /usr/libexec/rpcd/cloudflare-speedtest call config_summary
grep cloudflare /etc/crontabs/root
```

---

## 9. 已知坑（环境）

| 坑 | 处理 |
|----|------|
| Windows Git Bash `sleep` 看门狗残留 | `CFST_DISABLE_WATCHDOG=1`；杀残留 `sleep` 进程 |
| PowerShell 吃 `$?` / `&&` | 复杂脚本写成文件再 `bash script.sh` 或 plink 远程 sh |
| `proxy.golang.org` 不通 | `GOPROXY=https://goproxy.cn,direct` |
| 无 `cksum` | schedule 已 md5sum 回退 |
| ipapi.co CF 挑战页 | 默认 ipwho.is 优先 |
| LuCI 路径 | **必须 /www**，ACL **必须 /usr/share/rpcd/acl.d** |
| 正式 IPK | 需 Linux SDK；当前为手动部署，功能可用但非发版形态 |

---

## 10. 给下一会话的一句话

**代码与实地加固已完成；路由器上文件级安装 + LuCI 路径已修好，等用户在设置页提交 Token/Zone 后，继续 test-and-update、DNS 验收与正式 IPK。**
