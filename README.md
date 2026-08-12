# CloudflareSpeedTest OpenWrt Plugin

**Target architecture:** aarch64_cortex-a53

## Supported device/firmware

- Netcore N60 Pro (XploreWrt 24.10-SNAPSHOT, mediatek/filogic, aarch64_cortex-a53)

- Compatible with recent OpenWrt releases on filogic target

## Features

- Periodic execution of CloudflareSpeedTest (XIU2) to select best Cloudflare IPv4
- Automatic city/ISP identification from public WAN IP
- Publish preferred IP as Cloudflare gray-cloud A record (e.g. szct.domain.com)
- LuCI web interface for configuration, status, manual testing, DNS management
- Managed DNS record cleanup (uninstall does not delete remote DNS)

## Security model

- Cloudflare API Token with **Zone:Read** and **DNS:Edit** permissions only
- Gray cloud only (no orange cloud support)
- UCI Token stored on filesystem and protected by file permissions but **not encrypted at rest**
- All external API calls must bypass transparent proxy; `0.xx ms` latency often indicates proxy interception

## Token creation

Create a Cloudflare API Token with Zone:Read and DNS:Edit on the target zone.

## Release installation

```sh
opkg update
opkg install cloudflare-speedtest_*.ipk
opkg install luci-app-cloudflare-speedtest_*.ipk
```

## LuCI first-run

Access LuCI at `http://router-ip`, find `Cloudflare Speed Test` in Services menu.

## Manual validation

Run speed test from LuCI or CLI.

## Scheduling

Default: every 6 hours via crond.

## Logs

View via `logread -e cloudflare-speedtest` or LuCI logs.

## CLI troubleshooting

Use `cloudflare-speedtest --help` and diagnostics commands.

## Upgrade

`opkg update && opkg upgrade cloudflare-speedtest luci-app-cloudflare-speedtest`

## Uninstall

`opkg remove cloudflare-speedtest luci-app-cloudflare-speedtest`

## DNS cleanup policy

uninstall does not delete remote DNS records.

## Build from source

See build instructions in package/Makefile and scripts/.

## GPL/source availability

Source code available under GPL-3.0 at https://github.com/TalkItNextTime/N60Pro-CFSpeedTest.git

GeoIP and CFST must bypass transparent proxy; 0.xx ms indicates proxy interception.

UCI Token protected by filesystem perms but not encrypted at rest.

gray cloud only (no orange cloud)

## CLI diagnostics

```sh
opkg print-architecture
ubus call system board
ubus call cloudflare-speedtest status
logread -e cloudflare-speedtest
nslookup szct.domain.com 1.1.1.1
ps w | grep '[c]fst'
```

Install/upgrade/uninstall commands as above.