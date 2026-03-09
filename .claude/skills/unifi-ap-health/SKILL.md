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

## Instructions
Present a per-AP health report:

For each AP:
- Name, model, location, firmware, uptime
- Per-radio: band, channel, width, tx_power, channel utilization (cu_total), client count, satisfaction
- Flag any radio with cu_total > 40% as "busy" or > 60% as "congested"
- Flag any radio with satisfaction < 70 as "degraded"

Summary table at the top, then details per AP if anything notable.
