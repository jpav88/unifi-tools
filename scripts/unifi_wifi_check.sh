#!/bin/bash
set -euo pipefail
# Wi-Fi health check — diagnose common problems across the network
# Usage: ./unifi_wifi_check.sh
#
# Checks for:
#   - Weak signal clients (below -70 dBm)
#   - Clients possibly stuck on a far AP
#   - Co-channel interference between APs
#   - High channel utilization on any AP
#   - WLAN settings that may cause issues
#   - High retry rates (indicates interference or distance)
#
# No args needed — scans the entire network and reports findings.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/unifi_auth.sh"

unifi_init

# Gather all data in one pass
DEVICES=$(unifi_get "stat/device")
CLIENTS=$(unifi_get "stat/sta")
WLANS=$(unifi_get "rest/wlanconf")

# Build AP name lookup
AP_NAMES=$(echo "$DEVICES" | jq '[.data[] | select(.type != "usw") | {(.mac): (.name // .mac)}] | add // {}')

ISSUES="[]"

# --- Check 1: Weak signal clients ---
WEAK=$(echo "$CLIENTS" | jq --argjson aps "$AP_NAMES" '
    [.data[] | select(.is_wired == false and .signal != null and .signal < -70) | {
        check: "weak_signal",
        severity: (if .signal < -80 then "HIGH" elif .signal < -75 then "MEDIUM" else "LOW" end),
        client: (.name // .hostname // .mac),
        mac,
        signal: .signal,
        satisfaction: .satisfaction,
        ap: ($aps[.ap_mac] // .ap_mac),
        essid,
        detail: ("Signal \(.signal) dBm on " + ($aps[.ap_mac] // .ap_mac))
    }]')

# --- Check 2: High retry rates (>10% of packets) ---
HIGH_RETRIES=$(echo "$CLIENTS" | jq --argjson aps "$AP_NAMES" '
    [.data[] | select(.is_wired == false and .tx_packets != null and .tx_packets > 100) |
        (.tx_retries // 0) as $retries | (.tx_packets // 1) as $pkts |
        ($retries / $pkts * 100) as $pct |
        select($pct > 10) | {
            check: "high_retries",
            severity: (if $pct > 25 then "HIGH" elif $pct > 15 then "MEDIUM" else "LOW" end),
            client: (.name // .hostname // .mac),
            mac,
            retry_pct: ($pct * 10 | round / 10),
            signal: .signal,
            ap: ($aps[.ap_mac] // .ap_mac),
            detail: ("\($pct * 10 | round / 10)% retry rate — possible interference or distance issue")
        }]')

# --- Check 3: Co-channel APs (same channel, same band) ---
COCHANNEL=$(echo "$DEVICES" | jq '
    [.data[] | select(.type != "usw") |
        .name as $name | .mac as $mac |
        (.radio_table_stats[]? | select(.num_sta != null) | {
            ap: $name, ap_mac: $mac,
            radio: .radio, channel: .channel
        })
    ]
    | group_by(.channel)
    | map(select(length > 1 and .[0].channel != null and .[0].channel != 0))
    | map({
        check: "co_channel",
        severity: "MEDIUM",
        channel: .[0].channel,
        band: .[0].radio,
        aps: [.[].ap],
        detail: ("Channel \(.[0].channel): " + ([.[].ap] | join(", ")) + " — co-channel interference likely")
    })
    | [.[] | select(.band != "6e")]')

# --- Check 4: High channel utilization (>50%) ---
HIGH_CU=$(echo "$DEVICES" | jq '
    [.data[] | select(.type != "usw") |
        .name as $name |
        (.radio_table_stats[]? |
            select(.cu_total != null and .cu_total > 50) | {
                check: "high_utilization",
                severity: (if .cu_total > 75 then "HIGH" elif .cu_total > 60 then "MEDIUM" else "LOW" end),
                ap: $name,
                band: (if .radio == "na" then "5GHz" elif .radio == "ng" then "2.4GHz" elif .radio == "6e" then "6GHz" else .radio end),
                channel: .channel,
                utilization_pct: .cu_total,
                clients: .num_sta,
                detail: ("\($name) \(if .radio == "na" then "5GHz" elif .radio == "ng" then "2.4GHz" else .radio end) ch\(.channel): \(.cu_total)% utilization")
            }
        )
    ]')

# --- Check 5: WLAN settings review ---
WLAN_ISSUES=$(echo "$WLANS" | jq '
    [.data[] | select(.enabled == true) |
        {name, security, wpa_mode, fast_roaming, bss_transition, pmf_mode, group_rekey, mcastenhance, rrm: .rrm_enabled, uapsd: .uapsd_enabled} as $w |
        (
            if $w.group_rekey == 0 or $w.group_rekey == null then
                {check: "wlan_config", severity: "MEDIUM", ssid: $w.name, setting: "group_rekey", value: "disabled", detail: "\($w.name): group_rekey disabled — Apple recommends 3600s"}
            else empty end
        ),
        (
            if $w.bss_transition != true and ($w.name | test("iot|2"; "i") | not) then
                {check: "wlan_config", severity: "LOW", ssid: $w.name, setting: "bss_transition", value: "disabled", detail: "\($w.name): 802.11v (BSS Transition) disabled — helps clients find better APs"}
            else empty end
        ),
        (
            if $w.rrm != true and ($w.name | test("iot|2"; "i") | not) then
                {check: "wlan_config", severity: "LOW", ssid: $w.name, setting: "rrm", value: "disabled", detail: "\($w.name): 802.11k (RRM) disabled — helps clients scan faster when roaming"}
            else empty end
        )
    ]')

# --- Combine and sort by severity ---
ALL_ISSUES=$(jq -n \
    --argjson weak "$WEAK" \
    --argjson retries "$HIGH_RETRIES" \
    --argjson cochan "$COCHANNEL" \
    --argjson cu "$HIGH_CU" \
    --argjson wlan "$WLAN_ISSUES" \
    '$weak + $retries + $cochan + $cu + $wlan
    | sort_by(if .severity == "HIGH" then 0 elif .severity == "MEDIUM" then 1 else 2 end)')

# --- Summary ---
TOTAL=$(echo "$ALL_ISSUES" | jq 'length')
HIGH=$(echo "$ALL_ISSUES" | jq '[.[] | select(.severity == "HIGH")] | length')
MEDIUM=$(echo "$ALL_ISSUES" | jq '[.[] | select(.severity == "MEDIUM")] | length')
LOW=$(echo "$ALL_ISSUES" | jq '[.[] | select(.severity == "LOW")] | length')

WIRELESS_COUNT=$(echo "$CLIENTS" | jq '[.data[] | select(.is_wired == false)] | length')
AP_COUNT=$(echo "$DEVICES" | jq '[.data[] | select(.type != "usw")] | length')

jq -n \
    --argjson issues "$ALL_ISSUES" \
    --argjson total "$TOTAL" \
    --argjson high "$HIGH" \
    --argjson medium "$MEDIUM" \
    --argjson low "$LOW" \
    --argjson wifi_clients "$WIRELESS_COUNT" \
    --argjson aps "$AP_COUNT" \
    '{
        summary: {
            status: (if $high > 0 then "ISSUES FOUND" elif $medium > 0 then "MINOR ISSUES" else "HEALTHY" end),
            wireless_clients: $wifi_clients,
            access_points: $aps,
            issues: {total: $total, high: $high, medium: $medium, low: $low}
        },
        issues: $issues
    }'

unifi_logout
