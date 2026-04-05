#!/bin/bash
set -euo pipefail
# Pull device stats — APs get radio data, switches get port data
# Usage: ./unifi_devices.sh [mac_address]
#   No args:  all devices with radio/port summary
#   With MAC: detailed single device
#
# Examples:
#   ./unifi_devices.sh                    # all devices overview
#   ./unifi_devices.sh aa:bb:cc:dd:ee:ff  # single device detail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

MAC=$(normalize_mac "${1:-}")

# jq helper: convert radio codes to human names
RADIO_NAME='def radio_name: if . == "na" then "5GHz" elif . == "ng" then "2.4GHz" elif . == "6e" then "6GHz" else . end;'

if [[ -n "$MAC" ]]; then
    # Single device — type-aware detail
    unifi_get "stat/device" | jq --arg mac "$MAC" "$RADIO_NAME"'
        .data[] | select(.mac == $mac) |
        if .type == "usw" then {
            _id, name, mac, model, type,
            state: (if .state == 1 then "online" else "offline" end),
            version,
            uptime_hours: ((.uptime // 0) / 3600 | floor),
            ports: [.port_table[]? | {
                port_idx, name, up,
                speed, full_duplex,
                poe_enable,
                poe_power: (.poe_power // null),
                media
            }]
        } else {
            _id, name, mac, model, type,
            state: (if .state == 1 then "online" else "offline" end),
            version,
            uptime_hours: ((.uptime // 0) / 3600 | floor),
            num_clients: .num_sta,
            radios: [.radio_table[]? | {
                band: (.radio | radio_name),
                radio, channel, ht,
                tx_power_mode, tx_power,
                min_rssi_enabled, min_rssi
            }],
            radio_stats: [.radio_table_stats[]? | {
                band: (.radio | radio_name),
                radio, channel,
                cu_total, cu_self_rx, cu_self_tx,
                num_sta: .num_sta,
                satisfaction
            }],
            vaps: [.vap_table[]? | {
                essid,
                band: (.radio | radio_name),
                radio, channel,
                num_sta, satisfaction
            }]
        } end'
else
    # All devices — type-aware compact overview
    unifi_get "stat/device" | jq "$RADIO_NAME"'
        [.data[] |
        if .type == "usw" then {
            name, mac, type,
            state: (if .state == 1 then "online" else "offline" end),
            ports: [.port_table[]? | {
                port_idx, up, speed,
                poe_power: (.poe_power // null)
            }]
        } else {
            name, mac, type,
            state: (if .state == 1 then "online" else "offline" end),
            clients: .num_sta,
            radios: [.radio_table_stats[]? | {
                band: (.radio | radio_name),
                channel,
                cu_total,
                num_sta: .num_sta,
                satisfaction
            }]
        } end]'
fi

unifi_logout
