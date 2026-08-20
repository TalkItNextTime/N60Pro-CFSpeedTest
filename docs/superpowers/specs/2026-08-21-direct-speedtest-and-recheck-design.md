# 直连测速、旧 IP 复测与节点归属显示

日期：2026-08-21
状态：已确认，待实现

## 背景

测速任务在装有 passwall2 的路由器上得出的结果是无效的。`PSW2_OUTPUT_NAT` 链以一条无条件规则结尾：

```
ip protocol tcp counter redirect to :1041
```

本机发出的全部 TCP 先被重定向进 xray，直连与否由 xray 内部再判断。因此 cfst 的 TCPing 量到的是与本地 1041 端口握手的耗时，而不是真实 RTT；`sniffing_override_dest='0'` 且 cfst 直接拨 IP，xray 拿不到域名，域名分流规则也匹配不上。

同一批 5 个 IP 的实测对照：

| | root，经 xray | 专用 uid + mark 0xff |
|---|---|---|
| 延迟 | 0.46 – 1.67 ms | 202 – 206 ms |
| 速度 | 0.00 MB/s | 2.76 / 7.26 MB/s |
| colo | N/A | FRA |

passwall2 为防环在三条链里都留了 `meta mark 0x000000ff ... return`。借用这个标记即可让指定 socket 绕过代理，且不影响其他流量。

## 一、直连测速

新增 `direct.sh`，导出 `direct_enable` 与 `direct_disable`。

专用系统用户 `cfst`（固定 uid/gid 6520）由包的 postinst 创建；`/etc/passwd` 中已存在同名条目时不做改动。路由器上没有 `su`、`setpriv`、`setuidgid`，只有 `start-stop-daemon`，因此 cfst 的调用改为：

```sh
start-stop-daemon -S -c cfst -x "$CFST_CFST_BIN" -- <既有参数>
```

它在前台 exec 目标程序并透传退出码，现有的 `&` 加 `wait` 结构不用改。任务目录与准备好的 IP 列表在启动前 `chown` 给 `cfst`，使其能读列表、写 CSV。

`direct_enable` 建立独立表，避免 passwall2 重建规则时被清掉：

```sh
nft add table inet cfst_direct
nft add chain inet cfst_direct mark_out '{ type route hook output priority mangle ; policy accept ; }'
nft add rule inet cfst_direct mark_out meta skuid <uid> meta mark set 0x000000ff
```

uid 运行时用 `id -u cfst` 取。`direct_disable` 删整张表，并在 runner 的 EXIT trap 里兜底，任务被杀也不留规则。操作幂等：重复 enable 不叠加规则。

降级路径，任一条件不满足时记日志并按现状继续，不让任务失败：

- 没有 `nft`：跳过，记 info。
- 没有 `cfst` 用户：以 root 运行且不打标记，记 warn。
- 找不到 passwall2 的 `meta mark 0x000000ff ... return` 规则：仍然打标记（无副作用），记 warn 说明直连可能未生效。

新增 UCI 选项 `test.direct_mode`，取值 0/1，默认 1，界面可关。

## 二、旧 IP 复测并入结果

任务开始、准备候选列表之前，从 state 读取 `last_tested.ip` 与 `last_published.ip`，去重并剔除非公网地址，写入 `$CFST_TASK_DIR/recheck.txt`，单独跑一次完整下载测速得到 `recheck.csv`。参数沿用主测速的阈值与测速地址，`-dn` 取复测 IP 个数，额外耗时不超过 `2 × 单节点下载时间`。

首次运行或 state 中两个 IP 都不存在时跳过复测，直接进入主流程。复测同样沿用延迟与丢包阈值，因此已经不满足条件的旧 IP 会在这一步被 cfst 自己滤掉，不会进入结果表——这是预期行为。

`direct_enable` 在整个测速阶段开始前调用一次，覆盖复测、延迟预检与主测速三段，`direct_disable` 在测速阶段结束后调用；复测与主测速走同一条直连路径。

主测速结束后合成 `$CFST_TASK_DIR/combined.csv`：一行表头，加上 `result.csv` 与 `recheck.csv` 的数据行，按 IP 去重时保留速度较高的那行。优选在 `combined.csv` 上进行。`result.csv` 原样保留，便于事后诊断。

### 选择规则

`select_best_result` 增加两个可选参数：`STICKY_IP` 与 `MARGIN_PCT`，不传时行为与现在完全一致，既有测试不受影响。

先按（速度降、延迟升、丢包升）选出最快的合格 IP `X`。若 `last_published.ip` 也在合格集合内且速度为 `S_pub`，则仅当 `X.speed > S_pub × (1 + MARGIN_PCT / 100)` 时才切换到 `X`，否则保留已发布 IP。等于阈值不切换。

新增 UCI 选项 `test.publish_switch_margin`，单位百分比，默认 20，界面可调。

日志记录实际走向，例如 `select sticky kept=1.2.3.4 best=5.6.7.8 margin=20`。

这个改动同时提升了健壮性：只要旧 IP 仍然合格，整轮任务就不会因为本次抽样全部不达标而失败。

## 三、界面

优选节点块新增两行「最近测速时间」「最近发布时间」，取 `last_tested.tested_at` 与 `last_published.published_at`，沿用现有时间格式化函数。

节点归属由 `region / isp / asn` 改为 colo 代码加中文全称，例如 `FRA / 德国 法兰克福`。现在显示的是 Cloudflare 任播地址的注册地，与实际落地机房无关，属于误导。colo 为空或 `N/A` 时显示未知；表里查不到的代码原样显示。

映射表按现有 `cities.tsv`、`providers.tsv` 的惯例放 `/usr/share/cloudflare-speedtest/colos.tsv`，两列为代码与中文名。表是常见机房的整理集合而非 Cloudflare 全量列表，未收录的走原样回退。

查表在测速阶段完成：runner 组装 `last_tested` / `last_published` 时顺手写入 `colo_name` 字段。rpcd 的 `result` 方法保持原样直出 state 文件，前端不读文件。升级后旧 state 里没有 `colo_name`，前端回退显示原始 colo 代码。

## 四、测试

单元测试覆盖：colo 查表命中、未命中回退、空值；粘滞选择在恰好等于 margin、略低于、略高于三种边界的取舍；复测合并的去重与择优；`direct.sh` 在缺 `nft`、缺用户两种降级路径下的行为。

集成测试新增 `nft` 与 `start-stop-daemon` 的 mock，验证复测发生在主测速之前、直连规则装了又拆、cfst 经 `start-stop-daemon -c cfst` 启动、粘滞选择端到端生效。

## 运行注意

直连后延迟变为真实值。本次 5 个 IP 的抽样落在 FRA（约 200 ms），但 2000 个候选中应有相当数量落在更近的机房，因此不改动仓库里 `max_latency_ms` 的默认值 200。若上线后日志中的 `result_reject` 显示 `latency_rejected` 占比过高，再在界面上调高即可。
