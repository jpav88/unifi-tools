#!/bin/bash
set -euo pipefail
# Spectrum scan — show RF environment from an AP's perspective
# Usage: ./unifi_spectrum.sh <mac> [band] [width]
#   mac: AP MAC address
#   band: ng (2.4GHz), na (5GHz), 6e (default: all)
#   width: 20, 40, 80, 160, 320 (default: 20 for primary channel view)
#
# Spectrum data availability depends on AP model:
#   Dedicated scanning radio (U7 Pro Max, U7 Pro XGS, E7): continuous background data
#   All other APs: data only appears after a scan is triggered
#     The script tries the API trigger first. If that fails, use the UI:
#     (Devices > AP > Insights > RF Environment > Scan)
#     WARNING: Scans briefly take the AP offline — run during off-hours
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

MAC="${1:-}"
BAND="${2:-all}"
WIDTH="${3:-20}"

if [[ -z "$MAC" ]]; then
    echo "Usage: $0 <ap_mac> [ng|na|6e|all] [width]" >&2
    echo "  Shows cached RF spectrum scan data for each radio." >&2
    echo "  Default: all bands, 20MHz channels" >&2
    exit 1
fi

validate_mac "$MAC" || exit 1
NORM_MAC=$(normalize_mac "$MAC")

unifi_init

# Resolve AP name
AP_NAME=$(unifi_get "stat/device" | jq -r --arg mac "$NORM_MAC" \
    '.data[] | select(.mac == $mac) | .name // .mac')
if [[ -z "$AP_NAME" || "$AP_NAME" == "null" ]]; then
    echo "ERROR: AP $MAC not found" >&2
    unifi_logout
    exit 1
fi

RESULT=$(unifi_get "stat/spectrum-scan/${NORM_MAC}" 2>/dev/null) || true

if [[ -z "$RESULT" ]] || ! echo "$RESULT" | jq -e '.data[0].scans' >/dev/null 2>&1; then
    echo "ERROR: No spectrum data available for ${AP_NAME}" >&2
    echo "  Spectrum scans may need to be triggered via the UniFi UI:" >&2
    echo "  Devices > ${AP_NAME} > Insights > RF Environment > Scan" >&2
    unifi_logout
    exit 1
fi

# Check if spectrum_table is actually populated
ENTRY_COUNT=$(echo "$RESULT" | jq '[.data[0].scans[].spectrum_table | length] | add')
if [[ "$ENTRY_COUNT" -eq 0 ]]; then
    # Try to trigger a scan via API (works on some models, returns 400 on others)
    echo "${AP_NAME}: no cached data — attempting API scan trigger..." >&2
    TRIGGER=$(unifi_post "cmd/devmgr" "$(jq -n --arg mac "$NORM_MAC" \
        '{cmd: "spectrum-scan", mac: $mac}')" 2>/dev/null) || true
    TRIGGER_RC=$(echo "$TRIGGER" | jq -r '.meta.rc // "error"' 2>/dev/null)

    if [[ "$TRIGGER_RC" == "ok" ]]; then
        echo "${AP_NAME}: scan triggered — waiting 45s for results..." >&2
        echo "  WARNING: AP is offline during scan." >&2
        sleep 45
        RESULT=$(unifi_get "stat/spectrum-scan/${NORM_MAC}" 2>/dev/null) || true
        ENTRY_COUNT=$(echo "$RESULT" | jq '[.data[0].scans[].spectrum_table | length] | add' 2>/dev/null)
        if [[ "$ENTRY_COUNT" -eq 0 || -z "$ENTRY_COUNT" ]]; then
            echo "ERROR: Scan completed but no data returned. Try the UI instead:" >&2
            echo "  Devices > ${AP_NAME} > Insights > RF Environment > Scan" >&2
            unifi_logout
            exit 1
        fi
        echo "${AP_NAME}: scan complete." >&2
    else
        echo "ERROR: API trigger failed for ${AP_NAME}. Trigger via UniFi UI instead:" >&2
        echo "  Devices > ${AP_NAME} > Insights > RF Environment > Scan" >&2
        echo "  Note: Only U7 Pro Max, U7 Pro XGS, E7/E7 Campus have dedicated scanning" >&2
        echo "  radios. All other APs need a triggered scan (AP goes offline briefly)." >&2
        unifi_logout
        exit 1
    fi
fi

echo "$RESULT" | jq --arg ap "$AP_NAME" --arg band "$BAND" --argjson width "$WIDTH" '
    .data[0] as $d |
    {
        ap: $ap,
        mac: $d.mac,
        scanning: $d.spectrum_scanning,
        scan_time: ($d.scans[0].spectrum_table_time | strftime("%Y-%m-%dT%H:%M:%SZ")),
        radios: [
            $d.scans[] |
            select($band == "all" or .radio == $band) |
            {
                radio: .radio,
                radio_name: (if .radio == "ng" then "2.4GHz"
                            elif .radio == "na" then "5GHz"
                            elif .radio == "6e" then "6GHz"
                            else .radio end),
                channels: [
                    .spectrum_table[] |
                    select(.width == $width) |
                    {
                        channel,
                        freq_mhz: .center_freq,
                        interference_dbm: .interference,
                        utilization_pct: .utilization,
                        radar: (if (.interference_type | length) > 0 then .interference_type else null end)
                    }
                ] | sort_by(.channel),
                best_channels: ([
                    .spectrum_table[] |
                    select(.width == $width) |
                    {channel, score: (.utilization + (if .interference > -90 then 10 else 0 end))}
                ] | sort_by(.score) | .[0:3] | [.[].channel]),
                worst_channels: ([
                    .spectrum_table[] |
                    select(.width == $width) |
                    {channel, score: (.utilization + (if .interference > -90 then 10 else 0 end))}
                ] | sort_by(-.score) | .[0:3] | [.[].channel])
            }
        ]
    }'

unifi_logout
