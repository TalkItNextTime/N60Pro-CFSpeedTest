# N60 Pro CloudflareSpeedTest Acceptance Guide

**Date:** 2026-08-12  
**Device:** Netcore N60 Pro (2G RAM, SPI NAND 512MB)  
**Firmware:** XploreWrt 24.10-SNAPSHOT r0-b3f5438, mediatek/filogic, aarch64_cortex-a53, kernel 6.6.95

## Host verification (completed)

- Unit + integration suite (quick path without long watchdog sleeps): PASS
- ARM64 `cfst` 2.3.5 cross-built and verified on device: PASS

## Field checklist

- [x] **Firmware identity** — `opkg print-architecture` / `ubus call system board` match aarch64_cortex-a53 + mediatek/filogic
- [x] **Package deploy** — core + LuCI files + `/usr/bin/cfst` deployed (manual tar deploy; formal IPK via SDK/CI still recommended for release)
- [x] **Dependencies** — curl, ca-bundle, jsonfilter, luci present
- [x] **LuCI menu file** — `/usr/share/luci/menu.d/luci-app-cloudflare-speedtest.json` present (title: Cloudflare 优选 IP)
- [x] **rpcd API** — list/call works; `config_summary` returns `token_configured` only
- [x] **Token redaction** — token never in logs or ubus summary
- [x] **Cron schedule** — `14 */6 * * * ... # cloudflare-speedtest` (minute from hostname hash; cksum fallback via md5sum)
- [x] **GeoIP** — ipwho.is → Dongguan telecom → `dg`/`ct`; ipapi.co often blocked by CF challenge in CN
- [x] **Test-only** — success, last_tested includes IP + metrics + `hostname=dgct.domain.com`
- [x] **Test-and-update without token** — fails with `CONFIG_TOKEN_MISSING`, does not publish DNS
- [ ] **Test-and-update with real Token** — needs user-provided Zone-scoped API Token
- [ ] **DNS lookup** — `nslookup <host> 1.1.1.1` after successful publish
- [ ] **CF dashboard** — gray-cloud A record confirmed
- [ ] **Conflict / stop / reboot / multi-cron** — deferred until Token path verified
- [ ] **Formal IPK install via opkg** — build with `scripts/build-sdk.sh` on Linux/CI

## Commands used on device

```sh
opkg print-architecture
ubus call system board
/usr/bin/cloudflare-speedtest validate
/usr/bin/cloudflare-speedtest status
/usr/bin/cloudflare-speedtest result
/usr/bin/cloudflare-speedtest run --mode test-only --trigger manual
/usr/bin/cloudflare-speedtest run --mode test-and-update --trigger manual
echo '{}' | /usr/libexec/rpcd/cloudflare-speedtest call config_summary
grep cloudflare-speedtest /etc/crontabs/root
logread -e cloudflare-speedtest
```

## Field bugs fixed during acceptance

1. `ip.txt` must be bare CIDR only (CFST rejects `#` comments)
2. Runner must pass `-url` and sanitize IP list before CFST
3. Task timeout must not reuse `CFST_SLEEP_CMD` (host tests stub it to `true`)
4. `schedule_minute` must not require `cksum` (md5sum/od fallback)
5. ipwho.is sometimes puts street address in `connection.isp`; prefer `connection.org` when isp looks like an address
6. ISP mapping must substring-match long org strings (e.g. `CHINANET Guangdong province network`)
7. Default Geo provider order: `ipwho.is` before `ipapi.co`
8. Expanded cities.tsv (东莞 etc.)

## Production readiness

| Area | Status |
|------|--------|
| Host tests | Pass (quick suite) |
| Device CLI test-only | Pass |
| Device Geo + hostname | Pass (`dgct.domain.com`) |
| Safe fail without Token | Pass |
| Cron line | Pass |
| DNS publish | **Blocked on user Token** |
| Official IPK/opkg | **Needs Linux SDK/CI build** |

To finish DNS acceptance, configure:

```sh
uci set cloudflare-speedtest.cloudflare.api_token='YOUR_TOKEN'
uci set cloudflare-speedtest.cloudflare.zone='your.domain'
uci commit cloudflare-speedtest
/usr/bin/cloudflare-speedtest run --mode test-and-update --trigger manual
```
