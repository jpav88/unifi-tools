#!/bin/bash
set -euo pipefail
# Per-client bandwidth usage — find who's using the most data
# Usage: ./unifi_bandwidth.sh [hours_back] [top_n]
#   hours_back: how far back to look (default: 24)
#   top_n:      show top N clients by usage (default: 20, 0 = all)
#
# Examples:
#   ./unifi_bandwidth.sh              # top 20 clients, last 24h
#   ./unifi_bandwidth.sh 1            # last hour (who's using bandwidth NOW?)
#   ./unifi_bandwidth.sh 168 50       # last 7 days, top 50
#   ./unifi_bandwidth.sh 24 0         # last 24h, all clients
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

HOURS="${1:-24}"
TOP_N="${2:-20}"

unifi_init

# Build client name lookup from all known users
CLIENT_NAMES=$(unifi_get "stat/alluser" | jq '[.data[] | {(.mac): (.name // .hostname // .mac)}] | add // {}')

# Build AP name lookup
AP_NAMES=$(unifi_get "stat/device-basic" | jq '[.data[] | {(.mac): (.name // .mac)}] | add // {}')

NOW=$(date +%s)
START=$(( NOW - HOURS * 3600 ))

# Use hourly stats for > 12h, 5-minute for shorter windows
if [[ "$HOURS" -gt 12 ]]; then
    ENDPOINT="stat/report/hourly.user"
else
    ENDPOINT="stat/report/5minutes.user"
fi

BODY=$(jq -n --argjson start "$START" --argjson end "$NOW" \
    '{attrs: ["rx_bytes","tx_bytes","time"], start: ($start * 1000), end: ($end * 1000)}')

RESULT=$(unifi_post "$ENDPOINT" "$BODY")

# Aggregate by client MAC, resolve names, sort by total bytes
echo "$RESULT" | jq --argjson clients "$CLIENT_NAMES" --argjson aps "$AP_NAMES" --argjson top "$TOP_N" '
    [.data[] | {
        mac: .user,
        rx: (.rx_bytes // 0),
        tx: (.tx_bytes // 0)
    }]
    | group_by(.mac)
    | map({
        name: ($clients[.[0].mac] // .[0].mac),
        mac: .[0].mac,
        download_mb: ([.[].rx] | add / 1048576 | . * 10 | round / 10),
        upload_mb: ([.[].tx] | add / 1048576 | . * 10 | round / 10),
        total_mb: ((([.[].rx] | add) + ([.[].tx] | add)) / 1048576 | . * 10 | round / 10)
    })
    | sort_by(-.total_mb)
    | if $top > 0 then .[:$top] else . end
    | . as $list | {
        period_hours: ('"$HOURS"'),
        clients_shown: ($list | length),
        total_network_mb: ([$list[].total_mb] | add | . * 10 | round / 10),
        clients: $list
    }'

unifi_logout
