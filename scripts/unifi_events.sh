#!/bin/bash
set -euo pipefail
# Pull recent events — uses v2 system-log API (falls back to v1 stat/event)
# Usage: ./unifi_events.sh [hours_back] [limit] [class]
#   class: device-alert, client-alert, admin-activity, update-alert,
#          threat-alert, next-ai-alert, triggers,
#          all (default — excludes admin-activity noise),
#          everything (all classes including admin logins)
#
# Examples:
#   ./unifi_events.sh                        # last 24h, device+client+update+threat
#   ./unifi_events.sh 168 100                # last 7 days, up to 100 events
#   ./unifi_events.sh 24 50 device-alert     # only device events
#   ./unifi_events.sh 24 50 everything       # all classes including admin logins
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

HOURS="${1:-24}"
LIMIT="${2:-50}"
CLASS="${3:-all}"

unifi_init

# Calculate time range in milliseconds for v2 API
NOW_MS=$(date +%s)000
START_MS=$(( $(date +%s) - HOURS * 3600 ))000

_fetch_v2_class() {
    local cls="$1"
    unifi_post_v2 "system-log/${cls}" "$(jq -n \
        --arg start "$START_MS" --arg end "$NOW_MS" --argjson size "$LIMIT" \
        '{start: ($start | tonumber), end: ($end | tonumber), page: 0, size: $size}')" 2>/dev/null
}

_format_v2() {
    jq '[.data[]? | {
        time: ((.timestamp // 0) / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")),
        time_epoch_ms: (.timestamp // null),
        type: (.key // .type // .category // "unknown"),
        severity: (.severity // null),
        msg: (.message // .msg // null),
        device: (.parameters.DEVICE.name // .parameters.CONSOLE_NAME.name // null),
        device_mac: (.parameters.DEVICE.id // null),
        client: (.parameters.CLIENT.name // .admin.name // null),
        ssid: (.parameters.SSID.name // null)
    }]'
}

if [[ "$CLASS" == "all" ]]; then
    CLASSES=("device-alert" "client-alert" "update-alert" "threat-alert")
elif [[ "$CLASS" == "everything" ]]; then
    CLASSES=("device-alert" "client-alert" "admin-activity" "update-alert" "threat-alert")
else
    CLASSES=("$CLASS")
fi

# Try v2 API first
V2_RESULTS="[]"
V2_OK=false
for cls in "${CLASSES[@]}"; do
    RESULT=$(_fetch_v2_class "$cls" 2>/dev/null) || continue
    # Check if we got data (not an error response)
    COUNT=$(echo "$RESULT" | jq '.data // [] | length' 2>/dev/null) || continue
    if [[ "$COUNT" -gt 0 ]]; then
        V2_OK=true
        FORMATTED=$(echo "$RESULT" | _format_v2)
        V2_RESULTS=$(jq -n --argjson a "$V2_RESULTS" --argjson b "$FORMATTED" '$a + $b')
    fi
done

if [[ "$V2_OK" == true ]]; then
    # Sort by time descending, limit output
    echo "$V2_RESULTS" | jq --argjson lim "$LIMIT" 'sort_by(.time) | reverse | .[:$lim]'
else
    # Fall back to v1 stat/event (POST, may return empty on some firmware)
    echo "# v2 system-log returned no data, falling back to stat/event" >&2
    FALLBACK=$(unifi_post "stat/event" "$(jq -n --argjson hrs "$HOURS" --argjson lim "$LIMIT" \
        '{within: $hrs, _limit: $lim, _sort: "-time"}')" 2>/dev/null) || true
    if [[ -n "$FALLBACK" ]]; then
        echo "$FALLBACK" | jq '[.data[]? | {
            time: .datetime,
            type: .key,
            msg,
            client: (.user // .guest // null),
            ap: .ap,
            ssid
        }]'
    else
        echo "[]"
        echo "# Both v2 system-log and v1 stat/event returned no data" >&2
    fi
fi

unifi_logout
