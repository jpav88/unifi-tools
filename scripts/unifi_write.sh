#!/bin/bash
set -euo pipefail
# Write operations — reboot, block, kick, update radio, min_rssi
# Usage: ./unifi_write.sh <command> <mac> [extra_args]
#
# Commands:
#   reboot <mac>                        — reboot a device
#   provision <mac>                     — force provision a device
#   kick <mac>                          — disconnect a client
#   block <mac>                         — block a client
#   unblock <mac>                       — unblock a client
#   radio <device_id> <json>            — update device radio_table (PUT rest/device/<id>)
#   min_rssi <device_mac> <radio> <val> — set min_rssi on a radio (e.g. na -72, or na off)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

CMD="${1:-}"
ARG="${2:-}"

if [[ -z "$CMD" || -z "$ARG" ]]; then
    echo "Usage: $0 <command> <mac> [extra_args]" >&2
    echo "Commands: reboot, provision, kick, block, unblock, radio, min_rssi" >&2
    exit 1
fi

_resolve_cmd() {
    case "$1" in
        reboot)    echo "cmd/devmgr restart" ;;
        provision) echo "cmd/devmgr force-provision" ;;
        kick)      echo "cmd/stamgr kick-sta" ;;
        block)     echo "cmd/stamgr block-sta" ;;
        unblock)   echo "cmd/stamgr unblock-sta" ;;
        *)         return 1 ;;
    esac
}

unifi_init

if [[ "$CMD" == "min_rssi" ]]; then
    # min_rssi <device_mac> <radio> <value|off>
    # Fetches current radio_table, modifies the target radio, PUTs it back
    validate_mac "$ARG" || exit 1
    RADIO="${3:-}"
    VALUE="${4:-}"
    if [[ -z "$RADIO" || -z "$VALUE" ]]; then
        echo "Usage: $0 min_rssi <device_mac> <radio> <value|off>" >&2
        echo "  radio: ng (2.4GHz), na (5GHz), 6e" >&2
        echo "  value: negative dBm (e.g. -72) or 'off' to disable" >&2
        exit 1
    fi

    # Resolve device _id and get radio_table
    DEVICE_JSON=$(unifi_get "stat/device" | jq --arg mac "$ARG" '.data[] | select(.mac == $mac)')
    if [[ -z "$DEVICE_JSON" || "$DEVICE_JSON" == "null" ]]; then
        echo "ERROR: Device $ARG not found" >&2
        exit 1
    fi
    DEVICE_ID=$(echo "$DEVICE_JSON" | jq -r '._id')
    DEVICE_NAME=$(echo "$DEVICE_JSON" | jq -r '.name // .mac')

    # Build updated radio_table
    if [[ "$VALUE" == "off" ]]; then
        UPDATED=$(echo "$DEVICE_JSON" | jq --arg r "$RADIO" \
            '[.radio_table[] | if .radio == $r then .min_rssi_enabled = false else . end]')
        echo "Disabling min_rssi on ${DEVICE_NAME} radio ${RADIO}"
    else
        UPDATED=$(echo "$DEVICE_JSON" | jq --arg r "$RADIO" --argjson v "$VALUE" \
            '[.radio_table[] | if .radio == $r then .min_rssi_enabled = true | .min_rssi = $v else . end]')
        echo "Setting min_rssi=${VALUE} on ${DEVICE_NAME} radio ${RADIO}"
    fi

    unifi_put "rest/device/${DEVICE_ID}" "{\"radio_table\": $UPDATED}" | jq '.meta'

elif [[ "$CMD" == "radio" ]]; then
    DEVICE_ID="$ARG"
    BODY="${3:-}"
    if [[ -z "$BODY" ]]; then
        echo "Usage: $0 radio <device_id> '<json_body>'" >&2
        exit 1
    fi
    unifi_put "rest/device/${DEVICE_ID}" "$BODY" | jq '.meta'
elif resolved=$(_resolve_cmd "$CMD"); then
    validate_mac "$ARG" || exit 1
    read -r api_path api_cmd <<< "$resolved"
    unifi_post "$api_path" "$(jq -n --arg mac "$ARG" --arg cmd "$api_cmd" \
        '{cmd: $cmd, mac: $mac}')" | jq '.meta'
else
    echo "Unknown command: $CMD" >&2
    echo "Commands: reboot, provision, kick, block, unblock, radio, min_rssi" >&2
    exit 1
fi

unifi_logout
