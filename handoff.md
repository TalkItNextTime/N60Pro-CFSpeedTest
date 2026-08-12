# N60 Pro CloudflareSpeedTest OpenWrt 插件开发交接

更新时间：2026-08-12

## 1. 项目目标

本项目为 Netcore N60 Pro（XploreWrt 24.10-SNAPSHOT，`mediatek/filogic`，`aarch64_cortex-a53`，2 GB RAM，512 MB SPI NAND）开发原生 OpenWrt 插件，用于：

定时运行 XIU2/CloudflareSpeedTest，筛选低延迟且下载速度较高的 Cloudflare IPv4；根据路由器公网出口自动识别城市和运营商，例如“深圳电信”映射为 `szct`；将优选 IP 发布为 Cloudflare 灰云 A 记录，例如 `szct.domain.com`；在 LuCI 的“服务”菜单中提供配置、状态、手动测速、DNS 更新、停止任务和日志查看界面。

目标仓库：<https://github.com/TalkItNextTime/N60Pro-CFSpeedTest.git>

上游测速器：<https://github.com/XIU2/CloudflareSpeedTest>

## 2. 已确认的产品决策

已经完成需求讨论并确认以下设计：

- 使用原生 OpenWrt 软件包，而不是 Docker。最终包含核心包 `cloudflare-speedtest` 和界面包 `luci-app-cloudflare-speedtest`，同时提供辅助安装脚本。
- LuCI 使用单页仪表盘，集中显示状态卡、手动操作、配置和日志。
- 地区与运营商采用“公网 IPv4 自动识别 + LuCI 手动字段覆盖 + 上次可信缓存 + 固定回退”的优先级。
- DNS 只创建 A 记录，并固定为灰云 `proxied=false`。橙云会覆盖优选 IP 的解析意义，因此首版不支持。
- 公网归属变化时，先成功创建或更新新记录，再清理插件明确登记为 managed 的旧记录。不得删除用户手工管理的其他 DNS 记录。
- 默认均衡测速参数为低并发模式，计划每 6 小时执行一次。
- Cloudflare 使用 API Token，不支持 Global API Key。最小权限为目标 Zone 的 `Zone:Read` 与 `DNS:Edit`。
- 周期调度采用 BusyBox `crond`，原子维护 `/etc/crontabs/root` 中带插件标记的一行；procd 不再运行另一套周期调度器。

完整设计规格见：

- [设计规格](docs/superpowers/specs/2026-08-12-n60pro-cloudflare-speedtest-openwrt-design.md)
- [实施计划](docs/superpowers/plans/2026-08-12-n60pro-cloudflare-speedtest-openwrt.md)

## 3. Git 与远端状态

当前工作分支：

```text
feature/openwrt-plugin-implementation
```

当前已提交 HEAD：

```text
b32657b feat: implement city/ISP naming and hostname mapping
```

该提交已经推送到：

```text
origin/feature/openwrt-plugin-implementation
```

当前功能分支相对 `origin/main` 领先 5 个提交。最近提交顺序如下：

```text
b32657b feat: implement city/ISP naming and hostname mapping
0400ec6 feat: prevent concurrent speed tests
c2476fa feat: add atomic state and bounded logs
d2210b1 feat: define validated UCI configuration
be235d0 test: add portable shell test harness
447c4c7 docs: add OpenWrt plugin implementation plan
85e8f62 docs: add OpenWrt plugin design specification
```

不要在未检查工作区前切换分支、reset、clean 或拉取覆盖。目前存在大量未提交工作和临时文件。

## 4. 已提交并推送的完成内容

### 4.1 设计与实施计划

设计规格和 16 个任务的实施计划已经提交到 `main`，并包含架构、安全策略、Cloudflare 同步顺序、LuCI 界面、测试和 N60 Pro 实机验收要求。

### 4.2 测试基础设施

提交 `be235d0` 已建立：

- `Makefile`：`make test` 与 `make shellcheck` 入口。
- `tests/run.sh`：自动运行 `tests/unit/test_*.sh` 和 `tests/integration/test_*.sh`。
- `tests/helpers/assert.sh`：轻量断言函数。
- `tests/helpers/jsonfilter_mock.py` 与 mock 命令。
- `.github/workflows/test.yml`：Ubuntu 24.04 主机测试和 ShellCheck。
- GPL-3.0 `LICENSE`。

### 4.3 UCI 配置契约

提交 `d2210b1` 已建立：

- `package/cloudflare-speedtest/files/etc/config/cloudflare-speedtest`
- `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/config.sh`
- `tests/unit/test_config.sh`
- `tests/helpers/mock-bin/uci`

已覆盖默认值、Token/Zone 缺失、非法 Zone、线程和丢包率边界等验证。默认参数包括：

```text
-n 50 -t 4 -dn 5 -dt 10 -tp 443 -tl 200 -tlr 0.2
```

插件解析阶段默认以 `0.01 MB/s` 排除明显不可用或疑似回源结果，不直接向 CFST 传严格 `-sl`，以免长时间遍历。

### 4.4 原子状态与有限日志

提交 `c2476fa` 已建立：

- `state.sh`：运行状态、持久状态 schema v1、原子临时文件加 `mv` 写入、损坏状态进入保守模式。
- `log.sh`：日志大小限制、轮转、Token 和 Authorization 脱敏、有限字节读取、清空插件日志。
- `test_state.sh`、`test_log.sh`。

### 4.5 任务互斥锁

提交 `0400ec6` 已建立：

- `lock.sh`：原子目录锁、PID/启动时间/触发来源、锁所有权、存活 PID 检查、陈旧锁恢复。
- `test_lock.sh` 与测试专用 PID 存活模拟命令。

锁库本身不注册 trap；计划要求只在 runner 中注册 `trap 'release_lock' EXIT INT TERM`。

### 4.6 城市、运营商和域名映射

提交 `b32657b` 已建立：

- `naming.sh`
- `cities.tsv`
- `providers.tsv`
- `test_naming.sh`

已覆盖深圳/北京/上海/广州及中英文别名，运营商代码包括：

```text
中国电信 ct
中国联通 cu
中国移动 cm
中国广电 cbn
教育网 cernet
```

域名模板默认为 `{city}{isp}.{zone}`，例如 `szct.domain.com`。实现会拒绝大写、下划线、空标签、超长标签、超长 FQDN 和未知占位符。

注意：`naming.sh` 中 `_lookup_code()` 定义了一个没有实际用途的 awk `lower()` 函数，而且包含对 `and()` 的引用。虽然当前测试通过且该函数未调用，但后续质量审查时应删除这段死代码，避免 BusyBox awk 兼容风险。

## 5. 当前未提交的进行中工作

Task 6“公网 IPv4 与 GeoIP 提供方适配”正在开发，尚未提交，当前包含：

- `package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh`
- `tests/unit/test_geoip.sh`
- `tests/fixtures/geoip/invalid.json`
- `tests/fixtures/geoip/ipapi-public.json`
- `tests/fixtures/geoip/ipapi-shenzhen-telecom.json`
- `tests/fixtures/geoip/ipwhois-public.json`
- `tests/fixtures/geoip/ipwhois-shenzhen-telecom.json`
- 对 `tests/helpers/jsonfilter_mock.py` 的未提交修改。

`geoip.sh` 当前意图包括：

- 严格检查公网 IPv4，拒绝私网、环回、链路本地、组播、保留段和 TEST-NET 文档地址。
- 适配 `ipapi.co` 与 `ipwho.is`。
- 使用 `curl --noproxy '*'`，并清除大小写代理环境变量，避免透明/显式代理污染出口识别。
- 自动提供方、手动覆盖、未过期缓存、固定回退的字段级选择。
- 无安全名称时返回 `41` 和 `GEO_ALL_PROVIDERS_FAILED`。

这部分当前没有通过测试，不能视为已完成。

## 6. 当前测试状态和确切失败原因

最近执行：

```sh
sh tests/run.sh
```

退出码为 `1`。已提交部分的测试继续执行，但新增 `tests/unit/test_geoip.sh` 失败。

失败发生在第一个 `parse_ipapi` 用例。跟踪结果显示测试调用：

```sh
jsonfilter -i tests/fixtures/geoip/ipapi-shenzhen-telecom.json -e '@.ip'
```

mock `jsonfilter` 没有返回内容，随后 `parse_ipapi` 因 `ip/city/isp` 为空返回 1。

根因是当前未提交的 `tests/helpers/jsonfilter_mock.py` 已被意外写坏。当前 diff 中结尾出现了被真实换行切断的 Python f-string：

```python
sys.stdout.buffer.write(f"{value}
".encode("utf-8"))
```

这不是合法 Python。原意是规避 Windows 文本模式 stdout 输出 `CRLF` 导致 ash 命令替换保留 `\r`，正确实现应当类似：

```python
sys.stdout.buffer.write((str(value) + "\n").encode("utf-8"))
sys.stdout.buffer.flush()
```

下一会话应首先修复该语法，再运行：

```sh
python3 -m py_compile tests/helpers/jsonfilter_mock.py
CFST_ROOT="$PWD" PATH="$PWD/tests/helpers/mock-bin:$PATH" sh tests/unit/test_geoip.sh
sh tests/run.sh
```

如果 `parse_ipapi` 仍为空，再单独验证：

```sh
CFST_ROOT="$PWD" tests/helpers/mock-bin/jsonfilter \
  -i tests/fixtures/geoip/ipapi-shenzhen-telecom.json \
  -e '@.ip'
```

预期输出为：

```text
203.0.113.10
```

注意：TEST-NET 地址只用于解析夹具；实时 `validate_public_ipv4` 必须继续拒绝它，不能为通过测试而放宽生产校验。

## 7. 工作区污染与清理注意事项

工作区存在大量由中断的后台实现代理留下的未跟踪临时文件，例如：

```text
.tmp-*.txt
.tmp-*.json
.tmp-*.md
.tmp/
out-*.txt
```

这些文件不是产品代码，不应提交。但不能直接执行 `git clean -xfd`，因为以下未跟踪文件是需要保留的真实 Task 6 工作：

```text
package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh
tests/fixtures/geoip/*
tests/unit/test_geoip.sh
```

建议修复并提交 Task 6 后，再精确删除根目录临时文件。安全做法是先查看：

```sh
git status --short
git clean -nd -- '.tmp*' 'out-*.txt'
```

确认预览只包含临时文件后，再有选择地删除。不要把 `.tmp*` 一股脑加入仓库；可以在 `.gitignore` 增加项目根目录专用规则 `/.tmp*`、`/out-*.txt`，但应先确认不会屏蔽计划中的正式文件。

当前 `.tools/` 和 Python `__pycache__/` 已在 `.gitignore` 中。

## 8. 已踩过的坑和解决经验

### 8.1 Git 初次推送网络重置

首次 `git push` 出现 `Recv failure: Connection was reset`，重试后成功。Git 还会输出：

```text
git: 'credential-manager-core' is not a git command
```

该提示没有阻止已认证推送，属于本机 Git credential helper 配置问题。遇到网络失败应检查远端状态后重试，不要重新初始化仓库。

### 8.2 原工作目录最初未被工具识别为 Git 仓库

`EnterWorktree` 和隔离 subagent 曾错误报告“不在 git repository”，但直接执行 `git rev-parse` 证明仓库正常。最终没有成功创建 linked worktree，而是在普通 checkout 上创建并使用功能分支：

```text
feature/openwrt-plugin-implementation
```

下一会话不要假设当前目录是 harness 管理的 worktree；它是普通仓库 checkout。不要使用 `ExitWorktree` 清理。

### 8.3 Windows `/tmp` 与 Python 路径语义不同

Git Bash 中 `/tmp/foo` 对 shell 有效，但 Windows Python 的 `Path('/tmp/foo')` 可能解析成当前盘根目录的 `\tmp\foo`，造成找不到文件。主机测试中尽量让 shell 自己读临时文件，或向 Python 传 Windows 可解析的路径。

### 8.4 mock UCI 的 while 管道/命令替换退出状态

最初 mock `uci` 使用 `while read` 搜索键，即使找到值，循环最后一次 `read` 仍可能令命令替换返回非零，导致 `cfst_config_get`错误使用默认值。后来改为 awk 查找并明确退出。

### 8.5 ShellCheck 在 Windows 输出中文乱码

下载的 Windows ShellCheck 可执行文件能正常发现问题，但中文消息在 Git Bash 中可能显示乱码。这不代表源码编码损坏。重点查看规则编号和行号。

### 8.6 ShellCheck SC2034/SC2015/SC1090

配置库中的变量是供后续 sourced 脚本消费，ShellCheck 会误判为未使用，已使用文件级 `SC2034`。`A && B || C` 被重构为明确 `if`，避免 SC2015 和错误的类三元语义。动态 source 的测试使用 `SC1090,SC1091` 抑制。

### 8.7 JSON mock 必须返回对象

持久状态测试需要 `jsonfilter` 对对象/数组输出紧凑 JSON，而不是拒绝非标量。mock 已扩展支持对象、数组、布尔和 null。这一点对后续 Cloudflare API 测试同样重要。

### 8.8 Windows CRLF 污染命令替换

Python stdout 在 Windows 文本模式可能输出 `\r\n`，ash 命令替换只去掉 `\n`，留下 `\r`，导致字符串比较和 JSON 字段失效。Task 6 当前正试图使用 `sys.stdout.buffer` 固定输出 UTF-8 LF，但修改被写坏。修复时应使用明确的字节输出，不应删除所有 `\r` 来掩盖问题。

### 8.9 OpenWrt cron 路径设计修正

早期设计写成 `/etc/cron.d/cloudflare-speedtest`，这不符合 BusyBox crond 的常见 OpenWrt 使用方式。规格已改为原子维护 `/etc/crontabs/root` 中带标记的一行，并且不声明独立 `cron` 包依赖。

### 8.10 上游与 SDK 固定版本

实施计划已经固定：

```text
CloudflareSpeedTest v2.3.5
commit 65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4
source SHA-256 ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32
```

OpenWrt SDK 默认固定为：

```text
OpenWrt 24.10.2 mediatek/filogic
openwrt-sdk-24.10.2-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
SHA-256 df288284baa46d37cbc71812130b72617333f886f5c93c11f0548e28f0bb8309
```

普通构建不得使用 `latest` 或浮动分支。

## 9. 下一步实施顺序

下一会话应严格按实施计划继续，不要先做 LuCI，也不要跳过失败测试。

### 第一步：恢复干净的 Task 6 红绿循环

1. 修复 `tests/helpers/jsonfilter_mock.py` 的 Python 语法。
2. 运行 `python3 -m py_compile`。
3. 运行聚焦 GeoIP 测试并修复真实逻辑问题。
4. 运行完整 `sh tests/run.sh`。
5. 使用 ShellCheck 检查所有 shell 文件。
6. 审查 `geoip.sh` 的 BusyBox 兼容性，尤其是：
   - `env -u` 在目标 BusyBox/固件是否可用；更稳妥的做法可能是对子进程设置 `http_proxy= https_proxy= all_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY=`。
   - `_geo_field()` 当前多余地把 JSON同时通过 stdin 和 `-s` 传入，应简化。
   - 第 258 行附近 `&&` 与 `||` 混用存在优先级歧义，应改成清晰的嵌套 `if`。
   - 确认临时 body 文件不会在并发或异常退出时残留。
7. 通过后提交并推送：

```sh
git add tests/helpers/jsonfilter_mock.py \
  package/cloudflare-speedtest/files/usr/libexec/cloudflare-speedtest/geoip.sh \
  tests/fixtures/geoip tests/unit/test_geoip.sh
git commit -m "feat: detect WAN location with provider fallback

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push origin feature/openwrt-plugin-implementation
```

### 第二步：继续实施计划 Tasks 7–15

按顺序完成：

1. CFST CSV 严格解析和候选选择。
2. Cloudflare API 模拟集成测试、幂等更新、429/5xx 重试及 managed 记录安全清理。
3. runner、CLI、状态机、超时和取消。
4. BusyBox crond、procd、hotplug 与 UCI defaults。
5. 固定上游 v2.3.5，构建 ARM64 CFST，编写核心 OpenWrt package Makefile。
6. rpcd/ubus API 和最小权限 ACL。
7. LuCI JavaScript 单页仪表盘。
8. OpenWrt SDK 构建脚本、安装脚本和 GitHub Actions。
9. README 和 N60 Pro 实机验收文档。

每个任务都应执行：失败测试、确认失败原因、最小实现、聚焦测试、完整主机测试、ShellCheck、提交、推送。

### 第三步：主机端基本验收

全部实现后至少执行：

```sh
sh tests/run.sh
make shellcheck
python3 -m py_compile tests/helpers/jsonfilter_mock.py tests/helpers/mock_http.py
sh scripts/build-cfst.sh /tmp/cfst-build
sh scripts/build-sdk.sh dist
sha256sum -c dist/SHA256SUMS
```

SDK 构建可能受 Windows 主机、网络、tar/zstd 或 OpenWrt Linux 构建环境限制。如果无法在当前环境完成，不得宣称构建成功；应保留完整错误，并依赖 Linux GitHub Actions 构建产物。

### 第四步：路由器实测留给用户后续安排

用户明确表示后续会安排 N60 Pro 实地测试。因此当前会话应完成所有主机可验证内容和 IPK/CI 构建，实机项目保留在 `docs/acceptance-n60pro.md`。不要在没有路由器连接和真实受限 Cloudflare 测试 Token 的情况下声称端到端实机验证完成。

## 10. 尚未实现的关键模块

截至本交接文档，以下内容仍未开始或未完成：

- Task 6 GeoIP：代码已生成但测试失败、未提交。
- Task 7 CFST CSV 解析：未开始。
- Task 8 Cloudflare DNS API：未开始。
- Task 9 runner 与 CLI：未开始。
- Task 10 cron/procd/hotplug：未开始。
- Task 11 OpenWrt 核心包和 ARM64 CFST：未开始。
- Task 12 rpcd 与 ACL：未开始。
- Task 13 LuCI 仪表盘：未开始。
- Task 14 SDK、安装器、发布 CI：未开始。
- Task 15 README 与实机验收文档：已完成（Task 15 docs）。
- Task 16 完整验证：未开始。

当前不能生成可安装 IPK，也不能在 LuCI 中看到菜单，Cloudflare DNS 更新也尚未实现。

## 11. 安全和正确性底线

后续实现必须持续遵守：

- Token 不得出现在命令行参数、进程列表、日志、ubus 响应或 LuCI 配置回显中。
- 自动化测试不得调用真实 Cloudflare API 或修改真实 DNS。
- 测速或 GeoIP 失败时不得改动现有 DNS。
- 新 DNS 成功并校验后，才允许尝试清理旧 managed 记录。
- 状态文件损坏时禁止自动删除历史 DNS。
- 多条同名 A 记录必须停止并要求人工处理，不能猜测要覆盖哪一条。
- 插件只管理 A/灰云；不要为了便利引入橙云或 AAAA。
- 所有外部字符串都按不可信输入处理，不使用 `eval`，shell 变量全部正确引用。
- 公网归属和测速请求必须绕过代理；出现 `0.xx ms` 延迟通常意味着代理污染。
- 不要使用 `--force-depends` 安装 IPK。
- 不要创建版本标签，除非所有主机测试、SDK 构建和实机验收均通过且用户明确要求发布。

## 12. 接手时建议执行的首组命令

```sh
git branch --show-current
git status --short
git log --oneline --decorate -8
python3 -m py_compile tests/helpers/jsonfilter_mock.py
CFST_ROOT="$PWD" PATH="$PWD/tests/helpers/mock-bin:$PATH" \
  sh tests/unit/test_geoip.sh
sh tests/run.sh
```

预期前两条确认当前位于 `feature/openwrt-plugin-implementation`，且能够看到未提交的 Task 6 文件。`py_compile` 目前预计失败；先修复该问题，再继续 GeoIP 逻辑调试。

在修复 Task 6 并提交之前，不要运行会删除未跟踪文件的命令。
