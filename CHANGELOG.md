# Changelog — UniFi Network Settings

All notable changes to the UniFi network configuration are documented here.

## [2026-07-27]

### Changed
- **The per-client audit script was renamed to `unifi_client_audit.sh`** and de-personalised. It hardcoded
  **real device MACs** (lines 58-59) and a family member's name throughout — and every tracked
  file is copied to the public mirror, so both were already published. Audit targets and the AP
  MAC/name/room map now come from `local/devices.sh` (gitignored); the script errors out with a
  clear message if they're missing. `local/devices.sh.example` documents the new keys.

### Security
- **`pgit_publish.sh` now scrubs household names and redacts every MAC address.** Previously it
  rewrote only SSIDs, the UDM/syslog-host hostnames and one personal name, so real MACs and family
  names flowed straight through. Added: name rules (longest-match-first, word-bounded via BSD
  `[[:<:]]`/`[[:>:]]` so "Client" can't corrupt "Debug"), a blanket
  `xx:xx:xx:xx:xx:xx` MAC redaction, and a regex-based un-redacted-MAC leak check that fails the
  publish. **`.gitignore` is now scrubbed and leak-checked too** — it has no file extension, so
  every previous pass skipped it silently while it named a family member.
  Verified by replaying the full sync+scrub into a scratch clone: 0 name hits, 0 un-redacted MACs,
  "Debug" intact.

### Added
- **`scripts/sync_memory_backup.sh`** — mirrors this project's Claude auto-memory (which lives
  outside the repo at `~/.claude/projects/<sanitized-cwd>/memory/`, so no commit ever covered it)
  into a tracked `memory-backup/` directory via `rsync --delete`, markdown only. Run by
  `/checkpoint` before staging. `memory-backup/` is a generated mirror — never hand-edit it.
  **`pgit_publish.sh` now excludes `memory-backup/` wholesale**: it contains device MACs, LAN and
  WAN IPs, family names and the house layout, and the publisher's scrubber only rewrites SSIDs,
  the UDM/syslog-host hostnames and one personal name, so it would not have sanitized any of it.
- **`unifi_channel.sh`** — set an AP's channel/width safely. Reads the live `radio_table`, edits
  exactly one radio and PUTs the whole table back (a partial `radio_table` wipes the other bands'
  settings). `--dry-run` to preview; `--show` prints **configured vs. operating** channel plus
  channel utilisation for every radio — the two disagree after a DFS radar fallback and only the
  operating value is real. Takes literal args, so it also matches a static permission rule, unlike
  the old `unifi_write.sh radio <id> "$(cat file.json)"` form.
- **`unifi_write.sh wlan <ssid_name|_id> <on|off>`** — enable/disable an SSID by name (reversible;
  does not delete it).
- **`unifi_write.sh tx_power <ap_mac> <ng|na|6e> <low|medium|high|auto|N>`** — set radio transmit
  power, accepting either a named mode or an explicit dBm value (clamped to the radio's own
  `min_txpower`/`max_txpower`).

### Fixed
- **`unifi_clients.sh` (all-clients branch) and `unifi_sessions.sh` (both branches) crashed** with
  `jq: Cannot index object with null`. A *disconnected* wireless client has `ap_mac: null`, and
  `$aps[null]` is a hard jq error — not the post-gateway-reboot artifact previously assumed. The
  single-client branch was guarded on 2026-07-19; these three were missed. All now use
  `if .ap_mac then ($aps[.ap_mac] // .ap_mac) else null end`.

### Documentation
- **CLAUDE.md: login rate limiting.** `HTTP 429` is self-inflicted — there is no session reuse, so
  N script invocations = N logins. Documents the one-login-many-calls `bash -c` batch form, the
  bash-not-zsh `EXIT`-trap requirement, and the cross-project calling pattern. Section trimmed to
  keep CLAUDE.md scannable; full detail lives in project memory.

## [2026-07-25]

### Added
- **Hard-outage detection on the WAN dashboard** (`unifi_wan_dashboard.py`) — a new
  `outages()` pass over the samples table finds contiguous windows of *total* loss and
  classifies each one: **GATEWAY DOWN** (lan_gw is 100% lost too → the UDR7 itself
  rebooted/lost power — not Frontier), **INTERNET DOWN** (LAN gateway answers, every
  external tier at 100% → Frontier/ONT) and **NO DATA** (>5 min with no samples at all —
  monitor stopped or the syslog host lost its link). Shown as a red 7-day strip with
  start/end/length, shaded as bands on all three charts, and given its own `OUTAGE`
  banner state. Result cached 60s (a 7-day scan is ~100k rows).
- **3d / 7d chart windows** alongside 1h/6h/24h.
- **Outage cause attribution** — each gateway outage is explained from the UniFi syslog the
  syslog host already receives: a `fwupdate: Version:` marker within 15 min before it went dark
  becomes "Firmware update → v5.1.27", a bare `Systool Rebooting` becomes "Gateway reboot",
  and neither becomes "Unexplained" (power loss / hard crash). Each row also lists when every
  tier answered again, so LAN-before-WAN recovery is visible. The 500 MB syslog scan takes
  ~0.6s and is cached 15 min.
- **Colour-coded outage bands on every chart** (latency, jitter, loss) — red = gateway down,
  orange = internet down, grey = no data — each with a solid left edge, a cap along the top
  and the cause printed beside it ("Firmware update → v5.1.27"). Minimum 3px wide so a
  3-minute outage stays visible on a 7-day axis, plus a shaded-band key in the legend.

- **`unifi_write.sh auto_update <status|hour N|on|off>`** — reads/sets device firmware
  auto-upgrade (`rest/setting/mgmt` → `auto_upgrade`, `auto_upgrade_hour`) via partial
  POST `set/setting/mgmt`, and reports the controller app's own `super_mgmt.auto_upgrade`.

### Changed
- **Device firmware auto-upgrade window: hour 0 (12 AM) → 6 (6 AM)** so unattended
  *adopted-device* (AP/switch) reboots land after gaming hours.
  **This does NOT govern the console itself** — see below.

### Found (research, 2026-07-25)
- The console's own `GET /api/firmware/update` shows the UDR7 is on the
  **`"channel": "beta"`** (Early Access) UniFi OS track: build published
  `2026-07-23T10:12:09Z`, `cachedAt` **2026-07-25 03:48:12 CDT**, `fwupdate` logged at
  03:49:00, `Systool Rebooting` at 03:50:05. So the console **installs within ~1 minute
  of noticing** a build — the ~2-day lag was discovery/rollout, not a schedule, and
  `auto_upgrade_hour` was ignored (it was 0, install ran at 03:49).
- **Nothing is checked before rebooting** — no client count, traffic, or session test.
  58 clients were connected. UniFi offers no activity-aware deferral at all.
- EA cadence is the real driver of frequency: Dream Routers 5.1.26 shipped Jul 22,
  5.1.27 Jul 23. Fix is the channel (Official/Stable) or Notify-only, set in
  Settings → Control Plane → Updates + the account-level Early Access opt-in.
- **Chart X axis is now readable** — round-clock tick marks chosen from a 1min→2day
  ladder (~1 label per 110px), aligned to local hour/midnight boundaries, with vertical
  gridlines and the date stamped on the first tick and every day rollover (e.g.
  `Fri 7/24 · 12PM · 3PM … Sat 7/25 · 12AM`). Previously only start/mid/end times were
  labelled, so blips could not be placed in time at a glance.

### Incident
- **03:51:12–03:53:53 CDT, whole-network outage (~2m40s)** — *not* an Internet outage.
  UDR7 auto-updated to `UDR7.ipq5322.v5.1.27` (from 5.1.21) and rebooted
  (`fwupdate` 03:49:00 → `Systool Rebooting` 03:50:05). WAN DHCP lease on eth3 kept the
  same IP (47.162.15.71) throughout; no WAN link-down event exists. This is the known EA
  auto-update ~3am reboot behaviour.

## [2026-07-23]

### Added
- **`unifi_wan_monitor.sh`** (new) — continuous WAN-path monitor. Every 30s it fires
  `fping -C5` at a tiered target set (LAN gateway → Frontier first hop → Frontier
  regional → Google/Cloudflare) and records per-tier loss%, min/avg/max RTT and
  **jitter** (stddev of the per-packet RTTs) into SQLite (`data/wan_path.db`). Purpose:
  attribute gaming/latency incidents to *local vs Frontier vs beyond* without touching
  the client PC. On trouble it also captures a timestamped traceroute (cooldown-limited)
  to `data/wan_path_events.log`. Rolling 7-day retention (daily self-prune + maintenance
  backstop). Runs as LaunchDaemon `com.pavdog.unifi-wanmonitor`. `--pause`/`--resume`
  idle the daemon without sudo (flag file); `--status`/`--show [hrs]` for CLI review.
- **DNS resolution timing** — each tick times a lookup via the gateway resolver (client
  path) and Cloudflare (control), stored in a `dns` table. Catches "feels like lag" that
  ping can't see. Slow/failing gateway DNS counts toward incidents.
- **WAN public-IP watch** — each tick resolves the public IP via OpenDNS (DNS, no HTTP) and
  records it in a `wan_ip` table only on change; a Frontier rotation (which silently breaks
  the gamer's Satisfactory port-forward) is logged to the event log + flagged on the dashboard.
- **Bufferbloat (latency-under-load)** — every 3h the monitor runs Apple's `networkQuality`
  (RPM), storing idle vs loaded latency, throughput, and an A–D grade in a `bufferbloat`
  table. This is the game-host failure mode ping can't see (upload saturates → everything
  queues → lag). `--bufferbloat` triggers one on demand; a grade-D result raises the 24h
  incident strip. Dashboard shows a bufferbloat tile + an on-page explainer of how it's
  measured and why it matters.
- **`unifi_wan_dashboard.py`** (new) — live dashboard (stdlib `http.server`, port 8092,
  matches ruuvi/ecoflow) reading `wan_path.db`: per-tier latency/jitter/loss charts with
  **per-chart 1h/6h/24h toggles**, status tiles (incl. DNS + WAN-IP), a live **attribution
  banner** (LOCAL / FRONTIER / BEYOND / HEALTHY), a **persistent 24h incident strip** that
  survives a recovered overnight event and auto-clears, and an on-page "how to read this"
  notes panel (hop-1 ICMP-jitter caveat, etc.). LaunchDaemon `com.pavdog.unifi-wandashboard`.
- **FactoryGame.log analysis panel** — the dashboard parses `GameLogs/FactoryGame.log`
  (Satisfactory dedicated-server log, cached by mtime) and renders a bottom-of-page panel
  with a NETWORK/SERVER/CLEAN verdict, session span, lag-comp warning peak-hour, hitch
  count, autosave times, and a timeout/disconnect timeline — **all in Central time**.
  Lets network-vs-server-PC be told apart at a glance and cross-referenced with the tiers
  by timestamp. Auto-refreshes when a newer log is dropped in `GameLogs/`.
- **Hop-1 noise hardening** — a real deprioritized-ICMP blip (frontier_hop1 spiked to 93ms with
  0% loss and zero propagation to regional/google/cloudflare) exposed that hop-1 could false-trigger
  the banner/incident strip. Fixed: a WAN verdict now requires **both** external anchors (Google AND
  Cloudflare) to degrade together (end-to-end truth); hop-1 and regional only *localize* it. hop-1 is
  excluded from incident detection and its tile caps at amber (not red) on latency-only spikes, labeled
  "noisy baseline, trust regional".
- **Dashboard WAL read fix** — `_con()` now uses a normal connection + `PRAGMA query_only=ON`
  instead of `?mode=ro`; a read-only connection can't open a WAL database once the writer
  (monitor daemon) is stopped, which would have blanked the dashboard exactly when the monitor
  is paused/killed.
- Retention wired into `ruuvi/ruuvi_maintenance.sh` (DB 7-day prune + log caps).

## [2026-07-19]

### Added
- **`unifi_write.sh port_forward list|add|del`** — manage WAN port-forward rules via
  `rest/portforward`. `add <name> <ext_port> <fwd_ip> <fwd_port> [proto]` (proto
  tcp|udp|tcp_udp, ports single or range); `del` resolves by name or `_id`.
- **`unifi_write.sh game list|add|del`** — one-shot game-server presets that open every
  port a title needs. Built-ins: satisfactory (7777 tcp_udp + 8888 tcp), minecraft,
  valheim, terraria, palworld, ark. Ports taken from each game's official docs.
- **`unifi_backup.sh`** (new) — `--list` / `--create [keep]` / `--download <file>`. Pulls
  controller config backups off-box to a gitignored `backups/` dir with local retention.
  Downloads through `/proxy/network` and rejects the HTML SPA shell so it can never save a
  non-backup silently.
- **`unifi_delete()`** helper in `unifi_auth.sh` (DELETE via `_unifi_request`).

### Fixed
- **`unifi_clients.sh <mac>` no longer crashes on wired clients** — guarded null
  `ap_mac`/`assoc_time` in the single-client jq filter; added `switch`, `sw_port`,
  `wired_rate_mbps` to the output.

### Changed (network configuration)
- **Gaming PC** (`xx:xx:xx:xx:xx:xx`) reserved at **192.168.1.131** and given WAN
  port-forwards for a **Satisfactory dedicated server**: `Satisfactory 7777`
  (tcp_udp 7777) + `Satisfactory 8888` (tcp 8888) → .131.

## [2026-07-16]

### Added
- **`unifi_write.sh fixed_ip <mac> <ip|off>`** — set/remove a DHCP fixed-IP
  reservation via `upd/user` (resolves client `_id` and `network_id`
  automatically; validates the IPv4). Used to reserve Brother P750 (.143) and
  HDHomeRun (.190).
- **`EXPECTED_SLOW_PORTS`** in `local/devices.sh` (+ example) — list of
  `"<switch> P<idx>"` entries whose sub-1G link is expected (e.g. 100M-only
  NICs); `unifi_snapshot.sh` now skips them in its port-speed warning.

### Changed (network configuration)
- Fixed-IP reservations added: Brother P750 label printer (`xx:xx:xx:xx:xx:xx`
  → .143, my_network_iot) and HDHomeRun tuner (`xx:xx:xx:xx:xx:xx` → .190, wired).
  Both aliased in the controller. Inventory updated in
  `docs/STATIC_IPS.private.md`.

## [2026-07-09]

### Changed (network configuration)
- **Multicast DNS enabled** globally (Settings → Networks; was off) — required for
  HomeKit/Bonjour discovery across wired↔wireless. NOTE: this setting silently
  rejects API writes (`rc: ok` but value reverts, classic + v2 API) — UI-only.
- **Fixed-IP reservations**: added ESP32 Garage Ruuvi Gateway (.111) and James iPad
  (.100); re-reserved James iPhone (.161) under its new private MAC after a WiFi
  forget/rejoin rotated the old one; forgot 3 stale entries (old iPhone MAC + two
  unnamed offline ghosts at .170/.197) via `cmd/stamgr forget-sta`.

### Added
- **`docs/STATIC_IPS.private.md`** — full reservation inventory, IoT block
  convention (.110–.119), cleanup log. `.private.` suffix = never published.

### Changed (tooling)
- **`pgit_publish.sh`** — excludes `*.private.*` files from public sync (so
  private docs with real MACs/IPs can be version-controlled without leaking).
- Services: `com.unifi.syslog` migrated from LaunchAgent to LaunchDaemon
  (starts at boot, no login needed) — see ruuvi repo `migrate_to_daemons.sh`.

## [2026-06-20]

### Added
- **`unifi_port_sample.sh`** — periodic port-counter sampler. Fills the gap where the controller keeps hourly time-series for the WAN/gateway but NOT for wired clients (verified: `stat/report.user` returns empty bytes/drops for wired MACs). Snapshots raw `port_table` counters (bytes, packets, drops, errors) for a configurable set of `name@device_mac@port_idx` targets into `data/port_samples.csv`. Default targets: WAN (UDM port 4) + Gaming PC (UDM port 1). `--sample` takes one reading, `--show [n]` renders a side-by-side per-interval delta view (throughput Mbps, Δdrop, Δerr), `--install`/`--uninstall` manage a 15-min **cron** job (cron chosen over launchd — launchctl's GUI/Aqua domain is unreachable from headless/SSH shells).

## [2026-04-21]

### Changed
- **`unifi_syslog.py`** — log rotation reduced from 1 GB/10 backups to 100 MB/5 backups (~500 MB max). Added `ADDBA Resp Ba Policy` to filter list (U6+ noise, ~9,660/day).
- **my_network** WLAN: multicast enhancement disabled — stale IGMP tables were breaking mDNS/AirPrint discovery
- **Bedroom-NanoHD** 2.4GHz: min_rssi loosened from -70 to -75 — IoT device `c0:48:e6` auth reject loop (445/day)
- **HP M277dw printer** SSL cert renewed (397 days, Apple-compliant, expires May 2027)

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
