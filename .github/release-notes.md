# Cloudflare 优选 IP for N60 Pro

本版本让测速流量绕过路由器上的透明代理，新增上轮 IP 复测与发布 IP 粘滞，并把节点归属改为真实落地机房。

## 修复内容

- **测速走直连。** 路由器上运行 passwall2 等透明代理时，`PSW2_OUTPUT_NAT` 以一条无条件的 `ip protocol tcp counter redirect to :1041` 结尾，本机发出的每个 TCP 连接都先被抓进 xray，测速握手实际是和本地代理完成的。实测后果：延迟显示 0.46–1.67 ms 而非真实的百毫秒级，下载速度 0.00 MB/s，地区码 `N/A`。现在测速进程以专用用户 `cfst` 运行，独立 nftables 表给该 uid 的出站包打 `0xff` 标记，passwall2 自身防环用的 `meta mark 0x000000ff ... return` 规则据此放行。改后同一批 IP 测出 56–168 ms、31–52 MB/s、colo 为 SJC/NRT/SIN/LAX。按 socket 归属匹配，只有测速进程直连，其他流量不受影响。
- **上轮 IP 先复测。** 测速阶段开始时先对上次测速与上次发布的 IP 单独跑一轮完整测速，合格则并入结果表参与优选。只要旧 IP 仍然可用，本轮候选抽样不佳就不会让整个任务失败。
- **发布 IP 粘滞。** 已发布 IP 复测仍合格时，新 IP 速度需高出「切换阈值」百分比才替换，默认 20%，可在界面调整。速度测量本身有噪声，总是取最大值会让 DNS 记录反复抖动。
- **节点归属改用 colo。** 原先显示对节点 IP 做 ipinfo 查询得到的 `region / isp / asn`，对任播地址永远是注册地「美国 California San Francisco / CLOUDFLARENET」，与实际落地机房无关。现在显示 `LAX / 美国 洛杉矶` 这样的真实机房，未收录的代码原样显示。
- 优选节点块新增「最近测速时间」与「最近发布时间」。
- **优选节点按速度与延迟加权评分。** 原先只按下载速度排序，会选中突发速度高但远在几个时区之外的节点。现在速度与延迟各自对合格集合内的最优值归一化后加权求和，权重由新增的「速度权重（%）」控制，默认 60（延迟占 40）。实测数据上这会选中 58 ms / 540 Mbps 的东京节点，而不是 198 ms 的阿姆斯特丹节点。粘滞比较的也是评分而非原始速度。
- **不再重复测量延迟。** 下载阶段过去会把整批候选的延迟重测一遍。透明代理时代这一步几乎不耗时，改成真实测量后它成了最长的一段。现在下载阶段只接收预检已经通过的地址，实测 2000 个候选筛出 188 个，该阶段从 5 分 38 秒降到 1 分 22 秒，整轮从 10 分 33 秒降到 6 分 17 秒。
- **测速进度可见。** cfst 自身的进度计数原先被丢弃，几分钟的延迟扫描看起来像卡死。现在会解析并写入任务状态，界面显示形如「正在测试延迟 541/2000（27%，预计剩余 3 分 6 秒）」。

## 新增设置

测速设置页新增三项：**测速走直连**（默认开启）、**切换阈值（%）**（默认 20）与**速度权重（%）**（默认 60）。速度权重调低会更偏向就近机房，100 表示只看速度，0 表示只看延迟。

## 升级须知

直连后测得的是真实延迟，数值会明显高于之前经代理测出的假值。延迟预检需要对每个候选做真实往返，2000 个候选约需 5 分钟；若嫌慢可调低「随机候选 IP 数量」。若日志中的 `result_reject` 显示 `latency_rejected` 占绝大多数，说明真实延迟普遍高于当前「最高延迟」设置，在界面上调高即可。

安装时会创建系统用户 `cfst`（uid/gid 6520）供 nftables 按 uid 匹配。缺少 `nft` 或该用户时，插件会记录告警并以原有方式继续运行，不会导致任务失败。

## 安装包

- `cloudflare-speedtest_*.ipk`：测速、调度和 Cloudflare DNS 更新核心。
- `luci-app-cloudflare-speedtest_*.ipk`：LuCI 管理界面。
- `SHA256SUMS`：发布资产校验和。
- `install.sh`：下载、校验并安装两个 IPK 的辅助脚本。

## N60 Pro / XploreWrt 安装

仅适用于 `aarch64_cortex-a53` 的 Netcore N60 Pro，使用 OpenWrt 24.10.2 `mediatek/filogic` SDK 构建。安装前在路由器执行：

```sh
. /etc/openwrt_release
printf '%s\n' "$DISTRIB_ARCH"
```

输出必须为 `aarch64_cortex-a53`。请确认固件 ABI/版本兼容；不兼容时请勿强装。

### 手动安装

从本 Release 下载两个 ipk 与 `SHA256SUMS`，校验后上传：

```sh
sha256sum -c SHA256SUMS
scp cloudflare-speedtest_*.ipk luci-app-cloudflare-speedtest_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 '
  opkg install /tmp/cloudflare-speedtest_*.ipk
  opkg install /tmp/luci-app-cloudflare-speedtest_*.ipk
  /etc/init.d/rpcd restart
  /etc/init.d/uhttpd restart
'
```

请将 `192.168.1.1` 替换为路由器地址。升级会保留已有的 `/etc/config/cloudflare-speedtest` 配置。

安装后进入 LuCI 的 **服务 → Cloudflare 优选 IP**。如浏览器仍显示旧界面，请使用 `Ctrl + F5` 强制刷新。

## Cloudflare Token

请使用仅作用于目标 Zone 的 API Token，最小权限为 `Zone:Read` 与 `DNS:Edit`。不要使用 Global API Key。Token 会写入路由器 UCI 配置，请保护好路由器后台、备份文件和 SSH 登录权限。
