#!/bin/bash
set -euo pipefail
# List wireless clients with signal/satisfaction data
# Usage: ./unifi_clients.sh [mac_address]
#   No args:  all wireless clients (summary)
#   With MAC: detailed single client
#
# Examples:
#   ./unifi_clients.sh                    # all wireless clients
#   ./unifi_clients.sh xx:xx:xx:xx:xx:xx  # single client detail
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
    # Single client detail — wired-safe (ap_mac/assoc_time are null on wired clients)
    unifi_get "stat/sta" | jq --arg mac "$MAC" --argjson aps "$AP_NAMES" '
        .data[] | select(.mac == $mac) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            is_wired,
            ap: (if .ap_mac then ($aps[.ap_mac] // .ap_mac) else null end),
            switch: (if .sw_mac then ($aps[.sw_mac] // .sw_mac) else null end),
            sw_port,
            wired_rate_mbps,
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
            assoc_time: (if .assoc_time then (.assoc_time | todate) else null end)
        }'
else
    # All wireless clients — compact summary
    unifi_get "stat/sta" | jq --argjson aps "$AP_NAMES" '
        [.data[] | select(.is_wired == false) | {
            name: (.name // .hostname // .mac),
            mac, ip, essid,
            ap: (if .ap_mac then ($aps[.ap_mac] // .ap_mac) else null end),
            channel,
            signal, satisfaction,
            tx_rate, rx_rate
        }] | sort_by(.essid, .ap)'
fi

unifi_logout
