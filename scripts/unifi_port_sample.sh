#!/bin/bash
set -euo pipefail
# Periodic port-counter sampler — builds the hourly history the controller won't.
#
# The UniFi controller keeps hourly time-series for the WAN/gateway but NOT for
# wired clients (verified: wired bytes/drops come back empty from stat/report.user).
# This script snapshots raw port counters on a schedule so per-interval deltas
# (drops, errors, throughput) accumulate over time for any port we care about.
#
# Usage:
#   ./unifi_port_sample.sh --sample        # take one sample, append to CSV
#   ./unifi_port_sample.sh --show [n]      # side-by-side view, last n intervals (default 48)
#   ./unifi_port_sample.sh --install       # install cron job (every 15 min)
#   ./unifi_port_sample.sh --uninstall     # remove cron job
#
# Targets are "name:device_mac:port_idx". Edit TARGETS to add/remove ports.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_DIR/data"
CSV="$DATA_DIR/port_samples.csv"
LOG="$DATA_DIR/port_sample.log"
LABEL="com.unifi.portsample"
INTERVAL=900   # 15 min

# name@device_mac@port_idx  (UDM port 4 = WAN uplink, UDM port 1 = Gaming PC)
TARGETS=(
    "WAN@xx:xx:xx:xx:xx:xx@4"
    "Gamer@xx:xx:xx:xx:xx:xx@1"
)

CSV_HEADER="epoch,iso_local,target,device_mac,port_idx,speed,up,rx_bytes,tx_bytes,rx_packets,tx_packets,rx_dropped,tx_dropped,rx_errors,tx_errors"

sample() {
    source "$SCRIPT_DIR/unifi_auth.sh"
    unifi_init
    local devjson now iso
    devjson=$(unifi_get "stat/device")
    now=$(date +%s)
    iso=$(date "+%Y-%m-%d %H:%M:%S")

    mkdir -p "$DATA_DIR"
    [[ -f "$CSV" ]] || echo "$CSV_HEADER" > "$CSV"

    local entry name mac port row
    for entry in "${TARGETS[@]}"; do
        IFS='@' read -r name mac port <<< "$entry"
        row=$(echo "$devjson" | jq -r --arg mac "$mac" --argjson port "$port" \
            --argjson now "$now" --arg iso "$iso" --arg name "$name" '
            .data[] | select(.mac==$mac) | .port_table[] | select(.port_idx==$port) |
            [$now,$iso,$name,$mac,$port,.speed,(if .up then 1 else 0 end),
             (.rx_bytes//0),(.tx_bytes//0),(.rx_packets//0),(.tx_packets//0),
             (.rx_dropped//0),(.tx_dropped//0),(.rx_errors//0),(.tx_errors//0)] | @csv')
        if [[ -n "$row" ]]; then
            echo "$row" >> "$CSV"
        else
            echo "$iso WARN: no port_table match for $name ($mac port $port)" >> "$LOG"
        fi
    done
    echo "$iso sampled ${#TARGETS[@]} targets -> $CSV" >> "$LOG"
}

show() {
    local n="${1:-48}"
    [[ -f "$CSV" ]] || { echo "No data yet at $CSV — run --sample or --install first." >&2; exit 1; }
    # Compute per-interval deltas per target, then render side-by-side (WAN | Gamer).
    awk -F',' -v n="$n" '
    function strip(s){ gsub(/"/,"",s); return s }
    NR==1 { next }
    {
        t=strip($3); ep=strip($1)+0
        rxb=strip($8)+0; txb=strip($9)+0
        rxd=strip($12)+0; txd=strip($13)+0
        rxe=strip($14)+0; txe=strip($15)+0
        # store per target, ordered by epoch of appearance
        if (!(t in seen)) { order[++ntar]=t; seen[t]=1 }
        idx=cnt[t]++
        EP[t,idx]=ep; HM[t,idx]=substr(strip($2),12,5); DT[t,idx]=substr(strip($2),6,5)
        RXB[t,idx]=rxb; TXB[t,idx]=txb; RXD[t,idx]=rxd; TXD[t,idx]=txd; RXE[t,idx]=rxe; TXE[t,idx]=txe
    }
    END{
        # Use first two targets for the side-by-side (extend if needed)
        a=order[1]; b=order[2]
        printf "  %-34s │ %-34s\n", a" — drops/errors per interval", b" — drops/errors per interval"
        printf "  %-34s │ %-34s\n", "(throughput Mbps, Δdrop, Δerr)", "(throughput Mbps, Δdrop, Δerr)"
        print  "  ────────────────────────────────── │ ──────────────────────────────────"
        printf "  %-5s %7s %7s %5s %5s  │ %-5s %7s %7s %5s %5s\n","time","dn","up","drp","err","time","dn","up","drp","err"
        na=cnt[a]; nb=cnt[b]; m=(na>nb?na:nb)
        start=(m-1-n); if(start<1)start=1
        for(i=start;i<m;i++){
            la=fmt(a,i); lb=fmt(b,i)
            printf "  %s  │ %s\n", la, lb
        }
        # totals
        printf "  ────────────────────────────────── │ ──────────────────────────────────\n"
        printf "  %s  │ %s\n", tot(a), tot(b)
    }
    function fmt(t,i,   dt,secs,dn,up,dd,de){
        if(i<=0 || i>=cnt[t] || !((t SUBSEP i) in EP)) return sprintf("%-5s %7s %7s %5s %5s","--","","","","")
        secs=EP[t,i]-EP[t,i-1]; if(secs<=0)secs=1
        dn=(RXB[t,i]-RXB[t,i-1])*8/secs/1e6
        up=(TXB[t,i]-TXB[t,i-1])*8/secs/1e6
        dd=(RXD[t,i]-RXD[t,i-1])+(TXD[t,i]-TXD[t,i-1])
        de=(RXE[t,i]-RXE[t,i-1])+(TXE[t,i]-TXE[t,i-1])
        if(dd<0)dd=0; if(de<0)de=0
        return sprintf("%-5s %7.1f %7.1f %5d %5d",HM[t,i],dn,up,dd,de)
    }
    function tot(t,   i,dd,de){ dd=0;de=0
        for(i=1;i<cnt[t];i++){ x=(RXD[t,i]-RXD[t,i-1])+(TXD[t,i]-TXD[t,i-1]); if(x>0)dd+=x
                               y=(RXE[t,i]-RXE[t,i-1])+(TXE[t,i]-TXE[t,i-1]); if(y>0)de+=y }
        return sprintf("%-5s %7s %7s %5d %5d","TOTAL","","",dd,de)
    }
    ' "$CSV"
}

# Scheduling uses cron (works in headless/SSH contexts where launchctl's GUI
# domain is unreachable). Entry is tagged with CRON_TAG for clean removal.
CRON_TAG="# $LABEL"
CRON_LINE="*/$((INTERVAL/60)) * * * * /bin/bash $SCRIPT_DIR/unifi_port_sample.sh --sample >> $DATA_DIR/port_sample.cron.log 2>&1 $CRON_TAG"

install_job() {
    mkdir -p "$DATA_DIR"
    local existing
    existing=$(crontab -l 2>/dev/null | grep -vF "$CRON_TAG" || true)
    { [[ -n "$existing" ]] && printf '%s\n' "$existing"; printf '%s\n' "$CRON_LINE"; } | crontab -
    echo "Installed cron job — sampling every $((INTERVAL/60)) min into $CSV"
    echo "View anytime: $SCRIPT_DIR/unifi_port_sample.sh --show"
}

uninstall_job() {
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        echo "Uninstalled cron job (data preserved at $CSV)"
    else
        echo "No cron job found (nothing to remove)"
    fi
}

case "${1:---show}" in
    --sample)    sample ;;
    --show)      show "${2:-48}" ;;
    --install)   install_job ;;
    --uninstall) uninstall_job ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
    *)           echo "Usage: $0 [--sample|--show [n]|--install|--uninstall]" >&2; exit 1 ;;
esac
