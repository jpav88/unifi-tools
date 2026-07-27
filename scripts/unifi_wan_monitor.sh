#!/bin/bash
set -euo pipefail
# Continuous WAN-path latency/jitter/loss monitor -> SQLite (data/wan_path.db).
#
# Pings several targets ALONG the path every INTERVAL seconds so that when
# latency spikes we can see WHERE it starts:
#   lan_gw            192.168.1.1     -> local gateway/host health (isolates local)
#   frontier_hop1     47.189.192.1    -> Frontier first hop / last mile
#   frontier_regional 184.19.246.8    -> Frontier aggregation/backbone
#   google            8.8.8.8         -> beyond Frontier (transit/peering)
#   cloudflare        1.1.1.1         -> beyond Frontier (second opinion)
#
# Each tick fires COUNT pings at every target (via fping -C) and records, per
# target: loss%, min/avg/max RTT, and JITTER (stddev of the per-packet RTTs).
# When a non-LAN target shows loss or high latency, a timestamped traceroute is
# captured to the event log so we see the offending hop live (with a cooldown).
#
# Data self-caps at RETAIN_DAYS via a daily prune (rolling window). Pause/resume
# without sudo via a flag file the --run loop honors (daemon keeps running idle).
#
# Usage:
#   ./unifi_wan_monitor.sh --sample            # take one sample, insert into DB
#   ./unifi_wan_monitor.sh --bufferbloat       # run one networkQuality load test now
#   ./unifi_wan_monitor.sh --run               # loop forever (used by the daemon)
#   ./unifi_wan_monitor.sh --show [hours]      # per-tier summary + recent anomalies
#   ./unifi_wan_monitor.sh --pause             # stop sampling (daemon stays up, idle)
#   ./unifi_wan_monitor.sh --resume            # resume sampling
#   ./unifi_wan_monitor.sh --status            # running/paused + row count + span
#   ./unifi_wan_monitor.sh --prune             # drop rows older than RETAIN_DAYS
#   ./unifi_wan_monitor.sh --discover          # print current path (to update targets)
#   ./unifi_wan_monitor.sh --plist             # print the LaunchDaemon plist
#   ./unifi_wan_monitor.sh --install           # print sudo install steps
#   ./unifi_wan_monitor.sh --uninstall         # print sudo uninstall steps
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$PROJECT_DIR/data"
DB="$DATA_DIR/wan_path.db"
EVENTLOG="$DATA_DIR/wan_path_events.log"
LOG="$DATA_DIR/wan_monitor.log"
STAMP="$DATA_DIR/.wan_trace_stamp"
PAUSE_FLAG="$DATA_DIR/.wan_paused"
LABEL="com.pavdog.unifi-wanmonitor"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

INTERVAL=30          # seconds between ticks
COUNT=5              # pings per target per tick
PERIOD=200           # ms between the COUNT pings
TIMEOUT=500          # ms per-ping timeout
RETAIN_DAYS=7        # rolling retention window
BB_INTERVAL=10800    # seconds between bufferbloat (networkQuality) tests (3h)
LAT_THRESH=80        # ms avg RTT above this on a non-LAN target => "trouble"
TRACE_COOLDOWN=300   # min seconds between traceroute captures
EVENTLOG_CAP=5242880 # 5 MB cap on the event log

# label@ip  — edit after --discover if Frontier's first hop changes
TARGETS=(
    "lan_gw@192.168.1.1"
    "frontier_hop1@47.189.192.1"
    "frontier_regional@184.19.246.8"
    "google@8.8.8.8"
    "cloudflare@1.1.1.1"
)

ensure_db() {
    mkdir -p "$DATA_DIR"
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS samples(
        epoch INTEGER, iso TEXT, tier TEXT, target TEXT,
        sent INTEGER, recv INTEGER, loss REAL,
        min_ms REAL, avg_ms REAL, max_ms REAL, jitter_ms REAL);
      CREATE INDEX IF NOT EXISTS idx_epoch ON samples(epoch);
      CREATE TABLE IF NOT EXISTS dns(epoch INTEGER, iso TEXT, resolver TEXT, ms REAL, ok INTEGER);
      CREATE INDEX IF NOT EXISTS idx_dns_epoch ON dns(epoch);
      CREATE TABLE IF NOT EXISTS wan_ip(epoch INTEGER, iso TEXT, ip TEXT);
      CREATE TABLE IF NOT EXISTS bufferbloat(epoch INTEGER, iso TEXT, dl_mbps REAL,
        ul_mbps REAL, idle_ms REAL, loaded_ms REAL, rpm REAL, grade TEXT);
      CREATE INDEX IF NOT EXISTS idx_bb_epoch ON bufferbloat(epoch);
      PRAGMA journal_mode=WAL;" >/dev/null
}

# Bufferbloat = latency-under-load, via Apple's networkQuality (RPM). This is THE
# game-host failure mode: ping fine idle, spikes the instant upload saturates.
# Loaded latency ~= 60000/RPM. Costs real bandwidth (~15s saturation) so it runs
# every BB_INTERVAL (default 3h), NOT every tick. Grade: A>=1000 B>=400 C>=200 else D.
bufferbloat_measure() {
    local now iso json row
    now=$(date +%s); iso=$(date "+%Y-%m-%d %H:%M:%S")
    json=$(networkQuality -c 2>/dev/null) || { echo "$iso bufferbloat: networkQuality failed" >> "$LOG"; return; }
    row=$(echo "$json" | /usr/bin/python3 -c '
import sys,json
d=json.load(sys.stdin)
dl=d.get("dl_throughput",0)/1e6; ul=d.get("ul_throughput",0)/1e6
idle=d.get("base_rtt"); rpm=d.get("responsiveness")
loaded=(60000/rpm) if rpm else None
grade="A" if rpm and rpm>=1000 else ("B" if rpm and rpm>=400 else ("C" if rpm and rpm>=200 else "D"))
if idle is None or rpm is None: sys.exit(1)
print(f"{dl:.1f}|{ul:.1f}|{idle:.1f}|{loaded:.1f}|{rpm:.0f}|{grade}")
') || { echo "$iso bufferbloat: parse failed" >> "$LOG"; return; }
    local dl ul idle loaded rpm grade
    IFS='|' read -r dl ul idle loaded rpm grade <<< "$row"
    sqlite3 "$DB" "INSERT INTO bufferbloat VALUES($now,'$iso',$dl,$ul,$idle,$loaded,$rpm,'$grade');"
    echo "$iso bufferbloat: idle ${idle}ms -> loaded ${loaded}ms, RPM $rpm (grade $grade), ${dl}/${ul} Mbps" >> "$LOG"
}

# DNS resolution time via each resolver (measures the 'feels like lag' path that
# ping can't see). dig reports server-side Query time; empty = timeout/failure.
dns_measure() {   # <label> <resolver_ip> <now> <iso>
    local label="$1" resolver="$2" now="$3" iso="$4" ms
    ms=$(dig +tries=1 +time=2 "@$resolver" google.com 2>/dev/null | awk '/Query time:/{print $4; exit}')
    if [[ -n "$ms" ]]; then
        sqlite3 "$DB" "INSERT INTO dns VALUES($now,'$iso','$label',$ms,1);"
    else
        sqlite3 "$DB" "INSERT INTO dns VALUES($now,'$iso','$label',NULL,0);"
    fi
}

# Public WAN IP via OpenDNS (a DNS query, no HTTP). Records only on change — a
# Frontier IP rotation silently breaks the gamer's Satisfactory port-forward.
check_wan_ip() {   # <now> <iso>
    local now="$1" iso="$2" ip last
    ip=$(dig +short +tries=1 +time=2 myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -1)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return
    last=$(sqlite3 "$DB" "SELECT ip FROM wan_ip ORDER BY epoch DESC LIMIT 1;")
    if [[ "$ip" != "$last" ]]; then
        sqlite3 "$DB" "INSERT INTO wan_ip VALUES($now,'$iso','$ip');"
        echo "$iso WAN public IP: ${last:-<none>} -> $ip" >> "$LOG"
        { echo "===== $iso  WAN public IP changed: ${last:-<none>} -> $ip  (check port-forwards) ====="; echo; } >> "$EVENTLOG"
    fi
}

_ips_and_labels() {   # populate IPS[] and LABELMAP ("ip=label;...")
    IPS=(); LABELMAP=""
    local entry lab ip
    for entry in "${TARGETS[@]}"; do
        lab="${entry%@*}"; ip="${entry#*@}"
        IPS+=("$ip")
        LABELMAP="${LABELMAP}${ip}=${lab};"
    done
}

sample() {
    ensure_db
    local now iso out parsed sql worst
    now=$(date +%s); iso=$(date "+%Y-%m-%d %H:%M:%S")
    _ips_and_labels

    # fping -C prints one line per target: "ip : rtt rtt - rtt rtt" ('-' = lost)
    out=$(fping -C "$COUNT" -p "$PERIOD" -t "$TIMEOUT" -q "${IPS[@]}" 2>&1 || true)

    # -> "tier|target|sent|recv|loss|min|avg|max|jit"  (min/avg/max/jit empty if all lost)
    parsed=$(echo "$out" | awk -v labels="$LABELMAP" '
        BEGIN{ n=split(labels,a,";"); for(i=1;i<=n;i++){ if(a[i]=="")continue; split(a[i],kv,"="); L[kv[1]]=kv[2] } }
        /:/ {
            ip=$1; recv=0; sent=0; sum=0; sumsq=0; min=1e9; max=-1
            for(i=3;i<=NF;i++){ v=$i; sent++; if(v=="-")continue; recv++; sum+=v; sumsq+=v*v; if(v<min)min=v; if(v>max)max=v }
            if(sent==0) next
            loss=(sent-recv)/sent*100
            lab=(ip in L)?L[ip]:ip
            if(recv>0){ avg=sum/recv; jit=(recv>1)?sqrt(((sumsq-recv*avg*avg)/(recv-1)<0)?0:(sumsq-recv*avg*avg)/(recv-1)):0
                printf "%s|%s|%d|%d|%.1f|%.3f|%.3f|%.3f|%.3f\n", lab, ip, sent, recv, loss, min, avg, max, jit }
            else printf "%s|%s|%d|%d|%.1f||||\n", lab, ip, sent, recv, loss
        }')

    [[ -z "$parsed" ]] && { echo "$iso WARN: fping produced no rows" >> "$LOG"; return; }

    sql="BEGIN;"
    local tier target sent recv loss mn av mx jt
    while IFS='|' read -r tier target sent recv loss mn av mx jt; do
        [[ -z "$tier" ]] && continue
        sql="$sql INSERT INTO samples VALUES($now,'$iso','$tier','$target',$sent,$recv,$loss,${mn:-NULL},${av:-NULL},${mx:-NULL},${jt:-NULL});"
    done <<< "$parsed"
    sql="$sql COMMIT;"
    echo "$sql" | sqlite3 "$DB"

    # DNS timing (gateway resolver = the client path; Cloudflare = external control)
    dns_measure "dns_gw" "192.168.1.1" "$now" "$iso"
    dns_measure "dns_cf" "1.1.1.1"     "$now" "$iso"
    # WAN public-IP change watch
    check_wan_ip "$now" "$iso"

    worst=$(echo "$parsed" | awk -F'|' -v thr="$LAT_THRESH" '
        $1!="lan_gw"{ loss=$5+0; avg=($7==""?9999:$7+0)
          if(loss>0||avg>thr){ s=loss*1000+avg; if(s>b){b=s; w=$2} } } END{ if(w!="") print w }')
    [[ -n "$worst" ]] && _maybe_trace "$worst" "$iso"
}

_maybe_trace() {
    local target="$1" iso="$2" last=0 now
    now=$(date +%s)
    [[ -f "$STAMP" ]] && last=$(cat "$STAMP" 2>/dev/null || echo 0)
    (( now - last < TRACE_COOLDOWN )) && return
    echo "$now" > "$STAMP"
    {
        echo "===== $iso  trouble -> traceroute $target ====="
        traceroute -n -q1 -w1 -m15 "$target" 2>&1
        echo
    } >> "$EVENTLOG"
    echo "$iso captured traceroute to $target" >> "$LOG"
}

prune() {
    [[ -f "$DB" ]] || return 0
    local cutoff
    cutoff=$(( $(date +%s) - RETAIN_DAYS*86400 ))
    sqlite3 "$DB" "DELETE FROM samples WHERE epoch < $cutoff; DELETE FROM dns WHERE epoch < $cutoff; DELETE FROM bufferbloat WHERE epoch < $cutoff;" >/dev/null
    if [[ -f "$EVENTLOG" ]]; then
        local sz; sz=$(wc -c < "$EVENTLOG")
        if (( sz > EVENTLOG_CAP )); then
            tail -c "$EVENTLOG_CAP" "$EVENTLOG" > "$EVENTLOG.tmp" && mv "$EVENTLOG.tmp" "$EVENTLOG"
        fi
    fi
    echo "$(date '+%F %T') pruned DB to last ${RETAIN_DAYS}d" >> "$LOG"
}

run() {
    ensure_db
    echo "$(date '+%F %T') wan_monitor started (interval ${INTERVAL}s, ${#TARGETS[@]} targets)" >> "$LOG"
    local last_prune=0 last_bb=0 now
    while true; do
        if [[ -f "$PAUSE_FLAG" ]]; then
            sleep 5
            continue
        fi
        sample || echo "$(date '+%F %T') sample error" >> "$LOG"
        now=$(date +%s)
        if (( now - last_bb > BB_INTERVAL )); then bufferbloat_measure; last_bb=$now; fi
        if (( now - last_prune > 86400 )); then prune; last_prune=$now; fi
        sleep "$INTERVAL"
    done
}

pause()  { mkdir -p "$DATA_DIR"; touch "$PAUSE_FLAG"; echo "Paused — daemon stays up but stops sampling. Resume with --resume."; }
resume() { rm -f "$PAUSE_FLAG"; echo "Resumed — sampling will restart within a few seconds."; }

status() {
    if [[ -f "$PAUSE_FLAG" ]]; then echo "state:   PAUSED (flag present)"; else echo "state:   ACTIVE"; fi
    if pgrep -f 'unifi_wan_monitor.sh --run' >/dev/null; then echo "daemon:  running (pid $(pgrep -f 'unifi_wan_monitor.sh --run' | tr '\n' ' '))"; else echo "daemon:  NOT running"; fi
    if [[ -f "$DB" ]]; then
        sqlite3 "$DB" "SELECT 'rows:    '||COUNT(*), 'span:    '||datetime(MIN(epoch),'unixepoch','localtime')||' -> '||datetime(MAX(epoch),'unixepoch','localtime') FROM samples;" | tr '|' '\n'
    else echo "db:      none yet ($DB)"; fi
}

show() {
    local hours="${1:-3}"
    [[ -f "$DB" ]] || { echo "No data yet at $DB — run --sample or start the daemon first." >&2; exit 1; }
    local cutoff; cutoff=$(( $(date +%s) - $(printf '%.0f' "$(echo "$hours*3600" | bc -l 2>/dev/null || echo $((hours*3600)))") ))
    echo "WAN-path monitor — last ${hours}h (from $DB)"
    echo
    sqlite3 -header -column "$DB" "
        SELECT tier,
               COUNT(*)                         AS n,
               ROUND(AVG(avg_ms),2)             AS avg_ms,
               ROUND(MAX(avg_ms),1)             AS max_avg,
               ROUND(AVG(jitter_ms),2)          AS jit_ms,
               ROUND(MAX(jitter_ms),1)          AS max_jit,
               ROUND(AVG(loss),2)               AS loss_pct,
               ROUND(MAX(loss),1)               AS max_loss
        FROM samples WHERE epoch >= $cutoff
        GROUP BY tier
        ORDER BY CASE tier WHEN 'lan_gw' THEN 1 WHEN 'frontier_hop1' THEN 2
                 WHEN 'frontier_regional' THEN 3 WHEN 'google' THEN 4 ELSE 5 END;"
    echo
    echo "Recent anomalies (loss>0 or avg>${LAT_THRESH}ms), newest last:"
    sqlite3 -column "$DB" "
        SELECT iso, tier, loss, avg, jitter FROM (
          SELECT epoch, iso, tier, ROUND(loss,1)||'%' AS loss,
                 COALESCE(ROUND(avg_ms,1)||'ms','DROP') AS avg,
                 COALESCE(ROUND(jitter_ms,1)||'ms','-') AS jitter
          FROM samples WHERE epoch >= $cutoff AND (loss > 0 OR avg_ms > $LAT_THRESH)
          ORDER BY epoch DESC LIMIT 20)
        ORDER BY epoch ASC;"
    echo
    echo "DNS resolution (avg ms / fail count) last ${hours}h:"
    sqlite3 -header -column "$DB" "
        SELECT resolver, COUNT(*) AS n, ROUND(AVG(ms),1) AS avg_ms,
               ROUND(MAX(ms),1) AS max_ms, SUM(CASE WHEN ok=0 THEN 1 ELSE 0 END) AS fails
        FROM dns WHERE epoch >= $cutoff GROUP BY resolver;"
    echo
    echo "WAN public IP (most recent + any changes in window):"
    sqlite3 -column "$DB" "SELECT iso, ip FROM wan_ip ORDER BY epoch DESC LIMIT 5;"
    echo
    echo "Bufferbloat (latency under load; grade A>=1000 B>=400 C>=200 else D RPM):"
    sqlite3 -header -column "$DB" "
        SELECT iso, ROUND(idle_ms,1)||'ms' AS idle, ROUND(loaded_ms,1)||'ms' AS loaded,
               ROUND(rpm) AS rpm, grade, ROUND(dl_mbps)||'/'||ROUND(ul_mbps) AS mbps
        FROM bufferbloat WHERE epoch >= $cutoff ORDER BY epoch DESC LIMIT 8;"
}

discover() {
    echo "Current path from this host (update TARGETS if Frontier's first hop changed):"
    traceroute -n -q1 -m6 -w1 8.8.8.8 2>&1
}

plist() {
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/unifi_wan_monitor.sh</string>
        <string>--run</string>
    </array>
    <key>UserName</key><string>pavdog</string>
    <key>GroupName</key><string>staff</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>WorkingDirectory</key><string>$PROJECT_DIR</string>
    <key>StandardErrorPath</key><string>$DATA_DIR/wan_monitor.err</string>
    <key>StandardOutPath</key><string>$DATA_DIR/wan_monitor.out</string>
</dict>
</plist>
EOF
}

install_cmds() {
    cat <<EOF
LaunchDaemon install — run these in a normal Terminal (needs sudo, which can't run via '!'):

  sudo bash -c '$SCRIPT_DIR/unifi_wan_monitor.sh --plist > "$PLIST"'
  sudo chown root:wheel "$PLIST"
  sudo chmod 644 "$PLIST"
  sudo launchctl bootstrap system "$PLIST"

Confirm:
  $SCRIPT_DIR/unifi_wan_monitor.sh --status

Pause/resume WITHOUT sudo (daemon stays loaded, just idles):
  $SCRIPT_DIR/unifi_wan_monitor.sh --pause
  $SCRIPT_DIR/unifi_wan_monitor.sh --resume

Fully stop later (needs sudo):
  sudo launchctl bootout system "$PLIST"
EOF
}

uninstall_cmds() {
    cat <<EOF
LaunchDaemon uninstall — run in a normal Terminal:

  sudo launchctl bootout system "$PLIST"
  sudo rm "$PLIST"

Data is preserved at $DB
EOF
}

case "${1:---show}" in
    --sample)     sample ;;
    --bufferbloat) ensure_db; bufferbloat_measure; echo "bufferbloat test recorded (see --show)";;
    --run)        run ;;
    --show)       show "${2:-3}" ;;
    --pause)      pause ;;
    --resume)     resume ;;
    --status)     status ;;
    --prune)      prune ;;
    --discover)   discover ;;
    --plist)      plist ;;
    --install)    install_cmds ;;
    --uninstall)  uninstall_cmds ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
    *)            echo "Usage: $0 [--sample|--bufferbloat|--run|--show [hours]|--pause|--resume|--status|--prune|--discover|--plist|--install|--uninstall]" >&2; exit 1 ;;
esac
