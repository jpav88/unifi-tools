---
name: unifi-status
description: Quick UniFi network health summary — AP status, client counts, system health.
argument-hint:
disable-model-invocation: true
allowed-tools: Bash, Read
---

## Network Health
!`./scripts/unifi_health.sh`

## Instructions
Summarize the network health data above in a concise table:
- Overall network status (healthy/degraded/down)
- Each AP: name, status (online/offline), uptime
- Wireless client count
- Any subsystems showing non-ok status

Keep output brief — this is a quick status check, not a deep dive.
