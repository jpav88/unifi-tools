#!/usr/bin/env bash
# probe_gameserver.sh — on-demand latency/path probe to a specific game server.
#
# Rust/Satisfactory/etc. servers change IP (wipes, server-hopping), so this is a
# DISPOSABLE, on-demand tool — NOT wired into the dashboard/monitor. Point it at
# whatever server the player is on today.
#
#   probe_gameserver.sh <ip[:port]>                     one-shot: geo + 20 pings + traceroute
#   probe_gameserver.sh <ip[:port]> --watch [min] [sec] sample every <sec> for <min> minutes
#
# Watch mode logs to data/gameserver_probe/<ip>_<start>.csv and prints a summary at the end.
# ICMP is a proxy for the UDP game path (port is informational); if the host blocks ping,
# one-shot will show 100% loss even when the game works — traceroute still locates the path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../data/gameserver_probe"

target="${1:-}"
[[ -z "$target" ]] && { echo "usage: $(basename "$0") <ip[:port]> [--watch [minutes] [interval_s]]" >&2; exit 2; }
IP="${target%%:*}"
PORT=""; [[ "$target" == *:* ]] && PORT="${target##*:}"

# ---- helpers ---------------------------------------------------------------
geo() {
    echo "=== server $IP${PORT:+:$PORT} ==="
    curl -s --max-time 6 \
        "http://ip-api.com/line/$IP?fields=status,country,regionName,city,isp,org,as,reverse" \
        2>/dev/null | paste -sd' · ' - 2>/dev/null || echo "(geo lookup unavailable)"
}

# Parse a `ping` run -> "loss_pct min avg max mdev" (blanks if unreachable).
ping_stats() {
    local count="$1" out loss rtt
    out=$(ping -c "$count" -i 0.3 -t 5 "$IP" 2>/dev/null)
    loss=$(printf '%s\n' "$out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')
    rtt=$(printf '%s\n' "$out" | awk -F'= ' '/min\/avg\/max/{print $2}' | awk '{print $1}')
    local mn av mx md
    IFS='/' read -r mn av mx md <<<"${rtt:-///}"
    echo "${loss:-100} ${mn:-} ${av:-} ${mx:-} ${md:-}"
}

oneshot() {
    geo; echo
    echo "=== ping ×20 (latency / jitter / loss) ==="
    read -r loss mn av mx md < <(ping_stats 20)
    printf "  loss %s%%   min %s   avg %s   max %s   jitter(mdev) %s ms\n" \
        "$loss" "${mn:-–}" "${av:-–}" "${mx:-–}" "${md:-–}"
    echo
    echo "=== traceroute (where the path degrades) ==="
    traceroute -w 2 -q 2 -m 20 "$IP" 2>/dev/null
}

watch_mode() {
    local minutes="${1:-60}" interval="${2:-30}"
    mkdir -p "$OUT_DIR"
    local start_epoch csv
    start_epoch=$(date +%s)
    csv="$OUT_DIR/${IP}_$(date -r "$start_epoch" +%Y%m%d-%H%M%S).csv"
    echo "iso,epoch,loss_pct,min_ms,avg_ms,max_ms,mdev_ms" > "$csv"

    geo
    echo "Baseline path:"
    traceroute -w 2 -q 1 -m 20 "$IP" 2>/dev/null | sed 's/^/  /'
    echo
    echo "Watching $IP for ${minutes} min, one 10-ping sample every ${interval}s → $csv"
    printf "  %-19s %6s %7s %7s %7s %8s\n" "time" "loss%" "min" "avg" "max" "jitter"

    local end_epoch=$(( start_epoch + minutes * 60 ))
    while (( $(date +%s) < end_epoch )); do
        local now iso
        now=$(date +%s); iso=$(date -r "$now" '+%Y-%m-%d %H:%M:%S')
        read -r loss mn av mx md < <(ping_stats 10)
        printf '%s,%s,%s,%s,%s,%s,%s\n' "$iso" "$now" "$loss" "$mn" "$av" "$mx" "$md" >> "$csv"
        # flag a bad sample inline: any loss, or a latency/jitter spike worth an eye
        local flag=""
        awk "BEGIN{exit !(${loss:-100}+0>0)}" && flag=" ⚠ loss"
        [[ -n "${md:-}" ]] && awk "BEGIN{exit !(${md}+0>25)}" && flag="$flag ⚠ jitter"
        [[ -n "${av:-}" ]] && awk "BEGIN{exit !(${av}+0>60)}" && flag="$flag ⚠ latency"
        printf "  %-19s %6s %7s %7s %7s %8s%s\n" \
            "$iso" "$loss" "${mn:-–}" "${av:-–}" "${mx:-–}" "${md:-–}" "$flag"
        sleep "$interval"
    done

    echo
    echo "=== summary over ${minutes} min ($csv) ==="
    awk -F',' 'NR>1{
        n++; if($3+0>0){badloss++; losssum+=$3}
        if($5!=""){avsum+=$5; an++; if($5+0>mxavg)mxavg=$5}
        if($6!=""&&$6+0>wmax)wmax=$6
        if($7!=""){if($7+0>wjit)wjit=$7}
    } END{
        if(n==0){print "  no samples"; exit}
        printf "  samples: %d   clean(0%% loss): %d   with loss: %d\n", n, n-badloss, badloss
        printf "  avg latency: %.1f ms   worst-sample avg: %.1f ms   worst single ping: %.1f ms\n", (an?avsum/an:0), mxavg, wmax
        printf "  worst jitter: %.1f ms   total lossy samples: %d\n", wjit, badloss
        if(badloss==0 && mxavg<60 && wjit<25)
            print "  VERDICT: path to this server stayed clean the whole window — lag was NOT the network to here."
        else
            print "  VERDICT: saw loss/spikes to this server — cross-check the timestamps against the WAN dashboard."
    }' "$csv"
}

# ---- dispatch --------------------------------------------------------------
if [[ "${2:-}" == "--watch" ]]; then
    watch_mode "${3:-60}" "${4:-30}"
else
    oneshot
fi
