#
# Copyright (C) 2026 CloudflareSpeedTest OpenWrt packaging
#
# OpenWrt package for cloudflare-speedtest + pinned CFST binary.
# Built from pinned upstream commit only (no floating branch or tag refs).
#

include $(TOPDIR)/rules.mk

PKG_NAME:=cloudflare-speedtest
PKG_VERSION:=2.3.5
PKG_RELEASE:=3

# Pinned upstream v2.3.5 (commit below). Checksum is for the exact codeload archive.
# See upstream/cloudflare-speedtest.version — do not substitute floating refs.
PKG_SOURCE_VERSION:=65b43aa58c5f9c7ab8ab83d2d27e35fc00d9cec4
PKG_SOURCE:=CloudflareSpeedTest-$(PKG_SOURCE_VERSION).tar.gz
# Trailing ? makes download.mk use this URL as the full file URL (no path join).
PKG_SOURCE_URL:=https://codeload.github.com/XIU2/CloudflareSpeedTest/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=ad013a23c54d8c9f54984221fbc6f683fd1fd111575115892ed0dff19d7f1d32

PKG_BUILD_DIR:=$(BUILD_DIR)/CloudflareSpeedTest-$(PKG_SOURCE_VERSION)

PKG_MAINTAINER:=CloudflareSpeedTest OpenWrt
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/XIU2/CloudflareSpeedTest
GO_PKG_LDFLAGS_X:=main.version=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/cloudflare-speedtest
  SECTION:=net
  CATEGORY:=Network
  TITLE:=CloudflareSpeedTest scheduled DNS updater
  URL:=https://github.com/XIU2/CloudflareSpeedTest
  DEPENDS:=$(GO_ARCH_DEPENDS) +curl +ca-bundle +jsonfilter +uci +ubus +rpcd +procd
endef

define Package/cloudflare-speedtest/description
  OpenWrt plugin that runs a pinned CloudflareSpeedTest (cfst) binary,
  selects a qualified edge IP, and publishes a Cloudflare A record via
  the Cloudflare API. Uses BusyBox crond (no separate cron package).
endef

define Package/cloudflare-speedtest/conffiles
/etc/config/cloudflare-speedtest
/etc/cloudflare-speedtest/state.json
endef

define Package/cloudflare-speedtest/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/CloudflareSpeedTest $(1)/usr/bin/cfst

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/cloudflare-speedtest $(1)/usr/bin/cloudflare-speedtest

	$(INSTALL_DIR) $(1)/usr/libexec/cloudflare-speedtest
	$(INSTALL_BIN) ./files/usr/libexec/cloudflare-speedtest/*.sh $(1)/usr/libexec/cloudflare-speedtest/

	$(INSTALL_DIR) $(1)/usr/share/cloudflare-speedtest
	$(INSTALL_DATA) ./files/usr/share/cloudflare-speedtest/cities.tsv $(1)/usr/share/cloudflare-speedtest/
	$(INSTALL_DATA) ./files/usr/share/cloudflare-speedtest/providers.tsv $(1)/usr/share/cloudflare-speedtest/
	$(INSTALL_DATA) ./files/usr/share/cloudflare-speedtest/ip.txt $(1)/usr/share/cloudflare-speedtest/
	$(INSTALL_DATA) ./files/usr/share/cloudflare-speedtest/colos.tsv $(1)/usr/share/cloudflare-speedtest/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/cloudflare-speedtest $(1)/etc/config/cloudflare-speedtest
	chmod 0600 $(1)/etc/config/cloudflare-speedtest

	$(INSTALL_DIR) $(1)/etc/cloudflare-speedtest

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/cloudflare-speedtest $(1)/etc/init.d/cloudflare-speedtest

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/95-cloudflare-speedtest $(1)/etc/hotplug.d/iface/95-cloudflare-speedtest

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-cloudflare-speedtest $(1)/etc/uci-defaults/90-cloudflare-speedtest
endef

# The speed test runs as this account so nftables can match its traffic by uid.
# Image builds must not touch the host's /etc, hence the IPKG_INSTROOT guard.
define Package/cloudflare-speedtest/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if ! grep -q '^cfst:' /etc/passwd; then
	echo 'cfst:x:6520:6520:cfst:/var:/bin/false' >> /etc/passwd
fi
if ! grep -q '^cfst:' /etc/group; then
	echo 'cfst:x:6520:' >> /etc/group
fi
exit 0
endef

$(eval $(call GoPackage))
$(eval $(call BuildPackage,cloudflare-speedtest))
