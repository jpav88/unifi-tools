#!/bin/bash
set -euo pipefail
# Pull device and radio stats — filtered to what matters for Wi-Fi debugging
# Usage: ./unifi_devices.sh [mac_address]
#   No args: all APs with radio summary
#   With MAC: detailed single device
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

MAC=$(normalize_mac "${1:-}")

if [[ -n "$MAC" ]]; then
    # Single device — radio config + stats
    unifi_get "stat/device" | jq --arg mac "$MAC" '
        .data[] | select(.mac == $mac) | {
            _id, name, mac, model, type,
            state: (if .state == 1 then "online" else "offline" end),
            version,
            uptime_hours: ((.uptime // 0) / 3600 | floor),
            num_clients: .num_sta,
            radios: [.radio_table[]? | {
                radio, channel, ht,
                tx_power_mode, tx_power,
                min_rssi_enabled, min_rssi
            }],
            radio_stats: [.radio_table_stats[]? | {
                radio, channel,
                cu_total, cu_self_rx, cu_self_tx,
                num_sta: .num_sta,
                satisfaction
            }],
            vaps: [.vap_table[]? | {
                essid, radio, channel,
                num_sta, satisfaction
            }]
        }'
else
    # All devices — compact radio overview
    unifi_get "stat/device" | jq '
        [.data[] | {
            name, mac, type,
            state: (if .state == 1 then "online" else "offline" end),
            clients: .num_sta,
            radios: [.radio_table_stats[]? | {
                radio, channel,
                cu_total,
                num_sta: .num_sta,
                satisfaction
            }]
        }]'
fi

unifi_logout
