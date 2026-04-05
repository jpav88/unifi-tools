#!/bin/bash
set -euo pipefail
# Write operations for UniFi devices and clients
# Usage: ./unifi_write.sh <command> <mac> [extra_args]
#
# Commands:
#   reboot <mac>                        — reboot a device (AP, switch, gateway)
#   provision <mac>                     — force re-provision a device
#   kick <mac>                          — disconnect a Wi-Fi client (forces reconnect)
#   block <mac>                         — block a client from the network
#   unblock <mac>                       — unblock a previously blocked client
#   rename <mac> <name>                 — set/change a client's display name
#   poe_cycle <switch_mac> <port>       — power-cycle a PoE switch port (remotely reboot an AP)
#   min_rssi <ap_mac> <band> <dBm|off>  — set minimum signal threshold on an AP radio
#   radio <device_id> <json>            — raw radio_table update (advanced)
#
# Examples:
#   ./unifi_write.sh reboot aa:bb:cc:dd:ee:ff
#   ./unifi_write.sh kick aa:bb:cc:dd:ee:ff
#   ./unifi_write.sh rename aa:bb:cc:dd:ee:ff "Living Room TV"
#   ./unifi_write.sh poe_cycle aa:bb:cc:dd:ee:ff 2
#   ./unifi_write.sh min_rssi aa:bb:cc:dd:ee:ff na -75
#   ./unifi_write.sh min_rssi aa:bb:cc:dd:ee:ff na off
#
# Radio bands: ng = 2.4GHz, na = 5GHz, 6e = 6GHz
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

CMD="${1:-}"
ARG="${2:-}"

if [[ -z "$CMD" || -z "$ARG" || "$CMD" == "--help" || "$CMD" == "-h" ]]; then
    echo "Usage: $0 <command> <mac> [extra_args]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  reboot <mac>                       Reboot a device" >&2
    echo "  provision <mac>                    Force re-provision a device" >&2
    echo "  kick <mac>                         Disconnect a client" >&2
    echo "  block <mac>                        Block a client" >&2
    echo "  unblock <mac>                      Unblock a client" >&2
    echo "  rename <mac> <name>                Set client display name" >&2
    echo "  poe_cycle <switch_mac> <port>      Power-cycle a PoE port" >&2
    echo "  min_rssi <ap_mac> <band> <dBm|off> Set min signal threshold" >&2
    echo "  radio <device_id> <json>           Raw radio_table update" >&2
    echo "" >&2
    echo "Bands: ng = 2.4GHz, na = 5GHz, 6e = 6GHz" >&2
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

if [[ "$CMD" == "rename" ]]; then
    # rename <mac> <name> — set client alias via upd/user (partial update, no 403)
    validate_mac "$ARG" || exit 1
    NEW_NAME="${3:-}"
    if [[ -z "$NEW_NAME" ]]; then
        echo "Usage: $0 rename <mac> <name>" >&2
        exit 1
    fi

    # Resolve client _id from MAC
    CLIENT_ID=$(unifi_get "stat/alluser" | jq -r --arg mac "$(normalize_mac "$ARG")" \
        '.data[] | select(.mac == $mac) | ._id' | head -1)
    if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == "null" ]]; then
        echo "ERROR: Client $ARG not found" >&2
        exit 1
    fi

    echo "Renaming client $ARG → \"${NEW_NAME}\" (_id: ${CLIENT_ID})"
    unifi_put "upd/user/${CLIENT_ID}" "$(jq -n --arg n "$NEW_NAME" '{name: $n}')" | jq '.meta'

elif [[ "$CMD" == "poe_cycle" ]]; then
    # poe_cycle <switch_mac> <port_idx> — power-cycle a PoE port
    validate_mac "$ARG" || exit 1
    PORT_IDX="${3:-}"
    if [[ -z "$PORT_IDX" ]]; then
        echo "Usage: $0 poe_cycle <switch_mac> <port_idx>" >&2
        exit 1
    fi
    # Resolve switch name for confirmation
    SW_NAME=$(unifi_get "stat/device" | jq -r --arg mac "$(normalize_mac "$ARG")" \
        '.data[] | select(.mac == $mac) | .name // .mac')
    if [[ -z "$SW_NAME" || "$SW_NAME" == "null" ]]; then
        echo "ERROR: Switch $ARG not found" >&2
        exit 1
    fi
    echo "Power-cycling ${SW_NAME} port ${PORT_IDX}"
    unifi_post "cmd/devmgr" "$(jq -n --arg mac "$(normalize_mac "$ARG")" --argjson port "$PORT_IDX" \
        '{cmd: "power-cycle", mac: $mac, port_idx: $port}')" | jq '.meta'

elif [[ "$CMD" == "min_rssi" ]]; then
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
    DEVICE_JSON=$(unifi_get "stat/device" | jq --arg mac "$(normalize_mac "$ARG")" '.data[] | select(.mac == $mac)')
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
    echo "Commands: reboot, provision, kick, block, unblock, rename, poe_cycle, radio, min_rssi" >&2
    exit 1
fi

unifi_logout
