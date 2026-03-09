#!/bin/bash
set -euo pipefail
# Pull recent events — filtered for Wi-Fi relevant events
# Usage: ./unifi_events.sh [hours_back] [limit]
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

HOURS="${1:-24}"
LIMIT="${2:-50}"

unifi_init

unifi_post "stat/event" "$(jq -n --argjson hrs "$HOURS" --argjson lim "$LIMIT" \
    '{within: $hrs, _limit: $lim}')" | jq '
    [.data[]? | {
        time: .datetime,
        type: .key,
        msg,
        client: (.user // .guest // null),
        ap: .ap,
        ssid
    }]'

unifi_logout
