#!/bin/bash
set -euo pipefail
# Time-series AP stats — client counts and traffic over time
# Usage: ./unifi_ap_stats.sh [interval] [hours_back] [mac] [--timeline]
#   interval:   5min (default), hourly, daily
#   hours_back: default depends on interval (12h, 168h, 168h)
#   mac:        optional — filter to single AP
#   --timeline: include per-sample data (default: summary only)
#
# Examples:
#   ./unifi_ap_stats.sh                         # 5-min summary, last 12h
#   ./unifi_ap_stats.sh hourly 48               # hourly summary, last 2 days
#   ./unifi_ap_stats.sh 5min 6 aa:bb:cc:dd:ee:ff  # single AP, last 6h
#   ./unifi_ap_stats.sh 5min 6 --timeline       # all APs with full timeline
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

INTERVAL="${1:-5min}"
HOURS="${2:-}"
MAC=""
TIMELINE=false

# Parse remaining args — mac and/or --timeline in any order
for arg in "${@:3}"; do
    if [[ "$arg" == "--timeline" ]]; then
        TIMELINE=true
    elif [[ "$arg" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        MAC="$arg"
    fi
done

case "$INTERVAL" in
    5min)   ENDPOINT="stat/report/5minutes.ap"; DEFAULT_HOURS=12 ;;
    hourly) ENDPOINT="stat/report/hourly.ap";   DEFAULT_HOURS=168 ;;
    daily)  ENDPOINT="stat/report/daily.ap";    DEFAULT_HOURS=168 ;;
    --help|-h)
        echo "Usage: $0 [5min|hourly|daily] [hours_back] [mac] [--timeline]" >&2
        echo "" >&2
        echo "Shows historical per-AP client counts and traffic." >&2
        echo "Default: summary view. Add --timeline for per-sample detail." >&2
        exit 0
        ;;
    *)
        echo "Usage: $0 [5min|hourly|daily] [hours_back] [mac] [--timeline]" >&2
        exit 1
        ;;
esac

HOURS="${HOURS:-$DEFAULT_HOURS}"
NOW=$(date +%s)
START=$(( NOW - HOURS * 3600 ))

unifi_init

# Build device name lookup
DEVICES=$(unifi_get "stat/device-basic" | jq '[.data[] | {(.mac): (.name // .mac)}] | add // {}')

BODY=$(jq -n --argjson start "$START" --argjson end "$NOW" \
    '{attrs: ["bytes","num_sta","time"], start: ($start * 1000), end: ($end * 1000)}')

RESULT=$(unifi_post "$ENDPOINT" "$BODY")

# Filter to single AP if requested
if [[ -n "$MAC" ]]; then
    NORM_MAC=$(normalize_mac "$MAC")
    RESULT=$(echo "$RESULT" | jq --arg mac "$NORM_MAC" '{data: [.data[] | select(.ap == $mac)]}')
fi

if [[ "$TIMELINE" == true ]]; then
    # Full output with timeline
    echo "$RESULT" | jq --argjson devs "$DEVICES" '
        [.data[] | {
            ap: ($devs[.ap] // .ap),
            ap_mac: .ap,
            time: (.time / 1000 | strftime("%Y-%m-%d %H:%M")),
            clients: .num_sta,
            bytes_mb: ((.bytes // 0) / 1048576 | . * 10 | round / 10)
        }]
        | group_by(.ap)
        | map({
            ap: .[0].ap,
            ap_mac: .[0].ap_mac,
            samples: length,
            avg_clients: ([.[].clients] | add / length | . * 10 | round / 10),
            peak_clients: ([.[].clients] | max),
            total_mb: ([.[].bytes_mb] | add | . * 10 | round / 10),
            timeline: [.[] | {time, clients, bytes_mb}]
        })
        | sort_by(.ap)'
else
    # Summary only (default — much more readable)
    echo "$RESULT" | jq --argjson devs "$DEVICES" '
        [.data[] | {
            ap: ($devs[.ap] // .ap),
            ap_mac: .ap,
            clients: .num_sta,
            bytes_mb: ((.bytes // 0) / 1048576 | . * 10 | round / 10)
        }]
        | group_by(.ap)
        | map({
            ap: .[0].ap,
            ap_mac: .[0].ap_mac,
            samples: length,
            avg_clients: ([.[].clients] | add / length | . * 10 | round / 10),
            peak_clients: ([.[].clients] | max),
            total_mb: ([.[].bytes_mb] | add | . * 10 | round / 10)
        })
        | sort_by(.ap)'
fi

unifi_logout
