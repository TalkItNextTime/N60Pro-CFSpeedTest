# N60 Pro CloudflareSpeedTest OpenWrt 插件设计规格

日期：2026-08-12

## 1. 项目目标

本项目为 Netcore N60 Pro 路由器提供一套可维护的 OpenWrt 原生插件，用于定时运行 CloudflareSpeedTest，选择兼顾低延迟与高下载速度的 Cloudflare IPv4 节点，并把结果更新为指定 Cloudflare Zone 下的地区运营商子域名 A 记录。

目标设备运行 XploreWrt 24.10-SNAPSHOT，目标为 `mediatek/filogic`，软件包架构为 `aarch64_cortex-a53`，内核为 6.6.95。设备拥有四核 ARMv8 处理器、2 GB 内存和 512 MB SPI NAND。实现必须适应 OpenWrt 的 BusyBox 用户空间、只读 SquashFS 根文件系统、overlay 配置层和有限闪存写入寿命。

典型结果是：路由器公网出口被识别为“深圳电信”，用户配置 Zone 为 `domain.com`，系统便维护灰云 A 记录 `szct.domain.com`，记录值为本次测速选出的 Cloudflare 优选 IPv4 地址。

本项目以 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 为测速引擎蓝本，不改写其核心测速算法。插件负责 OpenWrt 生命周期、配置、调度、归属识别、结果校验、Cloudflare DNS 同步和 LuCI 管理界面。

## 2. 已确认的产品决策

实现采用“原生 OpenWrt 软件包 + LuCI 应用 + 辅助安装脚本”。核心功能和界面分别封装为 `cloudflare-speedtest` 与 `luci-app-cloudflare-speedtest` 软件包，构建产物优先面向 `aarch64_cortex-a53`。安装脚本用于没有本地软件源的设备，不替代标准 IPK 包。

LuCI 使用单页仪表盘布局。页面集中展示运行状态、当前网络归属、当前 DNS 记录、最新优选 IP、延迟、下载速度、最近运行时间、下次运行时间、配置、手动操作和日志。

公网归属采用“自动识别 + 手动覆盖”。自动查询失败或结果无法可靠映射时，系统使用用户覆盖值或上次可信缓存，不凭猜测生成名称。

DNS 记录固定为 A 类型和灰云，仅 DNS 模式。归属变化时，系统先成功创建或更新新名称，再清理插件管理的旧地区运营商记录。插件不得删除不属于自身管理范围的记录。

默认测速策略为均衡模式：每 6 小时运行一次，采用适合路由器的低并发延迟筛选，并仅对有限数量候选执行下载测速。所有关键参数均可在 LuCI 调整。

## 3. 范围与非目标

首个版本包括 OpenWrt 软件包定义、目标架构构建、UCI 配置、procd 服务、定时调度、手动任务、互斥锁、CloudflareSpeedTest 调用、CSV 解析、结果校验、公网 IPv4 归属查询、地区和运营商代码映射、Cloudflare API v4 DNS 同步、状态持久化、有限日志轮转、rpcd 接口、LuCI 单页界面、安装说明、卸载说明和自动化测试。

首个版本不包括 IPv6 AAAA 优选、Cloudflare WARP、多个 Cloudflare 账户、一次任务同时维护多个 Zone、基于客户端位置的多线路 DNS、Docker 容器、路由策略自动改写、代理插件联动、自建测速文件托管服务以及完整 IP 地理数据库离线打包。未来如需多 Zone 或多线路，应通过后续独立规格扩展，避免首版配置和状态模型过度复杂。

## 4. 软件包与组件边界

### 4.1 `cloudflare-speedtest`

核心包提供以下内容：

- `/usr/bin/cfst`：为 Linux ARM64 构建的 CloudflareSpeedTest 可执行文件。
- `/usr/libexec/cloudflare-speedtest/runner`：任务编排入口，负责加锁、配置读取、前置检查、执行阶段和最终状态。
- `/usr/libexec/cloudflare-speedtest/geoip`：公网 IPv4 获取、归属查询、结果标准化和缓存。
- `/usr/libexec/cloudflare-speedtest/naming`：城市、运营商与域名模板映射。
- `/usr/libexec/cloudflare-speedtest/dns`：Cloudflare Zone、DNS 记录查询、创建、更新和受控清理。
- `/usr/libexec/cloudflare-speedtest/result`：CSV 解析、候选过滤、排序和结果校验。
- `/etc/config/cloudflare-speedtest`：UCI 配置。
- `/etc/init.d/cloudflare-speedtest`：procd 服务定义。
- `/etc/hotplug.d/iface/95-cloudflare-speedtest`：网络恢复触发器，只唤醒调度并执行去抖，不直接运行长时间测速。
- `/usr/share/cloudflare-speedtest/ip.txt`：Cloudflare IPv4 地址段来源文件。
- `/etc/uci-defaults/`：首次安装初始化和升级迁移。

每个脚本只承担一个职责，并通过稳定的命令行输入、标准输出和退出码交互。`runner` 是唯一允许组合完整任务流程的入口，LuCI 和定时器不得绕过它直接调用 `cfst` 或 Cloudflare API。

### 4.2 `luci-app-cloudflare-speedtest`

LuCI 包提供菜单、JavaScript 视图、ACL 和 rpcd/ubus 接口。浏览器不能直接读取 Token、执行 shell 命令或访问任意日志路径。所有操作都通过最小权限 RPC 方法完成。

RPC 接口至少包括：读取脱敏配置摘要、读取运行状态、启动“测速并更新”、启动“仅测速”、停止当前任务、读取有限长度日志、清空插件日志、验证 Cloudflare 凭据与 Zone、读取最近结果。启动方法必须快速返回任务已受理或冲突状态，不阻塞 HTTP 请求直至测速结束。

### 4.3 构建与安装辅助

仓库包含标准 OpenWrt package feed 目录，可放入 OpenWrt SDK 或 ImageBuilder 相关工作流。持续集成构建 `aarch64_cortex-a53` IPK，并保留构建日志、校验和与对应源码版本。

辅助安装脚本只执行架构检查、依赖检查、下载指定版本 IPK、校验 SHA-256、调用 `opkg install` 和刷新 LuCI 缓存。脚本不得静默修改防火墙、代理、DNS 转发或其他无关配置。

## 5. 配置模型

UCI 包名为 `cloudflare-speedtest`。配置拆分为以下逻辑节：

`main` 保存启用状态、基础周期、启动延迟、工作模式、时区显示策略和日志级别。默认启用周期为 6 小时。主调度机制固定采用 BusyBox `crond`：配置应用时原子更新 `/etc/crontabs/root` 中由插件标记的单行任务，再向 cron 服务发送 reload；procd 只管理初始化、手动任务、停止操作和状态，不运行第二套周期调度器，从根本上避免重复任务。

`cloudflare` 保存 API Token、Zone 名称、可选 Zone ID 缓存、TTL 和代理状态。代理状态在首版固定为关闭，界面显示原因但不提供橙云选项。Token 在配置文件中以 `0600` 权限保存；UCI 本身不提供加密能力，因此界面与文档必须明确这是设备本地敏感配置，并要求管理员保护路由器登录权限和备份文件。

`naming` 保存模板、自动识别开关、城市覆盖、运营商覆盖和回退标签。默认模板为 `cf`，生成 `cf.<zone>`；也兼容 `{city}`、`{isp}`、`{zone}` 占位符。模板只允许预定义占位符、ASCII 小写字母、数字、连字符和点，最终生成的每个 DNS 标签必须满足长度和语法约束。

`test` 保存线程数、单 IP 延迟次数、下载候选数、单候选下载时长、端口、测速 URL、最高延迟、最高丢包率、最低下载速度、全局任务超时、结果改进阈值和自定义 IP 段文件。默认参数固定为 `-n 50 -t 4 -dn 5 -dt 10 -tp 443 -tl 200 -tlr 0.2`，比上游桌面默认值保守。首轮不设置 `-sl`，避免网络未标定时因速度门槛过高导致长时间遍历或无输出；插件在解析阶段应用可配置最低速度校验，默认值为 `0.01 MB/s`，用于排除明显不可用或疑似回源结果。

`geo` 保存查询提供方顺序、单次超时、总超时、缓存有效期和手动覆盖。首版至少支持两个返回结构明确的 HTTPS 提供方，通过适配器归一化，不把单一第三方接口作为唯一依赖。

`state` 不作为用户编辑配置。最近成功结果、插件管理记录标识和可信归属缓存在 `/etc/cloudflare-speedtest/state.json`，并采用原子写入。高频运行状态放在 `/tmp/cloudflare-speedtest/status.json`；持久状态仅在成功结果或受管 DNS 记录发生变化时写入。

## 6. 地区与运营商命名

公网出口识别只使用路由器直连 WAN 的公网 IPv4。查询请求必须明确绕过本机透明代理或在文档中要求将相关域名加入直连规则；测速流量同样必须避免经过代理，否则结果不能代表本地出口。

城市名称先标准化为行政区中文名或规范英文名，再查稳定短码表。深圳映射为 `sz`。运营商映射至少包括：中国电信 `ct`、中国联通 `cu`、中国移动 `cm`、中国广电 `cbn`、中国教育和科研计算机网 `cernet`。具体字符串匹配集中在单独数据文件和测试夹具中，不散落在流程脚本内。

当自动结果、手动覆盖和缓存同时存在时，优先级为：字段级手动覆盖、可信自动结果、未过期可信缓存、固定回退标签。城市和运营商分别决策，允许只覆盖其中一项。

若无法得到符合 DNS 规则的城市或运营商代码，任务可以完成测速并保存结果，但不得自动创建名称不明确的新 DNS 记录。日志和 LuCI 状态必须显示“测速成功，DNS 未更新”及具体原因。

## 7. 测速与候选选择

runner 为每次任务创建唯一临时目录，目录位于 `/tmp/cloudflare-speedtest/`，并以 `flock` 或兼容的原子锁机制防止计划任务与手动任务并发。若系统没有独立 `flock`，软件包应声明依赖或采用 BusyBox 可用的原子目录锁。锁中记录 PID 和启动时间，处理异常退出遗留锁。

调用 `cfst` 时始终使用绝对输入与输出路径，并设置 `-p 0`，避免交互等待。结果写入临时 CSV。CloudflareSpeedTest 上游结果第一行为按其规则选出的最快候选，CSV 字段为 IP、发送数、接收数、丢包率、平均延迟、下载速度和地区码。插件仍需自行解析和校验，不能盲目信任第一行。

候选必须满足以下条件：有效公网 IPv4、接收数大于零、丢包率不高于配置上限、平均延迟大于零且不高于配置上限、下载速度为有限非负数，并满足插件配置的最低速度。若多个候选合格，先按下载速度降序，再按平均延迟升序，再按丢包率升序选取，保证规则稳定。

可选“仅在明显更优时更新”策略比较新旧结果。默认关闭该策略，以便适应旧节点失效；开启后，仅当下载速度改善超过配置百分比、延迟改善超过配置毫秒数，或旧节点健康检查失败时更新。

每次运行有全局超时。收到停止请求时，runner 先向子进程发送 TERM，等待短暂宽限期后再 KILL，并写入明确的取消状态。取消、超时或无合格候选均不得改变 DNS。

## 8. Cloudflare DNS 同步

Token 采用 Cloudflare API Token，不支持 Global API Key。最低权限为目标 Zone 的 `Zone:Read` 与 `DNS:Edit`。Token 应尽可能限制到单个 Zone。

DNS 同步过程为：验证 Zone 名称；使用已缓存且匹配 Zone 的 Zone ID，或通过 API 查询；生成规范 FQDN；查询同名 A 记录；不存在则创建，存在一条则幂等更新，多条则停止并提示人工处理，避免错误覆盖；确认 API 返回成功且再次读取结果一致；更新本地管理状态；若归属名称发生变化，再删除本地状态中明确登记、且当前值仍符合插件预期的旧 A 记录。

记录属性固定为 `type=A`、`proxied=false`、TTL 为 Cloudflare 自动值或用户配置的合法值。更新前后 Token 绝不写入日志。HTTP 错误日志保留状态码、Cloudflare 错误代码、脱敏消息和请求阶段，不记录 Authorization 请求头。

对于 429 和暂时性 5xx，使用有限次数指数退避，并尊重 `Retry-After`。对于 401、403、无权限、Zone 不存在和数据冲突，不做无意义重试。DNS 更新失败时保留旧记录与旧的本地成功状态，新测速结果可以作为“未发布结果”展示。

## 9. 调度、服务与资源控制

默认计划每 6 小时运行一次，并在开机联网后增加随机或固定延迟，避免启动时争抢资源。网络刚恢复时只安排一次任务，短时间内多次 hotplug 事件必须去抖。

测速进程通过 `nice` 降低 CPU 优先级；如果目标固件提供 `ionice`，可选降低 I/O 优先级，但不增加硬依赖。默认并发显著低于上游桌面默认值。临时 CSV、PID、进度与运行日志缓存位于 `/tmp`。

持久日志采用固定文件大小和少量轮转文件，默认总量不超过数百 KB。只有任务阶段、结果、错误和 DNS 变更进入持久日志，实时进度不逐行持久化。系统同时使用 `logger` 写入带固定 tag 的系统日志，便于 `logread` 排查。

卸载时保留 UCI 配置还是清理配置遵循 OpenWrt 软件包惯例，并在文档中给出显式彻底清理命令。卸载绝不删除 Cloudflare DNS 记录；远端记录清理由用户主动执行。

## 10. LuCI 单页仪表盘

菜单位于“服务 → Cloudflare 优选 IP”。页面顶部三个状态卡分别显示运行状态和下次任务、当前优选节点指标、当前地区运营商域名及 DNS 同步状态。

操作区包含“立即测速并更新 DNS”“仅测速”“停止当前任务”。运行中禁用冲突按钮，并定期轮询轻量状态接口。页面关闭不影响后台任务。

配置区域包含以下标签页或折叠区：基本设置、Cloudflare DNS、测速参数、地区命名、运行日志。保存配置时先在浏览器做格式提示，再由 RPC 后端进行权威校验。保存成功不自动启动高带宽测速，除非用户点击明确的运行按钮。

Token 输入框使用密码类型。读取页面时后端只返回“已配置”状态，不返回原 Token；用户留空表示保持原值，明确点击清除或输入新值才修改。日志、状态和错误提示统一脱敏。

日志区支持刷新、自动刷新开关、下载插件日志和清空插件日志。后端限制单次返回字节数并只允许访问固定日志文件，避免任意文件读取。结果区显示最近一次已发布结果与最近一次未发布测速结果，防止用户误以为测速成功就等同于 DNS 更新成功。

页面应适配 OpenWrt 默认 LuCI 主题和移动端宽度，不引入大型前端框架或外部 CDN 资源。

## 11. 状态机与可观测性

任务状态至少包括 `idle`、`preparing`、`detecting_network`、`testing_latency`、`testing_download`、`validating_result`、`updating_dns`、`cleaning_old_record`、`success`、`partial_success`、`failed`、`cancelled`。

状态对象包含阶段、启动时间、更新时间、触发来源、当前进度摘要、最后错误代码、最后错误信息、检测到的公网 IPv4、归属、候选结果、已发布结果和下次计划时间。Token 与完整 API 响应不得出现。

错误使用稳定机器码和可读中文消息，例如 `CONFIG_TOKEN_MISSING`、`GEO_ALL_PROVIDERS_FAILED`、`CFST_TIMEOUT`、`RESULT_NO_QUALIFIED_IP`、`CF_API_FORBIDDEN`、`DNS_MULTIPLE_RECORDS`。LuCI 根据机器码提供针对性提示，日志保留具体阶段。

## 12. 故障保护

以下情况均不得改动现有 DNS：网络不可用、公网 IP 获取失败且无可信归属、所有归属提供方失败且名称不能安全确定、`cfst` 启动失败、全局超时、CSV 缺失或格式异常、无合格 IPv4、Token 无效、Zone 不匹配、API 权限不足、Cloudflare 限流重试耗尽、同名记录冲突、停止请求和内部状态写入失败。

新记录更新成功但旧记录清理失败时，任务标记为 `partial_success`，保留新记录并在后续任务重试清理。旧记录删除前必须同时匹配本地 managed 标识、记录 ID、预期名称和可接受的记录类型，避免误删后来被用户接管的记录。

状态文件采用写临时文件、`fsync` 条件允许时同步、原子重命名的方式更新。若持久状态损坏，系统进入保守模式：允许测速和同名幂等更新，但不自动删除任何历史 DNS。

## 13. 安全设计

Cloudflare Token 不通过命令行参数传给外部进程，不出现在进程列表。API 请求由受控脚本从权限为 `0600` 的 UCI 配置读取。LuCI ACL 仅授权管理员角色调用插件 RPC。

所有来自 UCI、GeoIP 接口、CSV 和 Cloudflare API 的字符串均视为不可信输入。shell 实现必须避免 `eval`，变量始终正确引用；域名、IP、数字和模板分别使用白名单校验。JSON 使用 `jsonfilter`、`jshn` 或明确声明的解析依赖，不用正则表达式解析任意 JSON。

辅助安装脚本固定下载来源和版本，并校验 SHA-256。持续集成发布产物附带校验和。项目遵守上游 GPL-3.0 许可证要求；若分发修改或捆绑后的 `cfst` 二进制，同时发布对应源码和许可证文本。

## 14. 测试与验收

单元测试覆盖城市标准化、运营商字符串映射、模板渲染、DNS 标签校验、CSV 解析、候选排序、阈值边界、Cloudflare 错误分类、Token 脱敏和 managed 记录保护。

集成测试使用模拟 HTTP 服务覆盖 Zone 查询、记录不存在时创建、同值幂等、值变化更新、429 退避、401/403、5xx、多个同名记录、新记录成功后旧记录删除失败，以及损坏状态文件下禁止清理。

流程测试覆盖计划任务与手动任务锁冲突、停止任务、超时、断网、GeoIP 主服务失败后切换备用服务、所有 GeoIP 服务失败、`cfst` 无输出、CSV 表头变化、无合格节点和 overlay 空间不足。

目标设备验收步骤为：安装两个 IPK；在 LuCI 填写最小权限 Token 和 Zone；验证凭据；确认自动识别或手动覆盖得到 `szct`；运行“仅测速”并检查结果不改 DNS；运行“测速并更新 DNS”；确认 Cloudflare 中生成 `szct.domain.com` 灰云 A 记录；确认 LuCI 指标与 DNS 值一致；模拟归属变化并验证先创建新记录再清理插件管理的旧记录；重启路由器后确认配置、最近成功状态和下一次调度正常；检查测速期间 CPU、内存和网络占用不影响路由器基本管理。

完成标准是：在目标 XploreWrt 设备上连续三次计划任务无并发冲突；失败场景不破坏现有 DNS；Token 不出现在 LuCI 响应、日志或进程参数；安装、升级和卸载流程可重复；自动化测试通过；文档能够让用户从空白设备完成安装和首个 DNS 更新。

## 15. 仓库结构建议

```text
N60Pro-CFSpeedTest/
├── README.md
├── LICENSE
├── docs/
│   └── superpowers/specs/
├── package/
│   ├── cloudflare-speedtest/
│   │   ├── Makefile
│   │   └── files/
│   └── luci-app-cloudflare-speedtest/
│       ├── Makefile
│       ├── htdocs/
│       ├── root/
│       └── po/
├── scripts/
│   ├── install.sh
│   └── build-sdk.sh
├── tests/
│   ├── unit/
│   ├── fixtures/
│   └── integration/
└── .github/workflows/
```

具体文件清单和任务拆分将在本规格获用户确认后，通过独立实施计划确定。实施计划必须优先完成可测试的核心控制层，再接入 Cloudflare API，最后开发 LuCI 界面和发布流水线。

## 16. 外部依赖与兼容性说明

CloudflareSpeedTest 上游使用 Go 构建，当前仓库模块声明兼容 Go 1.18。上游明确提示路由器应降低 `-n` 并发，测速时应关闭或绕过代理。上游 CSV 首行是其排序后的最佳结果，但本插件仍执行独立校验。

核心 OpenWrt 依赖固定为 BusyBox shell（含 `crond`）、`curl`、`ca-bundle`、`jsonfilter`、UCI、ubus、rpcd、procd 和 LuCI 基础组件。选择 `curl` 是因为 Cloudflare API 同步需要可靠处理请求方法、请求头、响应头、状态码和重试；选择 `jsonfilter` 是因为它是 OpenWrt 常用的轻量 JSON 查询工具。不声明独立 `cron` 软件包依赖，因为目标固件由 BusyBox 提供 `crond`。实施时仍需在 XploreWrt 24.10 实机确认这些组件的具体包名和已安装状态。

Cloudflare API、归属查询服务和上游测速 URL 都是外部依赖。测速 URL 默认值不能被视为永久可用，LuCI 必须允许修改，并在文档中建议高级用户使用自己控制且位于 Cloudflare 后的下载测试地址。
