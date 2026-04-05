#!/bin/bash
set -euo pipefail
# List wireless clients with signal/satisfaction data
# Usage: ./unifi_clients.sh [mac_address]
#   No args:  all wireless clients (summary)
#   With MAC: detailed single client
#
# Examples:
#   ./unifi_clients.sh                    # all wireless clients
#   ./unifi_clients.sh aa:bb:cc:dd:ee:ff  # single client detail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

MAC=$(normalize_mac "${1:-}")

# Build AP name lookup: {"mac": "name", ...}
AP_NAMES=$(unifi_get "stat/device-basic" | jq '[.data[] | {(.mac): (.name // .mac)}] | add // {}')

_radio_name() {
    # jq helper to convert radio codes to human names
    echo 'if . == "na" then "5GHz" elif . == "ng" then "2.4GHz" elif . == "6e" then "6GHz" else . end'
}

if [[ -n "$MAC" ]]; then
    # Single client detail
    unifi_get "stat/sta" | jq --arg mac "$MAC" --argjson aps "$AP_NAMES" '
        .data[] | select(.mac == $mac) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            ap: ($aps[.ap_mac] // .ap_mac),
            channel,
            radio: (.radio | '"$(_radio_name)"'),
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
    unifi_get "stat/sta" | jq --argjson aps "$AP_NAMES" '
        [.data[] | select(.is_wired == false) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            ap: ($aps[.ap_mac] // .ap_mac),
            channel,
            signal, satisfaction,
            tx_rate, rx_rate
        }] | sort_by(.essid, .ap)'
fi

unifi_logout
