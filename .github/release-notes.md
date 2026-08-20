# Cloudflare 优选 IP for N60 Pro

本版本修复了"没有符合条件的测速结果"、优选 IP 选取错误，以及通过 opkg 安装后 LuCI 界面无法工作的问题。

## 修复内容

- 修复 `luci-app-cloudflare-speedtest` 打包时 `/usr/libexec/rpcd/cloudflare-speedtest` 缺少可执行权限的问题。rpcd 会静默拒绝加载不可执行的插件，导致通过 opkg 全新安装后 `ubus` 中没有 `cloudflare-speedtest` 对象、整个 LuCI 页面不可用。此前用文件覆盖方式部署的机器不受影响。
- 修复下载测速只尝试固定几个 IP 就放弃的问题。现在会把界面上的最低下载速度作为 `-sl` 下限传给测速程序，跳过实际不可用的低延迟 IP 继续尝试，直到凑够"下载候选数"个达标地址。这是"延迟预检通过、却报没有符合条件的测速结果"的直接原因。
- 修复选取结果时并非取最快 IP 的问题。原先依赖 `sort -t, -k6,6nr` 排序，而部分 OpenWrt 的 BusyBox `sort` 会忽略 `-t/-k` 退化为整行字典序，导致选中编号最小的 IP 而不是最快的。排序改在 awk 内完成。
- 修复失败原因被吞掉的问题。结果筛选此前在子 shell 中执行，错误码无法回传，表头异常与无合格结果都笼统报成"没有符合条件的测速结果"。
- 新增筛选诊断日志 `result_reject rows=… latency_loss_ok=… max_speed_mbps=… required_mbps=…`，可直接看出是延迟、丢包还是下载速度这一关清空了结果集。
- "下载候选数"默认值由 5 调整为 10（仅影响全新安装，升级会保留既有配置）。

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

从本 Release 下载 `cloudflare-speedtest_*.ipk`、`luci-app-cloudflare-speedtest_*.ipk` 和 `SHA256SUMS`，校验后上传到路由器：

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

请将 `192.168.1.1` 替换为路由器地址。升级时会保留已有的 `/etc/config/cloudflare-speedtest` 配置。

### 使用安装脚本

也可以在路由器中下载本 Release 的 `install.sh`：

```sh
wget -O /tmp/install.sh \
  "https://github.com/TalkItNextTime/N60Pro-CFSpeedTest/releases/download/<tag>/install.sh"
sh /tmp/install.sh --version <tag>
```

安装后进入 LuCI 的 **服务 → Cloudflare 优选 IP**。如浏览器仍显示旧界面，请使用 `Ctrl + F5` 强制刷新。

## 透明代理环境提示

若路由器上运行 passwall / OpenClash 等透明代理并对全部出站 TCP 做重定向，测速得到的延迟是本地代理的 accept 时间（常见 1～5 ms），并非真实 RTT，`地区码` 也可能为 `N/A`。此时延迟排序基本失去意义，实际可用性完全依赖下载测速这一关，建议适当提高"下载候选数"或把测速流量排除在代理规则之外。

## Cloudflare Token

请使用仅作用于目标 Zone 的 API Token，最小权限为：

- `Zone:Read`
- `DNS:Edit`

不要使用 Global API Key。Token 会写入路由器 UCI 配置，请保护好路由器后台、备份文件和 SSH 登录权限。
