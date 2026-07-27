#!/bin/bash
set -euo pipefail
# Quick network health check — minimal output for context efficiency
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

health=$(unifi_get "stat/health") || exit 1
devices=$(unifi_get "stat/device") || exit 1
clients=$(unifi_get "stat/sta") || exit 1

jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson health "$(echo "$health" | jq '[.data[] | {subsystem, status, num_user, num_ap: .num_adopted}]')" \
    --argjson devices "$(echo "$devices" | jq '[.data[] | {name, mac, type, state: (if .state == 1 then "online" else "offline" end), uptime_hours: ((.uptime // 0) / 3600 | floor), clients: .num_sta}]')" \
    --argjson wifi_clients "$(echo "$clients" | jq '[.data[] | select(.is_wired == false)] | length')" \
    '{timestamp: $ts, health: $health, devices: $devices, wireless_clients: $wifi_clients}'

unifi_logout
