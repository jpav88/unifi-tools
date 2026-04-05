#!/bin/bash
set -euo pipefail
# Capture a baseline snapshot of network state for Claude session context
# Writes JSON to snapshots/session_baseline.json and outputs a 1-line summary
# Usage: ./unifi_snapshot.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/unifi_auth.sh"
unifi_init

SNAPSHOT_DIR="${PROJECT_DIR}/snapshots"
mkdir -p "$SNAPSHOT_DIR"
OUTFILE="${SNAPSHOT_DIR}/session_baseline.json"

# Load device config (iPad MACs, AP mappings)
LOCAL_DEVICES="${PROJECT_DIR}/local/devices.sh"
if [[ ! -f "$LOCAL_DEVICES" ]]; then
    echo "ERROR: local/devices.sh not found. Copy local/devices.sh.example and fill in your MACs." >&2
    exit 1
fi
source "$LOCAL_DEVICES"

# Pull all data in as few API calls as possible
HEALTH=$(unifi_get "stat/health" 2>/dev/null || echo '{"data":[]}')
DEVICES=$(unifi_get "stat/device" 2>/dev/null || echo '{"data":[]}')
CLIENTS=$(unifi_get "stat/sta" 2>/dev/null || echo '{"data":[]}')

# Extract iPad state
IPAD=$(echo "$CLIENTS" | jq --arg mac "$IPAD_PRIMARY" --arg mac2 "$IPAD_SECONDARY" '
    [.data[] | select(.mac == $mac or .mac == $mac2) | {
        mac, ip, essid, ap_mac, channel,
        radio: .radio,
        signal: .signal,
        satisfaction,
        tx_rate: .tx_rate,
        rx_rate: .rx_rate,
        uptime_seconds: .uptime,
        assoc_time: (.assoc_time | todate)
    }]')

# Extract AP configs (radio_table with min_rssi, tx_power, channels)
AP_CONFIGS=$(echo "$DEVICES" | jq '
    [.data[] | select(.type == "uap" or .type == "udm") | {
        name, mac, model,
        state: (if .state == 1 then "online" else "offline" end),
        clients: .num_sta,
        radios: [.radio_table[]? | {
            radio, channel, ht,
            tx_power_mode,
            min_rssi_enabled, min_rssi
        }],
        radio_stats: [.radio_table_stats[]? | {
            radio, channel,
            tx_power,
            cu_total,
            num_sta: .num_sta
        }]
    }]')

# Extract switch port states
SWITCHES=$(echo "$DEVICES" | jq '
    [.data[] | select(.type == "usw") | {
        name, mac, model,
        state: (if .state == 1 then "online" else "offline" end),
        ports: [.port_table[]? | {
            port_idx, name, up, speed,
            poe_enable,
            poe_power: (.poe_power // null),
            media
        }]
    }]')

# iPad session history (last 24h)
SESSION_END=$(date +%s)
SESSION_START=$((SESSION_END - 24 * 3600))
IPAD_SESSIONS=$(unifi_get "stat/session?type=all&start=${SESSION_START}&end=${SESSION_END}&mac=${IPAD_PRIMARY}" 2>/dev/null | jq '
    [.data[] | {
        start: (.assoc_time | todate),
        end: ((.assoc_time + .duration) | todate),
        duration_min: ((.duration // 0) / 60 | floor),
        ap_mac: .ap_mac,
        satisfaction,
        is_micro: ((.duration // 0) < 60),
        roaming: [.roaming_sessions[]? | {
            ap_mac,
            duration_sec: .duration,
            satisfaction
        }]
    }] | sort_by(.start)' 2>/dev/null || echo '[]')

# Network summary
WLAN_STATUS=$(echo "$HEALTH" | jq -r '.data[] | select(.subsystem=="wlan") | .status // "unknown"')
WIFI_CLIENTS=$(echo "$CLIENTS" | jq '[.data[] | select(.is_wired == false)] | length')
AP_ONLINE=$(echo "$DEVICES" | jq '[.data[] | select((.type == "uap" or .type == "udm") and .state == 1)] | length')
AP_TOTAL=$(echo "$DEVICES" | jq '[.data[] | select(.type == "uap" or .type == "udm")] | length')

# Switch summary counts
SW_TOTAL=$(echo "$SWITCHES" | jq 'length')
SW_PORTS_UP=$(echo "$SWITCHES" | jq '[.[].ports[] | select(.up == true)] | length')

# Build snapshot
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg wlan "$WLAN_STATUS" \
    --argjson wifi "$WIFI_CLIENTS" \
    --argjson ap_on "$AP_ONLINE" \
    --argjson ap_tot "$AP_TOTAL" \
    --argjson ipad "$IPAD" \
    --argjson aps "$AP_CONFIGS" \
    --argjson sws "$SWITCHES" \
    --argjson sessions "$IPAD_SESSIONS" \
    '{
        timestamp: $ts,
        network: { wlan_status: $wlan, wifi_clients: $wifi, aps_online: $ap_on, aps_total: $ap_tot },
        ipad: $ipad,
        ipad_sessions_24h: $sessions,
        access_points: $aps,
        switches: $sws
    }' > "$OUTFILE"

# Output 1-line summary for SessionStart hook
IPAD_AP=$(echo "$IPAD" | jq -r '.[0].ap_mac // "disconnected"')
IPAD_SIG=$(echo "$IPAD" | jq -r '.[0].signal // "n/a"')

# Build switch port alert (flag any non-1G links or down ports with PoE devices)
SW_ALERTS=$(echo "$SWITCHES" | jq -r '
    [.[] | .name as $sw | .ports[] |
        select(.up == true and .speed < 1000) |
        "\($sw) P\(.port_idx):\(.speed)M"
    ] | if length > 0 then "⚠️  " + join(", ") else "" end')

SW_BRIEF="${SW_TOTAL} switches, ${SW_PORTS_UP} ports up"

SUMMARY="Network: ${WLAN_STATUS}, ${WIFI_CLIENTS} wifi clients, ${AP_ONLINE}/${AP_TOTAL} APs online, ${SW_BRIEF} | iPad: ${IPAD_AP} (${IPAD_SIG} dBm)"
if [[ -n "$SW_ALERTS" ]]; then
    SUMMARY="${SUMMARY} | ${SW_ALERTS}"
fi
echo "${SUMMARY} | Snapshot: snapshots/session_baseline.json"

unifi_logout
