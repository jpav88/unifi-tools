#!/bin/bash
set -euo pipefail
# List wireless clients with signal/satisfaction data
# Usage: ./unifi_clients.sh [mac_address]
#   No args: all wireless clients (summary)
#   With MAC: detailed single client
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

MAC=$(normalize_mac "${1:-}")

if [[ -n "$MAC" ]]; then
    # Single client detail
    unifi_get "stat/sta" | jq --arg mac "$MAC" '
        .data[] | select(.mac == $mac) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            ap_mac,
            channel, radio,
            signal, rssi, noise,
            satisfaction,
            tx_rate, rx_rate,
            tx_bytes, rx_bytes,
            tx_retries, tx_packets,
            roam_count,
            uptime_seconds: .uptime,
            uptime_hours: ((.uptime // 0) / 3600 * 10 | floor / 10),
            assoc_time: (.assoc_time | todate),
            is_wired
        }'
else
    # All wireless clients — compact summary
    unifi_get "stat/sta" | jq '
        [.data[] | select(.is_wired == false) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            ap_mac, channel,
            signal, satisfaction,
            tx_rate, rx_rate
        }] | sort_by(.essid)'
fi

unifi_logout
