#!/bin/bash
set -euo pipefail
# Channel plan validator — analyze RF environment across all APs
# Usage: ./unifi_channel_plan.sh [band]
#   band: na (5GHz, default), ng (2.4GHz), 6e (6GHz), all
#
# Pulls spectrum scan data from every AP, compares against current
# channel assignments, and flags conflicts or better alternatives.
#
# Examples:
#   ./unifi_channel_plan.sh         # 5GHz analysis (most useful)
#   ./unifi_channel_plan.sh ng      # 2.4GHz analysis
#   ./unifi_channel_plan.sh all     # all bands
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

BAND="${1:-na}"

unifi_init

DEVICES=$(unifi_get "stat/device")

# Get all AP MACs (exclude switches)
AP_LIST=$(echo "$DEVICES" | jq -r '.data[] | select(.type != "usw") | .mac')

# Collect current channel assignments
CURRENT=$(echo "$DEVICES" | jq '
    def radio_name: if . == "na" then "5GHz" elif . == "ng" then "2.4GHz" elif . == "6e" then "6GHz" else . end;
    [.data[] | select(.type != "usw") |
        .name as $name | .mac as $mac |
        (.radio_table_stats[]? | {
            ap: $name,
            ap_mac: $mac,
            band: (.radio | radio_name),
            radio: .radio,
            channel: .channel,
            width: (if .extchannel then 40 else 20 end),
            utilization: .cu_total,
            clients: .num_sta,
            satisfaction: .satisfaction
        })
    ]')

# Collect spectrum data from each AP
SPECTRUM="[]"
while IFS= read -r mac; do
    AP_NAME=$(echo "$DEVICES" | jq -r --arg mac "$mac" '.data[] | select(.mac == $mac) | .name // .mac')
    SCAN=$(unifi_get "stat/spectrum-scan/${mac}" 2>/dev/null) || continue

    # Check if scan data exists and is populated
    if ! echo "$SCAN" | jq -e '.data[0].scans' >/dev/null 2>&1; then
        continue
    fi
    ENTRY_COUNT=$(echo "$SCAN" | jq '[.data[0].scans[].spectrum_table | length] | add')
    if [[ "$ENTRY_COUNT" -eq 0 ]]; then
        echo "# ${AP_NAME}: no spectrum data — trigger scan in UI (Devices > AP > Insights > RF Environment > Scan). AP goes offline briefly during scan." >&2
        continue
    fi

    # Extract per-radio spectrum summaries
    AP_SPECTRUM=$(echo "$SCAN" | jq --arg ap "$AP_NAME" --arg mac "$mac" '
        [.data[0].scans[] | {
            ap: $ap,
            ap_mac: $mac,
            radio: .radio,
            scan_time: ((.spectrum_table_time // 0) | if . > 0 then strftime("%Y-%m-%dT%H:%M:%SZ") else "no data" end),
            channels_20mhz: [.spectrum_table[] | select(.width == 20) | {
                channel, interference: .interference, utilization: .utilization
            }] | sort_by(.channel)
        }]')

    SPECTRUM=$(jq -n --argjson a "$SPECTRUM" --argjson b "$AP_SPECTRUM" '$a + $b')
done <<< "$AP_LIST"

# Filter by requested band
if [[ "$BAND" != "all" ]]; then
    CURRENT=$(echo "$CURRENT" | jq --arg band "$BAND" '[.[] | select(.radio == $band)]')
    SPECTRUM=$(echo "$SPECTRUM" | jq --arg band "$BAND" '[.[] | select(.radio == $band)]')
fi

# --- Build analysis in stages to avoid complex jq nesting ---

# Current plan summary
PLAN=$(echo "$CURRENT" | jq '[.[] | {ap, band, channel, utilization, clients, satisfaction}]')

# Co-channel conflicts
CONFLICTS=$(echo "$CURRENT" | jq '
    group_by(.channel) | map(select(length > 1 and .[0].channel != null and .[0].channel != 0)) |
    map({channel: .[0].channel, band: .[0].band, aps: [.[].ap]})')

# Per-AP analysis with spectrum data
PER_AP=$(jq -n --argjson current "$CURRENT" --argjson spectrum "$SPECTRUM" '
    [($current[] | . as $cur |
        ($spectrum[] | select(.ap_mac == $cur.ap_mac and .radio == $cur.radio)) as $scan |
        ($scan.channels_20mhz // [] | map(select(.channel == $cur.channel)) | .[0] // {interference: -96, utilization: 0}) as $cur_spec |
        {
            ap: $cur.ap,
            band: $cur.band,
            current_channel: $cur.channel,
            current_utilization: $cur.utilization,
            current_clients: $cur.clients,
            spectrum_on_current: $cur_spec,
            best_alternatives: [
                $scan.channels_20mhz[]? |
                select(.channel != $cur.channel) |
                {channel, interference, utilization, score: (.utilization + (if .interference > -90 then 10 else 0 end))}
            ] | sort_by(.score) | .[0:3]
        }
    )]')

# Build recommendations
RECS=$(jq -n --argjson conflicts "$CONFLICTS" --argjson per_ap "$PER_AP" '
    [
        $conflicts[] | {
            type: "co_channel",
            severity: "HIGH",
            detail: ("Channel \(.channel) (\(.band)): \(.aps | join(" and ")) share the same channel")
        }
    ] + [
        $per_ap[] |
        select(.spectrum_on_current.utilization > 30) |
        {
            type: "high_utilization",
            severity: (if .spectrum_on_current.utilization > 50 then "HIGH" else "MEDIUM" end),
            detail: ("\(.ap) ch\(.current_channel): \(.spectrum_on_current.utilization)% util. Consider ch\((.best_alternatives[0].channel // "?"))")
        }
    ] + [
        $per_ap[] |
        select(.spectrum_on_current.interference > -80) |
        {
            type: "interference",
            severity: "MEDIUM",
            detail: ("\(.ap) ch\(.current_channel): \(.spectrum_on_current.interference) dBm interference. Try: \([.best_alternatives[].channel] | join(", "))")
        }
    ]')

# Final output
jq -n --argjson plan "$PLAN" --argjson conflicts "$CONFLICTS" --argjson per_ap "$PER_AP" --argjson recs "$RECS" '{
    current_plan: $plan,
    conflicts: $conflicts,
    per_ap_analysis: $per_ap,
    recommendations: $recs
}'

unifi_logout
