# Changelog — UniFi Network Settings

All notable changes to the UniFi network configuration are documented here.

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
