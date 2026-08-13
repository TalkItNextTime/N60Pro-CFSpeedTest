# Cloudflare 优选 IP for N60 Pro

本版本提供 N60 Pro / XploreWrt 的正式 OpenWrt 安装包：

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
  opkg update
  opkg install /tmp/cloudflare-speedtest_*.ipk
  opkg install /tmp/luci-app-cloudflare-speedtest_*.ipk
  /etc/init.d/rpcd restart
  /etc/init.d/uhttpd restart
'
```

将 `192.168.1.1` 替换为自己的路由器地址。

### 安装脚本

也可在路由器中下载本 Release 的 `install.sh`，并以本 Release 的标签替换 `<tag>`：

```sh
wget -O /tmp/install.sh \
  "https://github.com/TalkItNextTime/N60Pro-CFSpeedTest/releases/download/<tag>/install.sh"
sh /tmp/install.sh --version <tag>
```

安装后进入 LuCI 的 **服务 → Cloudflare 优选 IP**，在「基本设置」保存 Cloudflare API Token 与 Zone。Token 最小权限为 `Zone:Read` 与 `DNS:Edit`。

## 说明

- 支持灰云（仅 DNS）与橙云（Cloudflare Proxy）切换。
- 默认测速 URL 为 Cloudflare 官方下载端点的 `99000000` 字节参数版本。
- 透明代理可能影响测速和归属查询；请确保相关请求绕过透明代理。
- 卸载插件不会删除已发布到 Cloudflare 的 DNS 记录。
