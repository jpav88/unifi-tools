#!/bin/bash
set -euo pipefail
# Set an AP's radio channel and width safely.
# Usage: ./unifi_channel.sh <ap_name|ap_mac> <band> <channel|auto> <width>
#   band:  ng = 2.4GHz, na = 5GHz, 6e = 6GHz
#
# Why this exists: radio changes need the device _id (not the MAC) and a PUT of the WHOLE
# radio_table. Hand-building that JSON is error-prone — a partial radio_table can wipe the
# other bands' settings. This reads the live table, edits exactly one radio, and writes it back.
#
# Examples:
#   ./unifi_channel.sh UDM na 149 40
#   ./unifi_channel.sh "U7 Pro Max" na 36 40
#   ./unifi_channel.sh --dry-run "Bedroom-NanoHD" na 44 40
#   ./unifi_channel.sh --show                     # print current plan for all APs
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

DRY=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY=1; shift; fi

unifi_init

# --show: current channel plan, config vs OPERATING (they can differ after a DFS radar move)
if [[ "${1:-}" == "--show" ]]; then
    unifi_get "stat/device" | jq -r '
        .data[] | select(.radio_table) | . as $d
        | .radio_table[]
        | . as $r
        | ($d.radio_table_stats // [] | map(select(.radio == $r.radio)) | first) as $s
        | "\($d.name)\t\($r.radio)\tcfg_ch=\($r.channel)/\($r.ht)\top_ch=\($s.channel // "?")\tCU=\($s.cu_total // "?")%\tmin_rssi=\(if $r.min_rssi_enabled then $r.min_rssi else "off" end)"
    ' | column -t -s $'\t'
    unifi_logout
    exit 0
fi

TARGET="${1:-}"; BAND="${2:-}"; CHAN="${3:-}"; WIDTH="${4:-}"
if [[ -z "$TARGET" || -z "$BAND" || -z "$CHAN" || -z "$WIDTH" ]]; then
    echo "Usage: $0 [--dry-run] <ap_name|ap_mac> <ng|na|6e> <channel|auto> <width>" >&2
    echo "       $0 --show" >&2
    unifi_logout; exit 1
fi

case "$BAND" in
    ng|na|6e) ;;
    *) echo "ERROR: band must be ng (2.4GHz), na (5GHz) or 6e (6GHz), got '$BAND'" >&2
       unifi_logout; exit 1 ;;
esac

DEVICES=$(unifi_get "stat/device")

# Resolve by exact name first, then by MAC
DEV=$(echo "$DEVICES" | jq -c --arg t "$TARGET" \
    '[.data[] | select(.radio_table) | select(.name == $t or .mac == ($t|ascii_downcase))] | first // empty')
if [[ -z "$DEV" ]]; then
    echo "ERROR: no radio-capable device matched '$TARGET'. Known:" >&2
    echo "$DEVICES" | jq -r '.data[] | select(.radio_table) | "  \(.name)  \(.mac)"' >&2
    unifi_logout; exit 1
fi

DEV_ID=$(echo "$DEV" | jq -r '._id')
DEV_NAME=$(echo "$DEV" | jq -r '.name')

if ! echo "$DEV" | jq -e --arg b "$BAND" '.radio_table[] | select(.radio == $b)' >/dev/null; then
    echo "ERROR: $DEV_NAME has no '$BAND' radio. It has:" >&2
    echo "$DEV" | jq -r '.radio_table[] | "  \(.radio)"' >&2
    unifi_logout; exit 1
fi

OLD=$(echo "$DEV" | jq -r --arg b "$BAND" '.radio_table[] | select(.radio==$b) | "ch\(.channel)/\(.ht)"')

# "auto" stays a string; a numeric channel must stay numeric or the controller rejects it.
if [[ "$CHAN" == "auto" ]]; then
    BODY=$(echo "$DEV" | jq -c --arg b "$BAND" --argjson w "$WIDTH" \
        '{radio_table: [.radio_table[] | if .radio==$b then (.channel="auto" | .ht=$w) else . end]}')
else
    BODY=$(echo "$DEV" | jq -c --arg b "$BAND" --argjson c "$CHAN" --argjson w "$WIDTH" \
        '{radio_table: [.radio_table[] | if .radio==$b then (.channel=$c | .ht=$w) else . end]}')
fi

echo "$DEV_NAME ($BAND): $OLD -> ch${CHAN}/${WIDTH}"

if [[ "$DRY" == "1" ]]; then
    echo "[dry-run] would PUT rest/device/${DEV_ID}"
    echo "$BODY" | jq '.radio_table[] | {radio, channel, ht}'
    unifi_logout; exit 0
fi

unifi_put "rest/device/${DEV_ID}" "$BODY" | jq -c '.meta'
unifi_logout
