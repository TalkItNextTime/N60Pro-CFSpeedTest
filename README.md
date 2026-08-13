# Cloudflare 优选 IP · OpenWrt / N60 Pro

面向 **Netcore N60 Pro** 的原生 OpenWrt 插件。它调用 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 测试 Cloudflare IPv4，选出符合延迟、丢包和下载速度条件的节点，并通过 Cloudflare DNS API 更新指定 A 记录。

- **已验证目标：** N60 Pro，XploreWrt 24.10-SNAPSHOT，`mediatek/filogic`，`aarch64_cortex-a53`
- **上游测速器：** CloudflareSpeedTest v2.3.5（固定源码提交，可复现构建）
- **LuCI 路径：** `服务 → Cloudflare 优选 IP`

## 功能

- 手动「仅测速」或「测速并发布 IP」，显示任务阶段、结果和运行日志。
- 支持定时测速；手动发布成功后从成功时间重新计算下次任务，失败不推后。
- 候选 IP 支持 Cloudflare CIDR、随机抽样、测试全部 IP、延迟不达标时按 1.5 倍自动扩容。
- 支持优选反代来源：电信、联通、移动、按本地运营商自动选择，或自定义 URL。
- 本地网络归属仅使用 UAPIS `network/myip`；优选节点归属仅使用 UAPIS `network/ipinfo`。本地归属缓存最长 7 天，节点归属缓存最长 30 天。
- 自定义子域名或 `{city}{isp}.{zone}` 模板；可启用自动识别城市/运营商。
- Cloudflare DNS 可选 **灰云（仅 DNS）** 或 **橙云（Cloudflare Proxy）**。

## Cloudflare Token

创建仅作用于目标 Zone 的 API Token，最小权限为：

- `Zone:Read`
- `DNS:Edit`

不支持 Global API Key。Token 写入路由器的 UCI 配置，文件权限受到保护，但**不加密保存（not encrypted at rest）**；请保护好路由器后台、备份文件和 SSH 登录权限。

## N60 Pro / XploreWrt 安装

> Release 内的 IPK 仅适用于 `aarch64_cortex-a53` 架构，并以 OpenWrt 24.10.2 `mediatek/filogic` SDK 构建。安装前请先确认 N60 Pro 固件的 ABI/版本兼容；不匹配时请勿强装。

先在路由器上确认架构：

```sh
. /etc/openwrt_release
printf '%s\n' "$DISTRIB_ARCH"       # 必须为 aarch64_cortex-a53
ubus call system board
```

### 方式一：下载 Release 的两个 IPK（推荐）

从对应 Release 下载：`cloudflare-speedtest_*.ipk` 与 `luci-app-cloudflare-speedtest_*.ipk`。上传并安装（把 `192.168.1.1` 替换为路由器地址）：

```sh
scp cloudflare-speedtest_*.ipk luci-app-cloudflare-speedtest_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 '
  opkg update
  opkg install /tmp/cloudflare-speedtest_*.ipk
  opkg install /tmp/luci-app-cloudflare-speedtest_*.ipk
  /etc/init.d/rpcd restart
  /etc/init.d/uhttpd restart
'
```

Release 同时提供 `SHA256SUMS`，下载后应先校验：

```sh
sha256sum -c SHA256SUMS
```

### 方式二：使用 Release 自带安装脚本

每个正式 Release 都附带 `install.sh`。在 N60 Pro 上下载脚本后，以实际标签替换 `<tag>`（例如 `v0.1.0`）：

```sh
wget -O /tmp/install.sh \
  "https://github.com/TalkItNextTime/N60Pro-CFSpeedTest/releases/download/<tag>/install.sh"
sh /tmp/install.sh --version <tag>
```

脚本会检查架构、可用 overlay 空间、下载校验和，并按「核心包 → LuCI 包」顺序安装；升级时不使用 `--force-depends` 或 `--force-reinstall`，已有 `/etc/config/cloudflare-speedtest` 会由 opkg 按 conffile 规则保留。

安装后访问 `http://路由器地址/cgi-bin/luci/`，进入 **服务 → Cloudflare 优选 IP**。在「基本设置」填写并保存 API Token 和 Zone；首次使用建议点击「验证凭据」，再执行一次「测速并发布 IP」。

## 使用说明

1. 在「基本设置」填写 Token、Zone、TTL 和灰云/橙云模式，点击页面底部的**保存并应用**。
2. 在「测速参数」设置测速周期、候选来源、阈值和测速 URL。默认下载地址为 `https://speed.cloudflare.com/__down?bytes=99000000`。
3. 在「地区命名」中：固定子域名模板可填 `cf`，生成 `cf.<zone>`；需按本地归属命名时启用「自动识别城市/运营商」并使用 `{city}{isp}.{zone}`。城市覆盖、运营商覆盖用于人工修正自动识别；回退代码只在自动识别和缓存均不可用时使用。
4. 在「运行日志」查看任务状态。定时计划默认每 6 小时运行一次；状态卡显示下一次任务时间。

## 代理与测速注意事项

- **灰云**只更新 DNS，适用于让客户端直接解析到优选 IP；**橙云**启用 Cloudflare Proxy，适用于需要代理保护的记录。
- 路由器上的透明代理可能截获 API 或测速连接；GeoIP 和 CFST 请求必须 **bypass transparent proxy**。如果延迟异常为 `0.xx ms`，先检查是否被代理劫持。

## Install/upgrade/uninstall 与诊断

升级：下载同架构新 Release 的两个 IPK，重复安装命令即可。卸载不会删除 Cloudflare 上已经创建的 DNS 记录：

```sh
opkg remove luci-app-cloudflare-speedtest cloudflare-speedtest
```

CLI diagnostics：

```sh
opkg print-architecture
ubus call system board
ubus call cloudflare-speedtest status
logread -e cloudflare-speedtest
ps w | grep '[c]fst'
```

## 从源码构建

GitHub Actions 在推送 `v*` 标签时运行测试，并使用固定的 OpenWrt 24.10.2 `mediatek/filogic` SDK 构建两份 IPK、`SHA256SUMS` 和上游源码归档。Linux 环境也可执行：

```sh
sh scripts/build-sdk.sh dist
```

项目采用 [GPL-3.0-only](LICENSE)；完整源码与发布记录位于 <https://github.com/TalkItNextTime/N60Pro-CFSpeedTest>。
