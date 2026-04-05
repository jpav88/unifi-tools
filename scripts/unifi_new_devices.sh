#!/bin/bash
set -euo pipefail
# Detect unknown devices on the network
# Usage: ./unifi_new_devices.sh [--learn] [--all]
#   No args:  show devices not in the known-devices list
#   --learn:  add all current devices to the known list (first-time setup)
#   --all:    show all connected clients with known/unknown status
#
# Known devices are stored in local/known_devices.txt (one MAC per line).
# Run with --learn once to seed it, then run periodically to catch new devices.
#
# Examples:
#   ./unifi_new_devices.sh              # show unknown devices only
#   ./unifi_new_devices.sh --learn      # add all current devices to known list
#   ./unifi_new_devices.sh --all        # show all with known/unknown flag
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

KNOWN_FILE="${PROJECT_DIR}/local/known_devices.txt"
MODE="${1:-check}"

# Ensure local dir exists
mkdir -p "${PROJECT_DIR}/local"

if [[ "$MODE" == "--learn" ]]; then
    unifi_init

    # Get all known clients (ever connected)
    ALL_MACS=$(unifi_get "stat/alluser" | jq -r '.data[].mac' | sort -u)

    # Merge with existing known list if it exists
    if [[ -f "$KNOWN_FILE" ]]; then
        EXISTING=$(cat "$KNOWN_FILE")
        ALL_MACS=$(printf "%s\n%s" "$ALL_MACS" "$EXISTING" | sort -u)
    fi

    echo "$ALL_MACS" > "$KNOWN_FILE"
    COUNT=$(wc -l < "$KNOWN_FILE" | tr -d ' ')
    echo "Learned ${COUNT} devices → ${KNOWN_FILE}"

    unifi_logout
    exit 0
fi

# Check mode — need the known list
if [[ ! -f "$KNOWN_FILE" ]]; then
    echo "No known devices list found. Run with --learn first:" >&2
    echo "  $0 --learn" >&2
    exit 1
fi

unifi_init

# Build AP name lookup
AP_NAMES=$(unifi_get "stat/device-basic" | jq '[.data[] | {(.mac): (.name // .mac)}] | add // {}')

# Get currently connected clients
CLIENTS=$(unifi_get "stat/sta" | jq --argjson aps "$AP_NAMES" '[.data[] | {
    name: (.name // .hostname // "unnamed"),
    mac,
    ip: (.ip // "no ip"),
    is_wired,
    essid: (.essid // "wired"),
    ap: (if .is_wired then "wired" else ($aps[.ap_mac] // .ap_mac // "unknown") end),
    signal: (if .is_wired then null else .signal end),
    first_seen: (if .first_seen then (.first_seen | todate) else null end)
}]')

# Load known MACs into a jq-friendly format
KNOWN_MACS=$(jq -R -s 'split("\n") | map(select(length > 0))' < "$KNOWN_FILE")

if [[ "$MODE" == "--all" ]]; then
    # Show all clients with known/unknown status
    echo "$CLIENTS" | jq --argjson known "$KNOWN_MACS" '
        [.[] | . + {status: (if (.mac | IN($known[])) then "known" else "UNKNOWN" end)}]
        | sort_by(.status, .name)'
else
    # Show only unknown devices
    UNKNOWN=$(echo "$CLIENTS" | jq --argjson known "$KNOWN_MACS" '
        [.[] | select(.mac | IN($known[]) | not)]')

    COUNT=$(echo "$UNKNOWN" | jq 'length')
    if [[ "$COUNT" -eq 0 ]]; then
        echo "No unknown devices detected."
    else
        echo "$UNKNOWN" | jq '.'
        echo ""
        echo "${COUNT} unknown device(s) found. To mark them as known:"
        echo "  $0 --learn"
    fi
fi

unifi_logout
