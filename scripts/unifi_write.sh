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
#   fixed_ip <mac> <ip|off>             — reserve a DHCP fixed IP for a client (off = remove)
#   poe_cycle <switch_mac> <port>       — power-cycle a PoE switch port (remotely reboot an AP)
#   min_rssi <ap_mac> <band> <dBm|off>  — set minimum signal threshold on an AP radio
#   port_forward list                   — list WAN port-forward rules
#   port_forward add <name> <ext_port> <fwd_ip> <fwd_port> [proto]
#                                       — create a WAN port-forward rule (proto: tcp|udp|tcp_udp, default tcp_udp)
#   port_forward del <name|id>          — delete a port-forward rule by name or _id
#   game list                           — list built-in game-server presets
#   game add <game> <fwd_ip>            — open all ports a game server needs, in one shot
#   game del <game>                     — remove a game server's port-forward rules
#   wlan <ssid_name|_id> <on|off>       — enable/disable an SSID (reversible)
#   radio <device_id> <json>            — raw radio_table update (advanced)
#
# Examples:
#   ./unifi_write.sh reboot xx:xx:xx:xx:xx:xx
#   ./unifi_write.sh kick xx:xx:xx:xx:xx:xx
#   ./unifi_write.sh rename xx:xx:xx:xx:xx:xx "Living Room TV"
#   ./unifi_write.sh fixed_ip xx:xx:xx:xx:xx:xx 192.168.1.143
#   ./unifi_write.sh poe_cycle xx:xx:xx:xx:xx:xx 2
#   ./unifi_write.sh min_rssi xx:xx:xx:xx:xx:xx na -75
#   ./unifi_write.sh min_rssi xx:xx:xx:xx:xx:xx na off
#   ./unifi_write.sh port_forward add "Satisfactory 7777" 7777 192.168.1.131 7777 tcp_udp
#   ./unifi_write.sh port_forward list
#   ./unifi_write.sh port_forward del "Satisfactory 7777"
#   ./unifi_write.sh game add satisfactory 192.168.1.131
#   ./unifi_write.sh game list
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
    echo "  fixed_ip <mac> <ip|off>            Reserve DHCP fixed IP (off = remove)" >&2
    echo "  poe_cycle <switch_mac> <port>      Power-cycle a PoE port" >&2
    echo "  min_rssi <ap_mac> <band> <dBm|off> Set min signal threshold" >&2
    echo "  port_forward list                  List WAN port-forward rules" >&2
    echo "  port_forward add <name> <ext_port> <fwd_ip> <fwd_port> [proto]" >&2
    echo "                                     Create a WAN port-forward rule" >&2
    echo "  port_forward del <name|id>         Delete a port-forward rule" >&2
    echo "  game list                          List game-server presets" >&2
    echo "  game add <game> <fwd_ip>           Open all ports a game server needs" >&2
    echo "  game del <game>                    Remove a game's port-forward rules" >&2
    echo "  auto_update status                 Show device/app firmware auto-upgrade + window
  auto_update hour <0-23>            Set the device auto-upgrade window (local hour)
  auto_update on|off                 Enable/disable device firmware auto-upgrade
  radio <device_id> <json>           Raw radio_table update" >&2
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

# Game-server port-forward presets. Echoes one "<ruleName>|<ext_port>|<fwd_port>|<proto>"
# line per rule the game needs; returns 1 for an unknown game. Ports verified against
# each game's official docs (not stale forum guides).
_game_ports() {
    case "$1" in
        satisfactory) printf '%s\n' "Satisfactory 7777|7777|7777|tcp_udp" "Satisfactory 8888|8888|8888|tcp" ;;
        minecraft)    printf '%s\n' "Minecraft|25565|25565|tcp" ;;
        valheim)      printf '%s\n' "Valheim|2456-2457|2456-2457|udp" ;;
        terraria)     printf '%s\n' "Terraria|7777|7777|tcp" ;;
        palworld)     printf '%s\n' "Palworld|8211|8211|udp" ;;
        ark)          printf '%s\n' "ARK Game|7777|7777|udp" "ARK Query|27015|27015|udp" ;;
        *)            return 1 ;;
    esac
}
_game_list() { printf '%s\n' satisfactory minecraft valheim terraria palworld ark; }

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

elif [[ "$CMD" == "fixed_ip" ]]; then
    # fixed_ip <mac> <ip|off> — set/remove a DHCP fixed-IP reservation via upd/user
    validate_mac "$ARG" || exit 1
    FIXED_IP="${3:-}"
    if [[ -z "$FIXED_IP" ]]; then
        echo "Usage: $0 fixed_ip <mac> <ip|off>" >&2
        exit 1
    fi

    # Resolve client _id from MAC
    CLIENT_ID=$(unifi_get "stat/alluser" | jq -r --arg mac "$(normalize_mac "$ARG")" \
        '.data[] | select(.mac == $mac) | ._id' | head -1)
    if [[ -z "$CLIENT_ID" || "$CLIENT_ID" == "null" ]]; then
        echo "ERROR: Client $ARG not found" >&2
        exit 1
    fi

    if [[ "$FIXED_IP" == "off" ]]; then
        echo "Removing fixed IP for client $ARG (_id: ${CLIENT_ID})"
        unifi_put "upd/user/${CLIENT_ID}" '{"use_fixedip": false}' | jq '.meta'
    else
        if ! [[ "$FIXED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "ERROR: '$FIXED_IP' is not a valid IPv4 address" >&2
            exit 1
        fi
        # network_id is required for the reservation; take it from the client's
        # current record if present, else the site's default LAN
        NETWORK_ID=$(unifi_get "stat/sta" | jq -r --arg mac "$(normalize_mac "$ARG")" \
            '.data[] | select(.mac == $mac) | .network_id // empty' | head -1)
        if [[ -z "$NETWORK_ID" ]]; then
            NETWORK_ID=$(unifi_get "rest/networkconf" | jq -r \
                '[.data[] | select(.purpose == "corporate")][0]._id // empty')
        fi
        if [[ -z "$NETWORK_ID" ]]; then
            echo "ERROR: Could not resolve network_id for reservation" >&2
            exit 1
        fi

        echo "Reserving ${FIXED_IP} for client $ARG (_id: ${CLIENT_ID}, network: ${NETWORK_ID})"
        unifi_put "upd/user/${CLIENT_ID}" "$(jq -n --arg ip "$FIXED_IP" --arg net "$NETWORK_ID" \
            '{use_fixedip: true, fixed_ip: $ip, network_id: $net}')" | jq '.meta'
    fi

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

elif [[ "$CMD" == "port_forward" ]]; then
    # port_forward list | add <name> <ext_port> <fwd_ip> <fwd_port> [proto] | del <name|id>
    SUB="$ARG"
    case "$SUB" in
        list)
            unifi_get "rest/portforward" | jq -r '
                if (.data | length) == 0 then "No port-forward rules configured."
                else (.data[] | "\(if .enabled then "on " else "off" end)  \(.name)  [\(.proto)]  WAN:\(.dst_port) → \(.fwd):\(.fwd_port)  (\(._id))")
                end'
            ;;
        add)
            NAME="${3:-}"; EXT_PORT="${4:-}"; FWD_IP="${5:-}"; FWD_PORT="${6:-}"; PROTO="${7:-tcp_udp}"
            if [[ -z "$NAME" || -z "$EXT_PORT" || -z "$FWD_IP" || -z "$FWD_PORT" ]]; then
                echo "Usage: $0 port_forward add <name> <ext_port> <fwd_ip> <fwd_port> [proto]" >&2
                echo "  proto: tcp | udp | tcp_udp (default tcp_udp)" >&2
                echo "  ports: single (7777) or range (7000-8000)" >&2
                exit 1
            fi
            if ! [[ "$FWD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo "ERROR: '$FWD_IP' is not a valid IPv4 address" >&2
                exit 1
            fi
            if ! [[ "$EXT_PORT" =~ ^[0-9]+(-[0-9]+)?$ && "$FWD_PORT" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
                echo "ERROR: ports must be a number (7777) or range (7000-8000)" >&2
                exit 1
            fi
            case "$PROTO" in tcp|udp|tcp_udp) ;; *)
                echo "ERROR: proto must be tcp, udp, or tcp_udp" >&2; exit 1 ;;
            esac
            echo "Creating port-forward '${NAME}': WAN ${PROTO} ${EXT_PORT} → ${FWD_IP}:${FWD_PORT}"
            unifi_post "rest/portforward" "$(jq -n \
                --arg name "$NAME" --arg dp "$EXT_PORT" --arg fwd "$FWD_IP" \
                --arg fp "$FWD_PORT" --arg proto "$PROTO" \
                '{name: $name, enabled: true, pfwd_interface: "wan", src: "any",
                  dst_port: $dp, fwd: $fwd, fwd_port: $fp, proto: $proto, log: false}')" \
                | jq '.meta'
            ;;
        del)
            TARGET="${3:-}"
            if [[ -z "$TARGET" ]]; then
                echo "Usage: $0 port_forward del <name|id>" >&2
                exit 1
            fi
            # Accept a 24-char hex _id directly, else resolve by name
            if [[ "$TARGET" =~ ^[0-9a-f]{24}$ ]]; then
                RULE_ID="$TARGET"
            else
                RULE_ID=$(unifi_get "rest/portforward" | jq -r --arg n "$TARGET" \
                    '.data[] | select(.name == $n) | ._id' | head -1)
            fi
            if [[ -z "$RULE_ID" || "$RULE_ID" == "null" ]]; then
                echo "ERROR: Port-forward rule '$TARGET' not found" >&2
                exit 1
            fi
            echo "Deleting port-forward rule ${TARGET} (_id: ${RULE_ID})"
            unifi_delete "rest/portforward/${RULE_ID}" | jq '.meta'
            ;;
        *)
            echo "Usage: $0 port_forward <list|add|del> ..." >&2
            exit 1
            ;;
    esac

elif [[ "$CMD" == "game" ]]; then
    # game list | add <game> <fwd_ip> | del <game>
    # One-shot: create/remove every port-forward a named game server needs.
    SUB="$ARG"
    case "$SUB" in
        list)
            echo "Supported game presets:"
            for g in $(_game_list); do
                ports=$(_game_ports "$g" | awk -F'|' '{printf "%s/%s ", $2, $4}')
                printf "  %-14s %s\n" "$g" "$ports"
            done
            ;;
        add|del)
            GAME=$(echo "${3:-}" | tr '[:upper:]' '[:lower:]')
            FWD_IP="${4:-}"
            if [[ -z "$GAME" ]]; then
                echo "Usage: $0 game $SUB <game> $([[ "$SUB" == add ]] && echo '<fwd_ip>')" >&2
                echo "  games: $(_game_list | tr '\n' ' ')" >&2
                exit 1
            fi
            SPECS=$(_game_ports "$GAME") || {
                echo "ERROR: unknown game '$GAME'. Supported: $(_game_list | tr '\n' ' ')" >&2
                exit 1
            }

            if [[ "$SUB" == "add" ]]; then
                if ! [[ "$FWD_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    echo "ERROR: '$FWD_IP' is not a valid IPv4 address" >&2
                    echo "Usage: $0 game add <game> <fwd_ip>" >&2
                    exit 1
                fi
                while IFS='|' read -r RNAME EPORT FPORT PROTO; do
                    [[ -z "$RNAME" ]] && continue
                    echo "Creating '${RNAME}': WAN ${PROTO} ${EPORT} → ${FWD_IP}:${FPORT}"
                    unifi_post "rest/portforward" "$(jq -n \
                        --arg name "$RNAME" --arg dp "$EPORT" --arg fwd "$FWD_IP" \
                        --arg fp "$FPORT" --arg proto "$PROTO" \
                        '{name: $name, enabled: true, pfwd_interface: "wan", src: "any",
                          dst_port: $dp, fwd: $fwd, fwd_port: $fp, proto: $proto, log: false}')" \
                        | jq '.meta'
                done <<< "$SPECS"
            else
                # del — remove each preset rule by exact name match
                RULES_JSON=$(unifi_get "rest/portforward")
                while IFS='|' read -r RNAME _; do
                    [[ -z "$RNAME" ]] && continue
                    RULE_ID=$(echo "$RULES_JSON" | jq -r --arg n "$RNAME" \
                        '.data[] | select(.name == $n) | ._id' | head -1)
                    if [[ -z "$RULE_ID" || "$RULE_ID" == "null" ]]; then
                        echo "Skipping '${RNAME}' — no matching rule found"
                        continue
                    fi
                    echo "Deleting '${RNAME}' (_id: ${RULE_ID})"
                    unifi_delete "rest/portforward/${RULE_ID}" | jq '.meta'
                done <<< "$SPECS"
            fi
            ;;
        *)
            echo "Usage: $0 game <list|add|del> ..." >&2
            exit 1
            ;;
    esac

elif [[ "$CMD" == "auto_update" ]]; then
    # auto_update status | hour <0-23> | on | off
    #
    # Device firmware auto-upgrade lives in rest/setting/mgmt as auto_upgrade +
    # auto_upgrade_hour. The UDR7's own UniFi OS build is reported as that device's
    # firmware, so this window is what schedules the gateway's ~3am reboot too.
    # Partial updates go via POST set/setting/mgmt (PUT rest/setting needs the full doc).
    SUB="${ARG:-status}"
    MGMT=$(unifi_get "rest/setting/mgmt" | jq '.data[0]')
    CUR_ON=$(echo "$MGMT" | jq -r '.auto_upgrade // false')
    CUR_HR=$(echo "$MGMT" | jq -r '.auto_upgrade_hour // 0')
    _fmt_hour() { date -j -f "%H" "$1" "+%-l %p" 2>/dev/null || echo "${1}:00"; }

    case "$SUB" in
        status)
            echo "Device firmware auto-upgrade: ${CUR_ON}"
            echo "Update window (hour):         ${CUR_HR}  ($(_fmt_hour "$CUR_HR"))"
            SUPER_ON=$(unifi_get "rest/setting" | jq -r '.data[] | select(.key=="super_mgmt") | .auto_upgrade')
            echo "Controller app auto-upgrade:  ${SUPER_ON}"
            ;;
        hour)
            HOUR="${3:-}"
            if ! [[ "$HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
                echo "Usage: $0 auto_update hour <0-23>" >&2
                exit 1
            fi
            echo "Setting device auto-upgrade window: ${CUR_HR} ($(_fmt_hour "$CUR_HR")) → ${HOUR} ($(_fmt_hour "$HOUR"))"
            unifi_post "set/setting/mgmt" "$(jq -n --argjson h "$HOUR" \
                '{auto_upgrade: true, auto_upgrade_hour: $h}')" | jq '.meta'
            ;;
        on|off)
            WANT=$([[ "$SUB" == "on" ]] && echo true || echo false)
            echo "Setting device firmware auto-upgrade: ${CUR_ON} → ${WANT}"
            unifi_post "set/setting/mgmt" "$(jq -n --argjson v "$WANT" \
                '{auto_upgrade: $v}')" | jq '.meta'
            ;;
        *)
            echo "Usage: $0 auto_update <status|hour <0-23>|on|off>" >&2
            exit 1
            ;;
    esac

elif [[ "$CMD" == "tx_power" ]]; then
    # tx_power <ap_mac> <band> <low|medium|high|auto|N dBm> — set radio transmit power.
    # NOTE: radio_table.tx_power is a placeholder; the REAL value is radio_table_stats.tx_power.
    validate_mac "$ARG" || exit 1
    BAND="${3:-}"; LEVEL="${4:-}"
    if [[ -z "$BAND" || -z "$LEVEL" ]]; then
        echo "Usage: $0 tx_power <ap_mac> <ng|na|6e> <low|medium|high|auto|N>" >&2
        exit 1
    fi
    DEV=$(unifi_get "stat/device" | jq -c --arg m "$(normalize_mac "$ARG")" \
        '[.data[] | select(.mac == $m and .radio_table)] | first // empty')
    if [[ -z "$DEV" ]]; then
        echo "ERROR: no radio-capable device with MAC $ARG" >&2
        exit 1
    fi
    DEV_ID=$(echo "$DEV" | jq -r '._id'); DEV_NAME=$(echo "$DEV" | jq -r '.name')
    if ! echo "$DEV" | jq -e --arg b "$BAND" '.radio_table[] | select(.radio==$b)' >/dev/null; then
        echo "ERROR: $DEV_NAME has no '$BAND' radio" >&2
        exit 1
    fi
    OLD=$(echo "$DEV" | jq -r --arg b "$BAND" '.radio_table[] | select(.radio==$b) | .tx_power_mode')
    if [[ "$LEVEL" =~ ^[0-9]+$ ]]; then
        # Explicit dBm — must clamp to the radio's own min/max or the controller rejects it
        MINP=$(echo "$DEV" | jq -r --arg b "$BAND" '.radio_table[] | select(.radio==$b) | .min_txpower // 6')
        MAXP=$(echo "$DEV" | jq -r --arg b "$BAND" '.radio_table[] | select(.radio==$b) | .max_txpower // 26')
        if (( LEVEL < MINP || LEVEL > MAXP )); then
            echo "ERROR: $LEVEL dBm out of range for $DEV_NAME $BAND (min ${MINP}, max ${MAXP})" >&2
            exit 1
        fi
        BODY=$(echo "$DEV" | jq -c --arg b "$BAND" --argjson p "$LEVEL" \
            '{radio_table: [.radio_table[] | if .radio==$b then (.tx_power_mode="custom" | .tx_power=$p) else . end]}')
        echo "$DEV_NAME ($BAND): tx_power_mode $OLD -> custom ${LEVEL}dBm"
    else
        case "$LEVEL" in
            low|medium|high|auto) ;;
            *) echo "ERROR: level must be low|medium|high|auto or a dBm integer" >&2; exit 1 ;;
        esac
        BODY=$(echo "$DEV" | jq -c --arg b "$BAND" --arg m "$LEVEL" \
            '{radio_table: [.radio_table[] | if .radio==$b then (.tx_power_mode=$m) else . end]}')
        echo "$DEV_NAME ($BAND): tx_power_mode $OLD -> $LEVEL"
    fi
    unifi_put "rest/device/${DEV_ID}" "$BODY" | jq -c '.meta'

elif [[ "$CMD" == "wlan" ]]; then
    # wlan <ssid_name|_id> <on|off> — enable/disable an SSID (reversible; does NOT delete it)
    STATE="${3:-}"
    if [[ -z "$STATE" || ( "$STATE" != "on" && "$STATE" != "off" ) ]]; then
        echo "Usage: $0 wlan <ssid_name|_id> <on|off>" >&2
        exit 1
    fi
    WLANS=$(unifi_get "rest/wlanconf")
    W=$(echo "$WLANS" | jq -c --arg t "$ARG" '[.data[] | select(.name == $t or ._id == $t)] | first // empty')
    if [[ -z "$W" ]]; then
        echo "ERROR: no SSID matched '$ARG'. Known:" >&2
        echo "$WLANS" | jq -r '.data[] | "  \(.name)  \(._id)  enabled=\(.enabled)"' >&2
        exit 1
    fi
    W_ID=$(echo "$W" | jq -r '._id')
    W_NAME=$(echo "$W" | jq -r '.name')
    WAS=$(echo "$W" | jq -r '.enabled')
    NEW=$([[ "$STATE" == "on" ]] && echo true || echo false)
    echo "SSID '$W_NAME' ($W_ID): enabled $WAS -> $NEW"
    # Partial update — only the changed field, per the wlanconf PUT convention
    unifi_put "rest/wlanconf/${W_ID}" "$(jq -nc --argjson e "$NEW" '{enabled: $e}')" | jq -c '.meta'

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
    echo "Commands: reboot, provision, kick, block, unblock, rename, fixed_ip, poe_cycle, min_rssi, port_forward, game, auto_update, radio" >&2
    exit 1
fi

unifi_logout
