# N60 Pro CloudflareSpeedTest Acceptance Guide

**Note:** Real device testing is pending user SSH session. Leave checkboxes unchecked with space for actual results.

## Checklist

- [ ] **Firmware identity**
  ```
  opkg print-architecture
  ubus call system board
  ```

- [ ] **Package install**
  ```
  opkg update
  opkg install cloudflare-speedtest_*.ipk luci-app-cloudflare-speedtest_*.ipk
  ```

- [ ] **Dependencies**
  - Check for required packages

- [ ] **LuCI menu**
  - Access via browser, confirm "Cloudflare Speed Test" menu

- [ ] **Token redaction**
  - Verify token not shown in status/logs

- [ ] **Test-only**
  - Run from LuCI or CLI: `cloudflare-speedtest test-only`

- [ ] **Test-and-update**
  - Run: `cloudflare-speedtest test-and-update`

- [ ] **DNS lookup**
  ```
  nslookup szct.domain.com 1.1.1.1
  ```

- [ ] **CF dashboard**
  - Confirm A record in Cloudflare dashboard

- [ ] **Location override**
  - Override city/ISP in LuCI config

- [ ] **Managed cleanup**
  - Uninstall and verify old records not deleted

- [ ] **Conflict**
  - Test concurrent runs

- [ ] **Cancellation**
  - Test stop command

- [ ] **Reboot**
  - Verify persistence after reboot

- [ ] **Three scheduled runs**
  - Confirm crond works

- [ ] **Log rotation**
  - Check logread -e cloudflare-speedtest

- [ ] **CPU/memory**
  - Monitor during tests

- [ ] **Uninstall/reinstall**
  - Remove and re-install

## Commands

- `opkg print-architecture`
- `ubus call system board`
- `ubus call cloudflare-speedtest status`
- `logread -e cloudflare-speedtest`
- `nslookup szct.domain.com 1.1.1.1`
- `ps w | grep '[c]fst'`

**Test results to fill:** [Actual results here]