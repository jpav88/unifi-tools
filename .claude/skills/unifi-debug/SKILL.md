---
name: unifi-debug
description: Debug UniFi connectivity issues for a specific device. Pulls health, client data, sessions, and AP radio stats.
argument-hint: <mac_or_hostname>
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
context: fork
---

## Network Health
!`./scripts/unifi_health.sh`

## Client: $ARGUMENTS
!`./scripts/unifi_clients.sh $ARGUMENTS`

## Sessions (last 24h)
!`./scripts/unifi_sessions.sh $ARGUMENTS 24`

## AP Radio Stats
!`./scripts/unifi_devices.sh`

## Known Devices
!`source local/devices.sh && echo "iPad fish_tank MAC: $IPAD_FISH_TANK" && echo "iPad fish_tank2 MAC: $IPAD_FISH_TANK2" && echo "" && echo "APs:" && ap_list`

## Instructions
Analyze the data above and provide a connectivity diagnosis:

1. **Current State** — Is the client connected? Which AP, band, channel? Signal strength and satisfaction?
2. **Session Stability** — How many sessions in the last 24h? Any micro-sessions (<60s)? Roaming cascades?
3. **AP Analysis** — Channel utilization on the connected AP's radio. Any congestion (cu_total > 50%)?
4. **Signal Quality** — RSSI assessment (-30 to -50 excellent, -50 to -65 good, -65 to -75 fair, -75+ poor). TX retries?
5. **Recommendations** — Specific, actionable fixes based on the data. Reference AP names and locations.

If the client is not found, check both iPad MACs and suggest the user verify which SSID the device is on.
