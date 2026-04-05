#!/bin/bash
set -euo pipefail
# Pull session history for a specific MAC address
# Usage: ./unifi_sessions.sh <mac_address> [hours_back]
#   Default: 24 hours back
#
# Examples:
#   ./unifi_sessions.sh aa:bb:cc:dd:ee:ff       # last 24 hours
#   ./unifi_sessions.sh aa:bb:cc:dd:ee:ff 168    # last 7 days
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

MAC=$(normalize_mac "${1:-}")
HOURS="${2:-24}"

if [[ -z "$MAC" ]]; then
    echo "Usage: $0 <mac_address> [hours_back]" >&2
    echo "  Shows Wi-Fi session history for a client." >&2
    echo "  Default: last 24 hours" >&2
    exit 1
fi

unifi_init

# Build AP name lookup
AP_NAMES=$(unifi_get "stat/device-basic" | jq '[.data[] | {(.mac): (.name // .mac)}] | add // {}')

# Calculate epoch range
END=$(date +%s)
START=$((END - HOURS * 3600))

unifi_get "stat/session?type=all&start=${START}&end=${END}&mac=${MAC}" | jq --argjson aps "$AP_NAMES" '
    [.data[] | {
        start: (.assoc_time | todate),
        end: ((.assoc_time + .duration) | todate),
        duration_min: ((.duration // 0) / 60 | floor),
        ap: ($aps[.ap_mac] // .ap_mac),
        channel,
        satisfaction,
        tx_mb: ((.tx_bytes // 0) / 1048576 | floor),
        rx_mb: ((.rx_bytes // 0) / 1048576 | floor),
        roam_count,
        is_micro: ((.duration // 0) < 60),
        roaming: [.roaming_sessions[]? | {
            ap: ($aps[.ap_mac] // .ap_mac),
            channel,
            duration_sec: .duration,
            satisfaction
        }]
    }] | sort_by(.start)'

unifi_logout
