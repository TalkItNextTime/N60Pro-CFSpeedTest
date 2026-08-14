# Cloudflare 优选 IP for N60 Pro

本版本修复了 N60 Pro / XploreWrt 上的测速任务启动、优选 URL 保存和测速速度单位问题。

## 修复内容

- 修复点击“立即测速并更新 DNS”后仅显示“已接受”、后台任务未实际开始测速的问题。
- 修复 LuCI 中电信、联通、移动及自定义优选 URL 修改后提示“没有待应用的更改”的问题。
- 修复 CloudflareSpeedTest CSV 中的下载速度（MB/s）与界面 Mbps 配置阈值之间的单位换算。
- 增加运行时 Shell 脚本 LF 换行检查，避免 CRLF 导致 BusyBox `ash` 执行失败。

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

## Cloudflare Token

请使用仅作用于目标 Zone 的 API Token，最小权限为：

- `Zone:Read`
- `DNS:Edit`

不要使用 Global API Key。Token 会写入路由器 UCI 配置，请保护好路由器后台、备份文件和 SSH 登录权限。
