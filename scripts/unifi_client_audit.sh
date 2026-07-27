#!/bin/bash
set -euo pipefail
# unifi_client_audit.sh — Connectivity audit focused on two tracked client devices
# with cross-room impact tracking after the 2026-04-27 UDM/NanoHD changes.
#
# Primary focus: AUDIT_PRIMARY + AUDIT_SECONDARY from local/devices.sh (5GHz clients)
# Secondary:    AUDIT_REF1 + AUDIT_REF2 (comparison baseline)
# Cross-room:   per-AP client distribution to spot drift in living room,
#               second bedroom, home office after the UDM 5GHz tx_power bump.
#
# Read-only — no kicks, writes, or config changes.
#
# Usage: ./unifi_client_audit.sh [hours=24]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

# Display all dates/times in Central Time (auto-handles CDT/CST via DST rules).
export TZ="America/Chicago"

HOURS="${1:-24}"

# Syslog files store timestamps in UTC. To match a 24h Central-time window,
# include both today and yesterday's UTC dates so we catch evenings that
# straddle 00:00 UTC.
TODAY_UTC=$(TZ=UTC date +%Y-%m-%d)
YESTERDAY_UTC=$(TZ=UTC date -v-1d +%Y-%m-%d 2>/dev/null || TZ=UTC date -d "1 day ago" +%Y-%m-%d)
DATE_REGEX="^(${TODAY_UTC}|${YESTERDAY_UTC})"

# Convert any UTC timestamps in stdin (ISO with 'Z' or 'YYYY-MM-DD HH:MM:SS')
# to America/Chicago. Output format: "YYYY-MM-DD HH:MM CDT" or "... CST".
to_central() {
    python3 -c '
import sys, re
from datetime import datetime, timezone
try:
    from zoneinfo import ZoneInfo
    CENTRAL = ZoneInfo("America/Chicago")
except ImportError:
    import pytz
    CENTRAL = pytz.timezone("America/Chicago")

iso_re    = re.compile(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z")
plain_re  = re.compile(r"(?<!\d)(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(?!\.\d)")

def fmt(date, t):
    dt = datetime.strptime(f"{date} {t}", "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    return dt.astimezone(CENTRAL).strftime("%Y-%m-%d %H:%M %Z")

for line in sys.stdin:
    line = iso_re.sub(lambda m: fmt(m.group(1), m.group(2)), line)
    line = plain_re.sub(lambda m: fmt(m.group(1), m.group(2)), line)
    sys.stdout.write(line)
'
}

# Focus devices + AP map come from local/devices.sh (gitignored) — real MACs must
# never live in a tracked file, since every tracked file is copied to the public mirror.
if [[ -f "$SCRIPT_DIR/../local/devices.sh" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../local/devices.sh"
else
    echo "ERROR: local/devices.sh not found — copy local/devices.sh.example and fill it in." >&2
    exit 1
fi

for _v in AUDIT_PRIMARY_MAC AUDIT_SECONDARY_MAC AUDIT_REF1_MAC AUDIT_REF2_MAC; do
    if [[ -z "${!_v:-}" ]]; then
        echo "ERROR: $_v is not set in local/devices.sh (see local/devices.sh.example)." >&2
        exit 1
    fi
done

AP_MACS=()
for _entry in "${AUDIT_AP_MAP[@]}"; do AP_MACS+=("${_entry%%|*}"); done

ap_name() {
    for _entry in "${AUDIT_AP_MAP[@]}"; do
        [[ "${_entry%%|*}" == "$1" ]] && { local _r="${_entry#*|}"; echo "${_r%%|*}"; return; }
    done
    echo "$1"
}

ap_room() {
    for _entry in "${AUDIT_AP_MAP[@]}"; do
        local _r="${_entry#*|}"
        [[ "${_r%%|*}" == "$1" ]] && { echo "${_r#*|}"; return; }
    done
    echo ""
}

unifi_init
ALL_STA=$(unifi_get "stat/sta")

hr() { printf '═══════════════════════════════════════════════════════════════\n'; }
sec() { printf '\n─── %s ───\n' "$1"; }

hr
echo "  Client Device Audit + Cross-Room Impact"
echo "  Generated: $(date '+%Y-%m-%d %H:%M %Z')"
echo "  Window:    last ${HOURS}h | times shown in Central"
hr
echo
echo "Tracked config changes (2026-04-27):"
echo "  UDM 5GHz tx_power: low (6 dBm) → medium (14 dBm)"
echo "  Bedroom NanoHD 2.4GHz tx_power: tried medium, reverted to low same day"
echo
echo "Watch for fallout in:"
echo "  - Living room    (tracked clients, Apple TV, photo frame, Mac, etc.)"
echo "  - Home office    (your phone/tablet/server, UDM-direct clients)"
echo "  - Second bedroom (NanoHD-served clients)"
echo "  - Master bedroom (U6+ clients should be unchanged)"

# ────────────────────────────────────────────────────────────
# 1. Live state
# ────────────────────────────────────────────────────────────
sec "1. Live state of focus devices"

show_client() {
    local mac="$1" label="$2"
    local data
    data=$(echo "$ALL_STA" | jq -r --arg mac "$mac" \
        '.data[] | select(.mac == $mac) | "\(.ap_mac)|\(.essid // "?")|\(.channel // "?")|\(.signal // "?")|\(.tx_rate // 0)|\(.rx_rate // 0)|\(.satisfaction // "?")|\(.uptime // 0)"')
    if [[ -z "$data" || "$data" == "null|"* ]]; then
        printf "  %-15s  -- not currently associated --\n" "$label"
        return
    fi
    local IFS='|'
    local ap essid ch sig tx rx sat uptime
    read -r ap essid ch sig tx rx sat uptime <<< "$data"
    local apname
    apname=$(ap_name "$ap")
    printf "  %-15s  %-15s  %-12s ch%-4s  %4s dBm  %4d/%-4d Mbps  sat=%-3s  up=%dm\n" \
        "$label" "$apname" "$essid" "$ch" "$sig" "$((tx/1000))" "$((rx/1000))" "$sat" "$((uptime/60))"
}

show_client "$AUDIT_PRIMARY_MAC"  "$AUDIT_PRIMARY_NAME"
show_client "$AUDIT_SECONDARY_MAC" "$AUDIT_SECONDARY_NAME"
echo "  ─── comparison ───"
show_client "$AUDIT_REF1_MAC"    "$AUDIT_REF1_NAME"
show_client "$AUDIT_REF2_MAC"  "$AUDIT_REF2_NAME"

# ────────────────────────────────────────────────────────────
# 2. Session history for the tracked clients
# ────────────────────────────────────────────────────────────
sec "2. Session history (last ${HOURS}h) — the tracked clients"

show_sessions() {
    local mac="$1" label="$2"
    printf "\n  %s (%s):\n" "$label" "$mac"
    local sessions
    sessions=$("$SCRIPT_DIR/unifi_sessions.sh" "$mac" "$HOURS" 2>/dev/null || echo "[]")
    local count
    count=$(echo "$sessions" | jq 'length')
    if [[ "$count" == "0" ]]; then
        echo "    (no sessions)"
        return
    fi
    echo "$sessions" | jq -r '.[] |
        "    \(.start)  \(.duration_min)m  \(.ap)  sat=\(.satisfaction)  TX/RX=\(.tx_mb)/\(.rx_mb)MB  roams=\(.roaming | length)"' \
        | to_central
}

show_sessions "$AUDIT_PRIMARY_MAC"  "$AUDIT_PRIMARY_NAME"
show_sessions "$AUDIT_SECONDARY_MAC" "$AUDIT_SECONDARY_NAME"

# ────────────────────────────────────────────────────────────
# 3. Today's syslog events for the tracked clients
# ────────────────────────────────────────────────────────────
sec "3. Today's kick / DEAUTH / BTM events — the tracked clients"

if ssh -o ConnectTimeout=5 -q syslog-host-local true 2>/dev/null; then
    # Path on remote (resolved by remote shell, not local)
    SYSLOG_BASE='Library/Logs/unifi-syslog'
    for entry in "$AUDIT_PRIMARY_MAC:$AUDIT_PRIMARY_NAME" "$AUDIT_SECONDARY_MAC:$AUDIT_SECONDARY_NAME"; do
        mac="${entry%%:*}"
        label="${entry##*:}"
        printf "\n  %s:\n" "$label"
        events=$(ssh syslog-host-local "cd ~ && grep -hE '${DATE_REGEX}' ${SYSLOG_BASE}/unifi.log.1 ${SYSLOG_BASE}/unifi.log 2>/dev/null | grep '$mac' | grep -E 'kick-sta|MlmeDeAuthAction|FORCE_TO_ROAM'" 2>/dev/null || true)
        if [[ -z "$events" ]]; then
            echo "    (no kick / DEAUTH / BTM events in window)"
            continue
        fi
        # Parse, filter rc=2 (stale-association noise), keep last 30 meaningful events.
        echo "$events" | awk '
        {
            ts = $1 " " $2
            ap = ""; evt = ""; rssi = ""; rc = ""
            for (i = 3; i <= NF; i++) {
                if ($i ~ /BedroomNanoHD|U7ProMax|U7ProOutdoor|U6-Plus|UDM/) ap = $i
                if ($i ~ /kick-sta-on/) evt = "KICK"
                if ($i ~ /FORCE_TO_ROAM/) evt = "BTM-roam-req"
                if ($i ~ /MlmeDeAuthAction/) evt = "DEAUTH"
                if ($i ~ /rssi:/) {
                    tok = $i; sub(/.*rssi:/, "", tok); sub(/[^0-9-].*$/, "", tok)
                    # UniFi kick logs use internal scale (positive small int);
                    # BTM/ASSOC logs use real dBm (negative). Convert internal to ~dBm.
                    if (tok+0 > 0 && tok+0 < 60) rssi = sprintf("≈%ddBm", tok - 95)
                    else                          rssi = sprintf("%sdBm", tok)
                }
                if ($i ~ /^rssi$/ && $(i+2) ~ /^-?[0-9]+/) {
                    tok = $(i+2); sub(/[^0-9-].*$/, "", tok)
                    rssi = sprintf("%sdBm", tok)
                }
                if ($i ~ /ReasonCode/) {
                    rc = $i; gsub(/.*ReasonCode\(/, "", rc); gsub(/\).*/, "", rc)
                }
            }
            if (evt == "DEAUTH" && rc == "2") next  # stale-association noise
            if (evt != "") {
                detail = (rssi != "" ? rssi : (rc != "" ? "rc=" rc : ""))
                printf "    %s  %-15s  %-12s  %s\n", ts, ap, evt, detail
            }
        }' | tail -30 | to_central
    done
else
    echo "  ⚠ Cannot reach syslog-host-local — skipping syslog analysis"
fi

# ────────────────────────────────────────────────────────────
# 4. Per-AP event count for the tracked clients (24h window)
# ────────────────────────────────────────────────────────────
sec "4. Per-AP event count in window (the tracked clients)"

if ssh -o ConnectTimeout=5 -q syslog-host-local true 2>/dev/null; then
    for entry in "$AUDIT_PRIMARY_MAC:$AUDIT_PRIMARY_NAME" "$AUDIT_SECONDARY_MAC:$AUDIT_SECONDARY_NAME"; do
        mac="${entry%%:*}"
        label="${entry##*:}"
        printf "\n  %s:\n" "$label"
        ssh syslog-host-local "cd ~ && grep -hE '${DATE_REGEX}' ${SYSLOG_BASE}/unifi.log.1 ${SYSLOG_BASE}/unifi.log 2>/dev/null | grep '$mac' | grep -oE '(BedroomNanoHD|U7ProMax|U7ProOutdoor|U6-Plus|UDM)' | sort | uniq -c | sort -rn" 2>/dev/null | \
            awk '{ printf "    %-15s  %s events\n", $2, $1 }'

        printf "  %s — kicks by AP+RSSI:\n" "$label"
        ssh syslog-host-local "cd ~ && grep -hE '${DATE_REGEX}' ${SYSLOG_BASE}/unifi.log.1 ${SYSLOG_BASE}/unifi.log 2>/dev/null | grep '$mac' | grep 'kick-sta-on'" 2>/dev/null | \
            awk '{
                for(i=1;i<=NF;i++){
                    if($i ~ /BedroomNanoHD|U7ProMax|U7ProOutdoor|U6-Plus|UDM/) ap=$i
                    if($i ~ /rssi:/) {
                        tok=$i; sub(/.*rssi:/,"",tok); sub(/[^0-9-].*$/,"",tok)
                        if (tok+0 > 0 && tok+0 < 60) rssi = sprintf("≈%ddBm", tok - 95)
                        else                          rssi = sprintf("%sdBm", tok)
                    }
                }
                if(ap != "") print "    " ap "  " rssi
                ap=""; rssi=""
            }' | sort | uniq -c | awk '{printf "    %-30s  ×%s\n", $2 "  " $3, $1}'
    done
else
    echo "  ⚠ Cannot reach syslog-host-local — skipping"
fi

# ────────────────────────────────────────────────────────────
# 5. Cross-room impact: all clients per AP, current snapshot
# ────────────────────────────────────────────────────────────
sec "5. Cross-room impact: clients per AP (current snapshot)"

for ap_mac in "${AP_MACS[@]}"; do
    apname=$(ap_name "$ap_mac")
    aproom=$(ap_room "$apname")
    count=$(echo "$ALL_STA" | jq --arg ap "$ap_mac" '[.data[] | select(.ap_mac == $ap)] | length')
    printf "\n  ─── %s [%s] — %d clients ───\n" "$apname" "$aproom" "$count"
    echo "$ALL_STA" | jq -r --arg ap "$ap_mac" \
        '.data[] | select(.ap_mac == $ap) | [(.signal // 0), (.essid // "?"), (.channel // "?"), (.satisfaction // "?"), (.name // .hostname // .mac)] | @tsv' | \
        sort -n | \
        awk -F'\t' '{ printf "    %4s dBm  %-12s ch%-4s  sat=%-3s  %s\n", $1, $2, $3, $4, $5 }'
done

echo
hr
echo "  End of audit — re-run later (./unifi_client_audit.sh) to compare drift"
hr
