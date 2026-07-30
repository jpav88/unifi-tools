---
name: unifi-ap-health
description: Check health and radio stats for all UniFi access points.
argument-hint:
disable-model-invocation: true
allowed-tools: Bash, Read
---

## AP Details
!`./scripts/unifi_devices.sh`

## Known AP Locations
!`source local/devices.sh && ap_list`

## Active Clients (for per-AP counts + signal distribution)
!`./scripts/unifi_clients.sh`

## Instructions
Present a per-AP health report:

For each AP:
- Name, model, location, firmware, uptime
- Per-radio: band, channel, width, tx_power, channel utilization (cu_total), client count, satisfaction
- Flag any radio with cu_total > 40% as "busy" or > 60% as "congested"
- Flag any radio with satisfaction < 70 as "degraded"

Per-AP client counts and their RSSI distribution come from the client data above.

Also flag:
- Any AP offline, or uptime under 1 hour (recently rebooted — check the raw `uptime`
  seconds, not rounded hours)
- Any AP with zero clients that normally carries clients
- Any switch port serving an AP linked below 1000 Mbps (cable/port problem)
- Clients at RSSI below -75 dBm (struggling, near the min_rssi kick thresholds)

Note on `cu_total`: high utilization with high `cu_self_tx` means the AP is doing real
work, not suffering contention. High `cu_total` with LOW `cu_self_tx` is real contention.
`radio_table` is config; `radio_table_stats` is what's actually happening.

Summary table at the top, then details per AP if anything notable.

For a deeper audit (retries, co-channel overlap, config issues) suggest
`./scripts/unifi_wifi_check.sh` as a follow-up — don't run it here, it adds a third
login and risks the HTTP 429 throttle.
