# Changelog — UniFi Network Settings

All notable changes to the UniFi network configuration are documented here.

## [2026-04-04]

### Added
- **v2 API support** in `unifi_auth.sh` — new base path and `unifi_get_v2`/`unifi_post_v2` helpers
- **`unifi_ap_stats.sh`** — historical per-AP client counts and traffic (5min/hourly/daily). Summary by default, `--timeline` for full detail.
- **`unifi_spectrum.sh`** — RF spectrum scan viewer with best/worst channel recommendations per radio. Documents 3-tier scanning model (dedicated radio vs manual scan vs unsupported).
- **`unifi_wifi_check.sh`** — full Wi-Fi health audit: weak signal, high retries, co-channel interference, channel utilization, WLAN config issues
- **`unifi_bandwidth.sh`** — per-client bandwidth usage sorted by total traffic. Find the bandwidth hog.
- **`unifi_new_devices.sh`** — detect unknown devices against a known-devices list (`--learn` to seed, then run periodically)
- **`unifi_channel_plan.sh`** — validate channel assignments against spectrum scan data from all APs, flag co-channel and interference
- **`unifi_write.sh rename`** — set client display name via `upd/user` partial update (avoids 403 on `rest/user`)
- **`unifi_write.sh poe_cycle`** — remotely power-cycle a PoE switch port to reboot an AP
- **[UniFi API Reference](docs/unifi-api-reference.md)** — comprehensive v1+v2 API guide with curl examples and known gotchas

### Changed
- **`unifi_events.sh`** — rewired to use v2 `system-log` API (replaces broken v1 `stat/event`). Auto-falls back to v1 if v2 unavailable.
- **`unifi_clients.sh`** — AP MACs now resolve to device names; radio codes show as "5GHz"/"2.4GHz"/"6GHz"
- **`unifi_sessions.sh`** — AP MACs resolve to device names in session and roaming history
- **`unifi_devices.sh`** — added human-readable band names alongside radio codes
- **`unifi_write.sh`** — improved help with examples, added `--help` flag, fixed min_rssi MAC normalization bug
- **U7 Pro Outdoor** 6E radio: `auto` → `ch37` fixed — stops daily channel hopping noise in event log

## [2026-03-24]

### Changed
- **my_network** WLAN: PMF mode `disabled` → `optional` (802.11w) — protects management frames for capable clients
- **unifi_syslog.py**: Added message filtering (wevent crash-loop spam), daemon mode (no stderr bloat), `UBNT_DEVICE` filter. Redeployed to syslog host.

### Added
- **UserPromptSubmit hook** in `.claude/settings.json` — injects session baseline on first prompt (workaround for SessionStart bug #10373)

### Fixed
- **~/.ssh/config** — was missing `Host` line, causing all SSH to route to `.198`. Split into `syslog-host` (remote) and `syslog-host-local` (home) entries.
- **syslog host syslog logs** — cleaned 1.4GB stderr.log and 1GB unifi.log.1; daemon mode prevents stderr growth.

## [2026-03-08]

### Changed
- **Bedroom NanoHD** 5GHz tx_power: `low` → `medium` — improve signal pull for nearby iPhone, reduce sticky-client ping-ponging to UDM
- **iPhone** identified and documented — Fixed private MAC on primary SSID
- **UDM** 5GHz min_rssi: `disabled` → `-75` — force sticky Apple clients to roam to closer APs
- **Remote syslog** enabled via CyberSecure SIEM. Receiver: `scripts/unifi_syslog.py` with LaunchAgent auto-start, 10GB/~3mo retention

### Applied (Wi-Fi Audit — all HIGH/MEDIUM items)
- **my_network** WLAN: enabled bss_transition, 802.11k (rrm), U-APSD, multicast enhancement; set group_rekey 3600
- **my_network_iot** WLAN: disabled bss_transition (IoT); set group_rekey 3600
- **my_network_tv** WLAN: set group_rekey 3600
- **UDM**: enabled min_rssi on 2.4GHz (-78) and 6E (-72); 5GHz left disabled
- **U7 Pro Outdoor**: enabled min_rssi on 5GHz (-72); 2.4GHz/6E left disabled
- **Bedroom NanoHD**: set min_rssi 5GHz -75, 2.4GHz -70
- **U6+**: set min_rssi 5GHz -78; 2.4GHz left disabled
- **Site settings**: enabled roaming assistant (-75 dBm), network optimization, mDNS "all"
