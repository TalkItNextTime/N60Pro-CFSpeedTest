#
# Copyright (C) 2026 CloudflareSpeedTest OpenWrt packaging
#
# LuCI application for cloudflare-speedtest management dashboard.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cloudflare-speedtest

LUCI_TITLE:=Cloudflare 优选 IP
LUCI_DEPENDS:=+luci-base +rpcd +cloudflare-speedtest
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=CloudflareSpeedTest OpenWrt

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
