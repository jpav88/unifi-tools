---
name: unifi-client-history
description: Look up Wi-Fi session history for a specific client on the UniFi network.
argument-hint: <mac_address> [hours]
disable-model-invocation: true
allowed-tools: Bash, Read
context: fork
---

## Client Current State
!`if [ -n "$0" ]; then ./scripts/unifi_clients.sh "$0"; else echo '{"error":"MAC address required. Usage: /unifi-client-history <mac> [hours]"}'; fi`

## Session History (last $1 hours, default 24)
!`if [ -n "$0" ]; then ./scripts/unifi_sessions.sh "$0" "${1:-24}"; else echo '[]'; fi`

## Known APs
!`source local/devices.sh && ap_list`

## Known iPad MACs
!`source local/devices.sh && echo "my_network: $IPAD_PRIMARY" && echo "my_network_iot: $IPAD_SECONDARY"`

## Instructions
Build a chronological session timeline:
- Start/end time and duration for each session
- Which AP (use friendly names above, match by ap_mac)
- Signal/RSSI and satisfaction score
- Roaming hops within sessions (roaming sub-records)
- Flag any session under 60 seconds as a "micro-session" (instability indicator)

Summarize:
- Total sessions in the period
- Any roaming cascade failures (rapid AP-hopping with degrading signal)
- Longest stable session and which AP
- Current state: AP, signal, uptime
