#!/usr/bin/env python3
"""Live WAN-path dashboard for unifi_wan_monitor.sh.

Serves a self-contained page (no external deps/CDNs) charting per-tier latency,
jitter, and packet loss from data/wan_path.db, plus an attribution banner (Local /
Frontier / Beyond / Healthy), DNS/WAN-IP/bufferbloat tiles, a 24h incident strip,
and a FactoryGame.log analysis panel (parsed from GameLogs/FactoryGame.log, Central time).

Pattern matches ruuvi (8090) and ecoflow (8091) dashboards. Port 8092.
Run by launchd (com.pavdog.unifi-wandashboard); KeepAlive.
"""
import collections
import datetime
import json
import re
import sqlite3
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT = 8092
GAME_LOG = Path(__file__).resolve().parent.parent / "Gamer" / "FactoryGame.log"
CENTRAL_OFFSET_H = 5      # Satisfactory logs in UTC; Seabrook TX = CDT = UTC-5 (summer)
MOVEMENT_LAG_THRESH = 20  # LogNetPlayerMovement warnings/hour above this = network lag
_fg_cache = {}
DB = Path(__file__).resolve().parent.parent / "data" / "wan_path.db"

# tier order + colors + "elevated" thresholds (ms avg) for attribution/coloring.
TIERS = [
    ("lan_gw",            "#4ade80", 5),
    ("frontier_hop1",     "#fbbf24", 40),
    ("frontier_regional", "#fb923c", 45),
    ("google",            "#60a5fa", 60),
    ("cloudflare",        "#a78bfa", 60),
]
TIER_LABEL = {
    "lan_gw": "LAN gateway (UDR7)",
    "frontier_hop1": "Frontier hop 1 (last mile)",
    "frontier_regional": "Frontier regional",
    "google": "Google 8.8.8.8 (beyond)",
    "cloudflare": "Cloudflare 1.1.1.1 (beyond)",
}


def _con():
    # normal connect + query_only, NOT ?mode=ro: a read-only connection can't open a
    # WAL database when no writer holds the -shm open (e.g. after the monitor daemon is
    # stopped), failing "unable to open database file". query_only keeps us read-only.
    c = sqlite3.connect(str(DB), timeout=3)
    c.execute("PRAGMA query_only=ON")
    return c


def load(hours):
    """Return {tier: [ [epoch, avg, jitter, loss, min, max], ... ]} within window.

    Long windows are bucketed (~1000 pts/tier max) so the payload stays small;
    short windows return full per-tick detail.
    """
    if not DB.exists():
        return {}
    cutoff = int(time.time() - hours * 3600)
    span = max(1, int(hours * 3600))
    bucket = max(1, span // 1000)          # seconds per bucket
    out = {t[0]: [] for t in TIERS}
    con = _con()
    try:
        if bucket <= 30:                    # full detail
            q = ("SELECT epoch,tier,avg_ms,jitter_ms,loss,min_ms,max_ms "
                 "FROM samples WHERE epoch>=? ORDER BY epoch")
            rows = con.execute(q, (cutoff,))
        else:                               # downsample
            q = ("SELECT (epoch/?)*? AS t, tier, AVG(avg_ms), AVG(jitter_ms), "
                 "MAX(loss), MIN(min_ms), MAX(max_ms) "
                 "FROM samples WHERE epoch>=? GROUP BY tier, epoch/? ORDER BY t")
            rows = con.execute(q, (bucket, bucket, cutoff, bucket))
        for r in rows:
            lab = r[1]
            if lab in out:
                out[lab].append([int(r[0]), r[2], r[3], r[4], r[5], r[6]])
    finally:
        con.close()
    return out


def attribution(data):
    """Classify the most recent ~2 minutes. Returns (state, detail)."""
    recent = {}
    if DB.exists():
        con = _con()
        try:
            cutoff = int(time.time() - 120)
            for r in con.execute(
                "SELECT tier, AVG(avg_ms), MAX(loss) FROM samples "
                "WHERE epoch>=? GROUP BY tier", (cutoff,)):
                recent[r[0]] = {"avg": r[1], "loss": r[2] or 0}
        finally:
            con.close()
    thr = {t[0]: t[2] for t in TIERS}

    def bad(lab):
        m = recent.get(lab)
        if not m:
            return False
        if m["loss"] and m["loss"] > 0:
            return True
        return m["avg"] is not None and m["avg"] > thr[lab]

    if not recent:
        return ("NO DATA", "No samples in the last 2 minutes — is the monitor running?")
    # total loss is its own verdict — "LOCAL"/"FRONTIER" understate a hard outage
    seen_wan = [t for t in WAN_TIERS if t in recent]
    if seen_wan and all((recent[t]["loss"] or 0) >= 100 for t in seen_wan):
        if (recent.get("lan_gw", {}).get("loss") or 0) >= 100:
            return ("OUTAGE", "Everything is unreachable INCLUDING the LAN gateway — the UDR7 itself is down or rebooting (firmware update / power / crash). Not Frontier.")
        return ("OUTAGE", "The LAN gateway answers but every external target is 100% lost — the Internet is down while the house network is fine. This is Frontier/the ONT.")
    if bad("lan_gw"):
        return ("LOCAL", "The LAN gateway itself is slow/lossy — this is on our side (UDR7/host), not Frontier.")
    # A real WAN problem must show at BOTH external anchors (end-to-end truth). hop1's
    # ICMP-deprioritization noise, or a single-target fluke, never triggers on its own.
    ext_bad = bad("google") and bad("cloudflare")
    if ext_bad:
        if bad("frontier_regional") or bad("frontier_hop1"):
            return ("FRONTIER", "Google AND Cloudflare are both degraded and it reaches back to Frontier's own hops while the LAN is clean — this is Frontier's access/backbone. Screenshot for support.")
        return ("BEYOND", "Google AND Cloudflare are degraded but Frontier's own hops look fine — the problem is past Frontier (peering/transit or the remote target).")
    return ("HEALTHY", "All tiers nominal — no loss, and any single-tier latency blip (esp. Frontier hop 1) isn't corroborated end-to-end, so it's measurement noise, not a real problem.")


DNS_THRESH = 120        # ms — gateway resolver slower than this "feels like lag"
DNS_LABEL = {"dns_gw": "DNS via gateway", "dns_cf": "DNS via Cloudflare"}


def dns_latest():
    out = {}
    if not DB.exists():
        return out
    con = _con()
    try:
        for res in ("dns_gw", "dns_cf"):
            row = con.execute(
                "SELECT ms,ok FROM dns WHERE resolver=? ORDER BY epoch DESC LIMIT 1",
                (res,)).fetchone()
            if row:
                out[res] = {"ms": row[0], "ok": row[1]}
    finally:
        con.close()
    return out


def wan_info():
    if not DB.exists():
        return {}
    con = _con()
    try:
        row = con.execute("SELECT epoch,ip FROM wan_ip ORDER BY epoch DESC LIMIT 1").fetchone()
        total = con.execute("SELECT COUNT(*) FROM wan_ip").fetchone()[0]
    finally:
        con.close()
    if not row:
        return {}
    changed_24h = total > 1 and int(row[0]) >= int(time.time() - 86400)
    return {"ip": row[1], "since": int(row[0]), "changed_24h": changed_24h}


_FG_TS = re.compile(r'^\[(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):\d+\]')
_FG_IP = re.compile(r'\[::ffff:([0-9.]+)\]:\d+')


def _fg_local(y, mo, d, h, mi, s):
    """Log timestamp (UTC) -> Central-time string, no UTC shown."""
    dt = datetime.datetime(int(y), int(mo), int(d), int(h), int(mi), int(s)) \
        - datetime.timedelta(hours=CENTRAL_OFFSET_H)
    return dt.strftime("%a %m/%d %I:%M %p")


def analyze_factorygame_log():
    """Parse GameLogs/FactoryGame.log (cached by mtime). All times returned in Central."""
    if not GAME_LOG.exists():
        return {"present": False}
    mtime = GAME_LOG.stat().st_mtime
    if _fg_cache.get("mtime") == mtime:
        return _fg_cache["data"]

    first = last = None
    hitches = 0
    saves = []
    movement = collections.Counter()      # keyed by local "Day MM/DD HH:00"
    timeouts, disconnects = [], []
    with GAME_LOG.open(errors="ignore") as fh:
        for line in fh:
            m = _FG_TS.match(line)
            g = m.groups() if m else None
            if g:
                if first is None:
                    first = _fg_local(*g)
                last = _fg_local(*g)
            if "LogNetPlayerMovement: Warning" in line and g:
                dt = datetime.datetime(int(g[0]), int(g[1]), int(g[2]), int(g[3])) \
                    - datetime.timedelta(hours=CENTRAL_OFFSET_H)
                movement[dt.strftime("%a %m/%d %I %p")] += 1
            elif "World Serialization (save):" in line:
                mm = re.search(r"save\): ([0-9.]+) seconds", line)
                if mm:
                    saves.append(float(mm.group(1)))
            elif "hitch" in line.lower():
                hitches += 1
            elif "LogNet: Warning: UNetConnection::Tick" in line and "TIMED OUT" in line and g:
                ip = _FG_IP.search(line)   # canonical line only (event logs 4 lines)
                timeouts.append({"time": _fg_local(*g), "ip": ip.group(1) if ip else "?"})
            elif "UChannel::CleanUp: ChIndex == 0. Closing connection" in line and g:
                ip = _FG_IP.search(line)
                disconnects.append({"time": _fg_local(*g), "ip": ip.group(1) if ip else "?"})

    peak_hour, peak_ct = (movement.most_common(1)[0] if movement else (None, 0))
    saves_n = len(saves)
    verdict = ("network" if peak_ct >= MOVEMENT_LAG_THRESH else
               ("server" if hitches > 20 else "clean"))
    data = {
        "present": True,
        "span": {"first": first, "last": last},
        "hitches": hitches,
        "saves": {"n": saves_n,
                  "avg": round(sum(saves) / saves_n, 2) if saves_n else None,
                  "max": round(max(saves), 2) if saves_n else None},
        "movement_total": sum(movement.values()),
        "movement_peak": {"hour": peak_hour, "count": peak_ct},
        "timeouts": timeouts[-12:],
        "disconnects": disconnects[-16:],
        "verdict": verdict,
    }
    _fg_cache["mtime"] = mtime
    _fg_cache["data"] = data
    return data


def bufferbloat_latest():
    if not DB.exists():
        return {}
    con = _con()
    try:
        row = con.execute(
            "SELECT epoch,dl_mbps,ul_mbps,idle_ms,loaded_ms,rpm,grade "
            "FROM bufferbloat ORDER BY epoch DESC LIMIT 1").fetchone()
    finally:
        con.close()
    if not row:
        return {}
    return {"epoch": int(row[0]), "dl": row[1], "ul": row[2], "idle": row[3],
            "loaded": row[4], "rpm": row[5], "grade": row[6]}


def recent_incidents(hours=24):
    """Persistent 'trouble in last N hours' summary (auto-ages out with the window).

    Uses per-tier avg thresholds + any loss. frontier_hop1 is EXCLUDED — its ICMP
    baseline is too noisy (deprioritized pings spike to 90ms+ with no real impact), so
    it charts/tiles but never registers an incident. Real WAN trouble shows at the
    external anchors / regional hop, which are trustworthy.
    """
    empty = {"count": 0, "tiers": [], "last": None}
    if not DB.exists():
        return empty
    cutoff = int(time.time() - hours * 3600)
    thr_case = " ".join(f"WHEN '{t[0]}' THEN {t[2]}" for t in TIERS if t[0] != "frontier_hop1")
    con = _con()
    try:
        rows = con.execute(
            f"SELECT epoch,tier,loss,avg_ms FROM samples WHERE epoch>=? AND tier!='frontier_hop1' AND "
            f"(loss>0 OR avg_ms > CASE tier {thr_case} ELSE 999999 END) "
            f"ORDER BY epoch DESC LIMIT 2000", (cutoff,)).fetchall()
    finally:
        con.close()
    # also count DNS trouble (failures or slow gateway resolution) in the window
    con = _con()
    try:
        dns_rows = con.execute(
            "SELECT epoch,resolver FROM dns WHERE epoch>=? AND (ok=0 OR ms>?) "
            "ORDER BY epoch DESC", (cutoff, DNS_THRESH)).fetchall()
        bb_rows = con.execute(
            "SELECT epoch,'bufferbloat' FROM bufferbloat WHERE epoch>=? AND grade='D'",
            (cutoff,)).fetchall()
    finally:
        con.close()
    allrows = list(rows) + list(dns_rows) + list(bb_rows)
    if not allrows:
        return empty
    tiers = sorted({r[1] for r in allrows})
    last = max(int(r[0]) for r in allrows)
    return {"count": len(allrows), "tiers": tiers, "last": last}


SAMPLE_INTERVAL = 30    # unifi_wan_monitor.sh INTERVAL — used to size outage durations
WAN_TIERS = ["frontier_hop1", "frontier_regional", "google", "cloudflare"]


SYSLOG_DIR = Path.home() / "Library" / "Logs" / "unifi-syslog"
_SYS_TS = re.compile(r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) ')
_FW_VER = re.compile(r'fwupdate\[\d+\]: Version: (\S+)')
_syslog_cache = {"at": 0, "val": []}


def _syslog_events():
    """Reboot/firmware markers from the UniFi syslog the syslog host already receives.

    ~500 MB scans in about 1.4s, so it is cached for 15 min — plenty, since these
    events are rare and outages are minutes long.
    """
    now = time.time()
    if now - _syslog_cache["at"] < 900:
        return _syslog_cache["val"]
    events = []
    if SYSLOG_DIR.exists():
        for f in sorted(SYSLOG_DIR.glob("unifi.log*")):
            try:
                with f.open(errors="ignore") as fh:
                    for line in fh:
                        if "fwupdate" not in line and "Systool Rebooting" not in line:
                            continue
                        m = _SYS_TS.match(line)
                        if not m:
                            continue
                        ep = int(time.mktime(tuple(int(x) for x in m.groups())
                                             + (0, 0, -1)))
                        fw = _FW_VER.search(line)
                        if fw:
                            events.append((ep, "firmware", fw.group(1)))
                        elif "Systool Rebooting" in line:
                            events.append((ep, "reboot", ""))
            except OSError:
                continue
    events.sort()
    _syslog_cache.update(at=now, val=events)
    return events


def _explain(o):
    """Name the cause of an outage from syslog + say when each layer came back."""
    if o["kind"] == "gateway":
        window = [e for e in _syslog_events() if o["start"] - 900 <= e[0] <= o["end"] + 60]
        fw = next((e for e in window if e[1] == "firmware"), None)
        if fw:
            ver = fw[2].split(".v")[-1].split(".")[0:3]
            o["cause"] = "Firmware update → v" + ".".join(ver) if len(ver) == 3 else "Firmware update"
            o["cause_detail"] = f"UDR7 installed {fw[2]} and rebooted to apply it — planned by UniFi, not a fault."
        elif any(e[1] == "reboot" for e in window):
            o["cause"] = "Gateway reboot"
            o["cause_detail"] = "The UDR7 logged a clean reboot with no firmware install — manual reboot, or the OS restarting itself."
        else:
            o["cause"] = "Unexplained"
            o["cause_detail"] = "No shutdown or firmware entry in syslog before it went dark — power loss, hard crash, or the syslog feed died with it."
    elif o["kind"] == "wan":
        o["cause"] = "Frontier / ONT"
        o["cause_detail"] = "The gateway stayed up and reachable the whole time; only the outside world vanished."
    else:
        o["cause"] = "Monitor blind"
        o["cause_detail"] = "No samples were written — the monitor daemon or the syslog host itself was down, so the network's real state is unknown."

    # per-tier recovery: first clean sample after the outage ended
    if not DB.exists():
        return
    con = _con()
    try:
        back = {}
        for tier, _c, _t in TIERS:
            # anchor on the tier's LAST fully-lost sample — starting from the outage
            # start would report a tier as "back" at a tick where it hadn't failed yet
            lastbad = con.execute(
                "SELECT MAX(epoch) FROM samples WHERE tier=? AND loss>=100 AND epoch BETWEEN ? AND ?",
                (tier, o["start"], o["end"])).fetchone()[0]
            if lastbad is None:
                continue        # this tier never went fully down in this window
            row = con.execute(
                "SELECT epoch FROM samples WHERE tier=? AND epoch>? AND (loss IS NULL OR loss<100) "
                "ORDER BY epoch LIMIT 1", (tier, int(lastbad))).fetchone()
            if row:
                back[tier] = int(row[0])
    finally:
        con.close()
    o["recovery"] = back


_outage_cache = {"at": 0, "val": []}


def outages(hours=168, merge_gap=180):
    """Hard-down windows: everything unreachable, or the monitor itself blind.

    Three kinds, because they mean very different things:
      gateway — lan_gw is 100% lost too, so the UDR7 (or our path to it) is down.
                A whole-network drop: reboot/firmware update/power, NOT Frontier.
      wan     — LAN gateway answers but every external tier is 100% lost: the
                Internet is gone while the house network is fine (Frontier/ONT).
      nodata  — no samples at all for >5 min (monitor stopped, or the syslog host
                lost its own link) — an unknown, and worth showing as one.
    """
    if not DB.exists():
        return []
    # a 7-day scan is ~100k rows; every browser poll would redo it, so cache 60s
    now = time.time()
    if now - _outage_cache["at"] < 60:
        return _outage_cache["val"]
    cutoff = int(now - hours * 3600)
    con = _con()
    try:
        rows = con.execute(
            "SELECT epoch,tier,loss FROM samples WHERE epoch>=? ORDER BY epoch",
            (cutoff,)).fetchall()
    finally:
        con.close()
    by_tick = {}
    for e, tier, loss in rows:
        by_tick.setdefault(int(e), {})[tier] = loss

    marks = []          # (epoch, kind)
    prev = None
    for e in sorted(by_tick):
        if prev is not None and e - prev > 300:
            marks.append((prev, "nodata", e - prev))
        prev = e
        m = by_tick[e]
        seen_wan = [t for t in WAN_TIERS if t in m]
        wan_down = bool(seen_wan) and all((m[t] or 0) >= 100 for t in seen_wan)
        if not wan_down:
            continue
        lan = m.get("lan_gw")
        marks.append((e, "gateway" if (lan is not None and lan >= 100) else "wan",
                      SAMPLE_INTERVAL))

    out = []
    for start, kind, dur in marks:
        if out and start - out[-1]["end"] <= merge_gap:
            cur = out[-1]
            cur["end"] = max(cur["end"], start + dur)
            # a gateway drop subsumes the wan-only ticks on either side of it
            if kind == "gateway" or cur["kind"] == "gateway":
                cur["kind"] = "gateway"
            elif kind == "nodata" and cur["kind"] == "wan":
                pass
            continue
        out.append({"start": start, "end": start + dur, "kind": kind})
    for o in out:
        o["secs"] = max(SAMPLE_INTERVAL, o["end"] - o["start"])
    out = out[-40:]
    for o in out:
        _explain(o)
    _outage_cache.update(at=now, val=out)
    return out


PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WAN Path Monitor</title>
<style>
:root{--bg:#0b1220;--panel:#131c2e;--ink:#e6edf6;--dim:#8aa0bd;--line:#22304a}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:16px;flex-wrap:wrap}
h1{font-size:17px;margin:0;font-weight:650}
.controls{margin-left:auto;display:flex;gap:8px;align-items:center}
select,button{background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:6px 10px;font-size:13px}
.banner{margin:14px 20px;padding:14px 16px;border-radius:12px;border:1px solid var(--line);display:flex;gap:14px;align-items:center}
.badge{font-weight:800;letter-spacing:.5px;padding:6px 12px;border-radius:8px;font-size:15px}
.b-HEALTHY{background:#0f2e1c;color:#4ade80}.b-FRONTIER{background:#3a2410;color:#fb923c}
.b-BEYOND{background:#10243a;color:#60a5fa}.b-LOCAL{background:#3a1220;color:#f87171}
.b-NODATA,.b-NO{background:#20242c;color:#8aa0bd}.b-OUTAGE{background:#4a0f0f;color:#fca5a5}
.outages{margin:0 20px 14px;padding:10px 16px;border-radius:10px;font-size:13px;border:1px solid var(--line);background:#2a0f14;color:#fca5a5}
.outages table{width:100%;border-collapse:collapse;font-size:12.5px;margin-top:8px}
.outages th{text-align:left;color:#e0a0a8;font-weight:600;padding:3px 10px 3px 0}
.outages td{padding:3px 10px 3px 0;color:var(--ink)}
.otag{font-size:11px;padding:1px 7px;border-radius:6px;font-weight:700}
.otag.gateway{background:#4a0f0f;color:#fca5a5}.otag.wan{background:#3a2410;color:#fb923c}
.otag.nodata{background:#20242c;color:#8aa0bd}
.incident{margin:0 20px 14px;padding:10px 16px;border-radius:10px;font-size:13px;border:1px solid var(--line)}
.incident.bad{background:#2a1a0e;color:#fbbf24}
.incident.good{background:#0f2115;color:#6ee7a0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:12px;margin:0 20px 14px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.tile .name{font-size:12px;color:var(--dim);display:flex;align-items:center;gap:7px}
.dot{width:9px;height:9px;border-radius:50%}
.tile .big{font-size:24px;font-weight:750;margin-top:6px}
.tile .sub{font-size:12px;color:var(--dim);margin-top:2px}
.warn{color:#f87171}.ok{color:#4ade80}.mid{color:#fbbf24}
.charts{margin:0 20px 30px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:14px}
.chdr{display:flex;align-items:center;justify-content:space-between;margin:0 0 8px}
.card h2{font-size:13px;margin:0;color:var(--dim);font-weight:600}
.seg{display:inline-flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.seg button{background:transparent;border:0;border-radius:0;border-left:1px solid var(--line);padding:4px 10px;font-size:12px;color:var(--dim);cursor:pointer}
.seg button:first-child{border-left:0}
.seg button.on{background:#22304a;color:var(--ink);font-weight:600}
canvas{width:100%;height:220px;display:block}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--dim);margin-top:8px}
.legend span{display:inline-flex;align-items:center;gap:6px}
.notes{margin:0 20px 18px;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:14px 18px}
.notes h3{font-size:13px;margin:0 0 10px;color:var(--ink)}
.notes ul{margin:0;padding-left:18px}
.notes li{font-size:13px;color:var(--dim);margin:5px 0;line-height:1.5}
.notes b{color:var(--ink)}
.k{display:inline-block;width:9px;height:9px;border-radius:50%;vertical-align:middle;margin:0 2px}
.fgv{font-weight:800;padding:5px 11px;border-radius:8px;font-size:13px;letter-spacing:.3px}
.fgv.network{background:#3a2410;color:#fb923c}.fgv.server{background:#3a1220;color:#f87171}.fgv.clean{background:#0f2e1c;color:#4ade80}
.fgstat{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin:12px 0}
.fgstat .s{background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:9px 12px}
.fgstat .s .l{font-size:11px;color:var(--dim)}.fgstat .s .v{font-size:19px;font-weight:700;margin-top:3px}
.fgtl{width:100%;border-collapse:collapse;font-size:12.5px;margin-top:6px}
.fgtl th{text-align:left;color:var(--dim);font-weight:600;padding:4px 10px;border-bottom:1px solid var(--line)}
.fgtl td{padding:4px 10px;border-bottom:1px solid var(--line);color:var(--ink)}
.fgtl .tag{font-size:11px;padding:1px 7px;border-radius:6px}
.tag.to{background:#3a1220;color:#f87171}.tag.dc{background:#20242c;color:#8aa0bd}
.foot{color:var(--dim);font-size:12px;margin:0 20px 24px}
</style></head><body>
<header>
  <h1>WAN Path Monitor <span style="color:var(--dim);font-weight:400">· Frontier attribution</span></h1>
  <div class="controls">
    <button id="refresh">Refresh</button>
    <span id="auto" style="color:var(--dim)">auto 20s</span>
  </div>
</header>
<div id="banner" class="banner"><div class="badge b-NODATA" id="badge">…</div><div id="detail">loading…</div></div>
<div id="incident" class="incident good" style="display:none"></div>
<div id="outages" class="outages" style="display:none"></div>
<div class="tiles" id="tiles"></div>
<div class="charts">
  <div class="card">
    <div class="chdr"><h2>Latency — avg RTT (ms)</h2>
      <div class="seg" data-chart="c_lat"><button data-h="1" class="on">1h</button><button data-h="6">6h</button><button data-h="24">24h</button><button data-h="72">3d</button><button data-h="168">7d</button></div></div>
    <canvas id="c_lat"></canvas><div class="legend" id="leg"></div></div>
  <div class="card">
    <div class="chdr"><h2>Jitter — stddev of ping RTTs (ms)</h2>
      <div class="seg" data-chart="c_jit"><button data-h="1" class="on">1h</button><button data-h="6">6h</button><button data-h="24">24h</button><button data-h="72">3d</button><button data-h="168">7d</button></div></div>
    <canvas id="c_jit"></canvas></div>
  <div class="card">
    <div class="chdr"><h2>Packet loss (%)</h2>
      <div class="seg" data-chart="c_loss"><button data-h="1" class="on">1h</button><button data-h="6">6h</button><button data-h="24">24h</button><button data-h="72">3d</button><button data-h="168">7d</button></div></div>
    <canvas id="c_loss"></canvas></div>
</div>
<div class="notes">
  <h3>How to read this dashboard</h3>
  <ul>
    <li><b><span class="k" style="background:#fbbf24"></span>Frontier hop 1 looking jittery is NORMAL — ignore it on its own.</b>
        ISP first-hop routers answer pings at low priority, so this line looks noisy even when everything is fine.
        The proof it's harmless: the tiers <i>behind</i> it (regional, Google, Cloudflare) stay smooth.</li>
    <li><b><span class="k" style="background:#fb923c"></span>Trust "Frontier regional" as the real Frontier signal</b> — it isn't rate-limited the way hop 1 is.</li>
    <li><b><span class="k" style="background:#4ade80"></span>Green (LAN gateway) flat near ~0.6 ms = our side (UDR7/home network) is fine.</b>
        If green lifts off the floor, the problem is local — not Frontier.</li>
    <li><b>It's Frontier</b> when latency/loss rises at hop 1 <i>and carries through</i> to regional +
        <span class="k" style="background:#60a5fa"></span>Google +
        <span class="k" style="background:#a78bfa"></span>Cloudflare together, while green stays flat. Banner turns orange (FRONTIER).</li>
    <li><b>It's beyond Frontier</b> (peering/transit or the game/Discord server itself) when only Google/Cloudflare degrade but Frontier regional stays flat. Banner turns blue (BEYOND).</li>
    <li><b>Jitter is what wrecks games &amp; voice</b> — steady 60 ms is fine; 60 ms bouncing to 400 ms is not. Watch the jitter chart during lag, not just latency.</li>
    <li><b>Hard outages get their own red strip</b> (last 7 days) and are shaded on every chart.
        <span class="k" style="background:#f87171"></span><b>GATEWAY DOWN</b> = the UDR7 itself stopped answering — a reboot,
        firmware auto-update or power event; the whole house was offline and it is <i>not</i> Frontier's fault.
        <span class="k" style="background:#fb923c"></span><b>INTERNET DOWN</b> = the gateway answered fine but nothing outside did — that one <i>is</i> Frontier/the ONT.
        <span class="k" style="background:#8aa0bd"></span><b>NO DATA</b> = the monitor itself went blind (syslog host asleep/daemon stopped) — cause unknown.</li>
    <li>The banner up top decides using <b>average latency + packet loss</b> (not hop-1 jitter), so hop 1's noisy baseline never triggers a false alarm.</li>
  </ul>
  <h3 style="margin-top:16px">About the bufferbloat test (the pink tile)</h3>
  <ul>
    <li><b>What it is:</b> bufferbloat = how much latency <i>inflates when the connection is busy</i>. Your speed can be "2 Gbps" and pings still fine when idle, yet the moment the link fills up, packets queue in an oversized buffer and latency spikes — which is what actually lags games and voice.</li>
    <li><b>How we measure it:</b> every 3 hours the syslog host runs Apple's built-in <b>networkQuality</b>, which deliberately saturates the link for ~15&nbsp;seconds and measures <b>responsiveness (RPM)</b> — round-trips per minute under load. Loaded latency ≈ <b>60000 ÷ RPM</b>. The tile shows the grade, the loaded latency, and idle→loaded so you can see the jump. (It uses real bandwidth, so it runs periodically, not continuously.)</li>
    <li><b>Grades:</b> <b>A</b> = RPM ≥ 1000 (minimal bufferbloat), <b>B</b> ≥ 400 (mild), <b>C</b> ≥ 200 (noticeable), <b>D</b> &lt; 200 (severe — a D in the last 24h raises the incident strip).</li>
    <li><b>Why it matters for Gamer specifically:</b> hosting a Satisfactory server is <i>upload-heavy</i>. When his upload saturates, everything else (his game traffic, his friends' data, Discord) queues behind it and latency balloons — the classic "fast internet but everyone's lagging" cause, and it looks identical to a network fault unless you measure under load like this.</li>
    <li><b>If it's ever bad (C/D):</b> the fix is enabling <b>Smart Queues / SQM (FQ-CoDel)</b> on the UDR7, which caps the buffer and keeps latency low even when the link is full — at the cost of a little peak throughput.</li>
  </ul>
</div>
<div class="notes" id="fganalysis"><h3>FactoryGame.log Analysis</h3><p style="color:var(--dim)">loading…</p></div>
<div class="foot" id="foot"></div>
<script>
const TIERS=__TIERS__, LABELS=__LABELS__;
const CH=[{id:'c_lat',idx:1,loss:false},{id:'c_jit',idx:2,loss:false},{id:'c_loss',idx:3,loss:true}];
const chartHours={c_lat:1,c_jit:1,c_loss:1};
let timer=null, cyc={}, OUTAGES=[];
function fmt(v,u){return v==null?'—':(Math.round(v*100)/100)+(u||'')}
async function getData(h,fresh){ if(!fresh&&cyc[h])return cyc[h]; const r=await fetch('/api/data?hours='+h); const j=await r.json(); cyc[h]=j; return j; }
async function refreshAll(){
  cyc={};
  const meta=await getData(1);
  renderMeta(meta);
  for(const c of CH){ const j=await getData(chartHours[c.id]); chart(c.id,j.data,c.idx,c.loss); }
  loadFG();
}
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
async function loadFG(){
  const el=document.getElementById('fganalysis');
  let a; try{ a=await (await fetch('/api/factorygame')).json(); }catch(e){ return; }
  if(!a.present){ el.innerHTML='<h3>FactoryGame.log Analysis</h3>'+
    '<p style="color:var(--dim)">No log loaded. Drop a <b>FactoryGame.log</b> in the <code>GameLogs/</code> folder and refresh — it will be analyzed here (all times Central).</p>'; return; }
  const V={network:['NETWORK','Server was healthy; player data arrived late — the lag was network-side, not the server/PC. Cross-check the tiers above for that time to see if it was Frontier.'],
           server:['SERVER / PC','The server itself was stalling (hitches) — this points at the host PC, not the network.'],
           clean:['CLEAN','No network-lag or server-stall signature in this log.']}[a.verdict];
  const sv=a.saves;
  let h=`<h3>FactoryGame.log Analysis <span class="fgv ${a.verdict}">${V[0]}</span></h3>`;
  h+=`<p style="color:var(--dim);margin:2px 0 0">Session ${esc(a.span.first)} → ${esc(a.span.last)} · all times Central. ${V[1]}</p>`;
  h+=`<div class="fgstat">`+
    `<div class="s"><div class="l">Lag-comp warnings (peak hr)</div><div class="v ${a.movement_peak.count>=20?'warn':'ok'}">${a.movement_peak.count}</div><div class="l">${a.movement_peak.hour?esc(a.movement_peak.hour):'—'}</div></div>`+
    `<div class="s"><div class="l">Server hitches (stalls)</div><div class="v ${a.hitches>20?'warn':'ok'}">${a.hitches}</div><div class="l">whole session</div></div>`+
    `<div class="s"><div class="l">Autosave time</div><div class="v ${sv.max>3?'warn':'ok'}">${sv.avg==null?'—':sv.avg+'s'}</div><div class="l">max ${sv.max==null?'—':sv.max+'s'} · n=${sv.n}</div></div>`+
    `<div class="s"><div class="l">Player timeouts</div><div class="v ${a.timeouts.length?'mid':'ok'}">${a.timeouts.length}</div><div class="l">60s network death</div></div>`+
    `</div>`;
  const rows=[...a.timeouts.map(t=>({...t,k:'to'})),...a.disconnects.map(t=>({...t,k:'dc'}))];
  if(rows.length){
    h+=`<table class="fgtl"><tr><th>Time (Central)</th><th>Event</th><th>Client IP</th></tr>`;
    for(const r of rows){
      h+=`<tr><td>${esc(r.time)}</td><td><span class="tag ${r.k}">${r.k==='to'?'TIMED OUT':'disconnect'}</span></td><td>${esc(r.ip)}</td></tr>`;
    }
    h+=`</table><p style="color:var(--dim);font-size:12px;margin-top:8px"><b>TIMED OUT</b> = client went silent 60s (hard network break). <b>disconnect</b> = clean leave/quit (often "gave up from lag"). Lag-comp warnings spiking in one hour = the network was delivering player data late that hour.</p>`;
  }
  el.innerHTML=h;
}
const OBAND={gateway:{fill:'rgba(248,113,113,.20)',edge:'#f87171'},
             wan:    {fill:'rgba(251,146,60,.18)', edge:'#fb923c'},
             nodata: {fill:'rgba(138,160,189,.14)',edge:'#8aa0bd'}};
const OKIND={gateway:['GATEWAY DOWN','whole network — UDR7 rebooted / lost power (not Frontier)'],
             wan:['INTERNET DOWN','LAN fine, all external targets lost — Frontier / ONT'],
             nodata:['NO DATA','monitor stopped or the syslog host lost its own link']};
function dur(s){return s<90?s+'s':(s<5400?Math.round(s/60)+' min':(s/3600).toFixed(1)+' h')}
function renderOutages(list){
  OUTAGES=list;
  const el=document.getElementById('outages');
  const recent=list.filter(o=>o.end>=Date.now()/1000-7*86400);
  if(!recent.length){el.style.display='none';return}
  el.style.display='';
  const f=t=>new Date(t*1000).toLocaleString([],{weekday:'short',month:'numeric',day:'numeric',hour:'numeric',minute:'2-digit'});
  let h=`⛔ <b>${recent.length} hard outage${recent.length>1?'s':''} in the last 7 days</b> — full loss of connectivity, shaded on the charts below.`;
  h+='<table><tr><th>Start</th><th>End</th><th>Length</th><th>What</th><th>Cause</th></tr>';
  const hhmmss=t=>new Date(t*1000).toLocaleTimeString([],{hour:'numeric',minute:'2-digit',second:'2-digit'});
  for(const o of recent.slice().reverse()){
    const k=OKIND[o.kind]||[o.kind,''];
    h+=`<tr><td>${f(o.start)}</td><td>${new Date(o.end*1000).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})}</td>`+
       `<td>${dur(o.secs)}</td><td><span class="otag ${o.kind}">${k[0]}</span></td>`+
       `<td><b>${esc(o.cause||'—')}</b></td></tr>`;
    // recovery line: when each layer answered again, so you can see LAN-before-WAN
    const rec=o.recovery||{};
    const parts=TIERS.map(([t])=>rec[t]?`${LABELS[t]} ${hhmmss(rec[t])}`:null).filter(Boolean);
    h+=`<tr><td colspan="5" style="color:var(--dim);padding-bottom:9px">${esc(o.cause_detail||'')}`+
       (parts.length?`<br><span style="opacity:.85">Back online — ${esc(parts.join(' · '))}</span>`:'')+
       `<br><span style="opacity:.7">${esc(k[1])}</span></td></tr>`;
  }
  el.innerHTML=h+'</table>';
}
function renderMeta(j){
  const data=j.data, attr=j.attribution, inc=j.incidents||{count:0,tiers:[]};
  const badge=document.getElementById('badge'); const key=attr.state.replace(/ /g,'');
  badge.className='badge b-'+key; badge.textContent=attr.state;
  document.getElementById('detail').textContent=attr.detail;
  // persistent 24h incident strip
  const el=document.getElementById('incident'); el.style.display='';
  if(inc.count>0){
    const nowS=Date.now()/1000, mins=Math.round((nowS-inc.last)/60);
    const ago=mins<60?mins+'m ago':(mins<1440?Math.round(mins/60)+'h ago':Math.round(mins/1440)+'d ago');
    const d=new Date(inc.last*1000);
    const names=inc.tiers.map(t=>LABELS[t]||t).join(', ');
    el.className='incident bad';
    el.innerHTML=`⚠ <b>Trouble seen in the last 24h</b> — ${names} · last at ${d.toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'})} (${ago}) · ${inc.count} sample(s). <span style="opacity:.7">Auto-clears after 24h with no new trouble.</span>`;
  } else { el.className='incident good'; el.innerHTML='✓ No trouble in the last 24h.'; }
  renderOutages(j.outages||[]);
  // tiles: latest sample per tier (from the 1h meta window)
  const tiles=document.getElementById('tiles'); tiles.innerHTML=''; const leg=document.getElementById('leg'); leg.innerHTML='';
  for(const [tier,color,thr] of TIERS){
    const rows=data[tier]||[]; const last=rows.length?rows[rows.length-1]:null;
    const avg=last?last[1]:null, jit=last?last[2]:null, loss=last?last[3]:null;
    let cls='ok'; if(last){ if((loss&&loss>0)||(avg!=null&&avg>thr)) cls='warn'; else if(avg!=null&&avg>thr*0.6) cls='mid'; }
    // hop1's ICMP baseline is noisy; a latency-only spike is capped at amber (not red)
    const noisy=(tier==='frontier_hop1');
    if(noisy && cls==='warn' && !(loss>0)) cls='mid';
    const t=document.createElement('div'); t.className='tile';
    t.innerHTML=`<div class="name"><span class="dot" style="background:${color}"></span>${LABELS[tier]}</div>`+
      `<div class="big ${cls}">${fmt(avg,' ms')}</div>`+
      `<div class="sub">jitter ${fmt(jit,' ms')} · loss ${fmt(loss,'%')}${noisy?' · noisy baseline, trust regional':''}</div>`;
    tiles.appendChild(t);
    const s=document.createElement('span'); s.innerHTML=`<span class="dot" style="background:${color}"></span>${tier}`; leg.appendChild(s);
  }
  // shaded-band key (only worth showing once something has actually been shaded)
  if((j.outages||[]).some(o=>o.end>=Date.now()/1000-7*86400)){
    const sep=document.createElement('span'); sep.style.opacity='.5'; sep.textContent='│ shaded:'; leg.appendChild(sep);
    for(const [k,name] of [['gateway','gateway down'],['wan','internet down'],['nodata','no data']]){
      const s=document.createElement('span');
      s.innerHTML=`<span style="display:inline-block;width:14px;height:9px;border-left:2px solid ${OBAND[k].edge};background:${OBAND[k].fill}"></span>${name}`;
      leg.appendChild(s);
    }
  }
  // DNS tiles + WAN public-IP chip
  const dns=j.dns||{}, wan=j.wan||{};
  for(const [k,name,color] of [['dns_gw','DNS via gateway','#22d3ee'],['dns_cf','DNS via Cloudflare','#818cf8']]){
    const m=dns[k]; if(!m)continue;
    let cls='ok', val;
    if(m.ok===0){cls='warn'; val='FAIL';}
    else{ val=fmt(m.ms,' ms'); if(k==='dns_gw'&&m.ms>120)cls='warn'; else if(k==='dns_gw'&&m.ms>70)cls='mid'; }
    const t=document.createElement('div'); t.className='tile';
    t.innerHTML=`<div class="name"><span class="dot" style="background:${color}"></span>${name}</div>`+
      `<div class="big ${cls}">${val}</div><div class="sub">resolution time</div>`;
    tiles.appendChild(t);
  }
  if(wan.ip){
    const cls=wan.changed_24h?'warn':'ok';
    const sub=wan.changed_24h?'⚠ changed in last 24h — check port-forward':'stable';
    const t=document.createElement('div'); t.className='tile';
    t.innerHTML=`<div class="name">WAN public IP</div>`+
      `<div class="big ${cls}" style="font-size:18px">${wan.ip}</div><div class="sub">${sub}</div>`;
    tiles.appendChild(t);
  }
  const bb=j.bufferbloat||{};
  if(bb.grade){
    const cls=bb.grade==='A'?'ok':(bb.grade==='B'?'mid':'warn');
    const when=bb.epoch?new Date(bb.epoch*1000).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}):'';
    const t=document.createElement('div'); t.className='tile';
    t.innerHTML=`<div class="name"><span class="dot" style="background:#f472b6"></span>Bufferbloat (under load)</div>`+
      `<div class="big ${cls}">${bb.grade} · ${fmt(bb.loaded,' ms')}</div>`+
      `<div class="sub">idle ${fmt(bb.idle,' ms')} → loaded · RPM ${bb.rpm?Math.round(bb.rpm):'—'} · ${when}</div>`;
    tiles.appendChild(t);
  }
  document.getElementById('foot').textContent='Updated '+new Date().toLocaleTimeString()+' · source: data/wan_path.db';
}
// Pick a round time step (1min…1day) giving ~one label per 110px, aligned to local
// clock boundaries so ticks land on :00 / midnight instead of arbitrary offsets.
const STEPS=[60,120,300,600,900,1800,3600,7200,10800,21600,43200,86400,172800];
function xticks(tmin,tmax,W){
  const span=Math.max(1,tmax-tmin), want=Math.max(3,Math.min(9,Math.floor((W-60)/110)));
  let st=STEPS[STEPS.length-1];
  for(const s of STEPS){ if(span/s<=want){st=s;break} }
  const off=-new Date().getTimezoneOffset()*60;          // local-midnight alignment
  const out=[];
  for(let t=Math.ceil((tmin+off)/st)*st-off; t<=tmax; t+=st) out.push({t,st});
  return out;
}
function tickLabel(t,st,prev){
  const d=new Date(t*1000);
  const time=st>=86400?'':(st>=3600
    ?d.toLocaleTimeString([],{hour:'numeric',hour12:true}).replace(' ','')
    :d.toLocaleTimeString([],{hour:'numeric',minute:'2-digit'}));
  // stamp the date on the first tick and whenever the day rolls over
  const newDay=!prev||new Date(prev*1000).toDateString()!==d.toDateString();
  const day=newDay?d.toLocaleDateString([],{weekday:'short',month:'numeric',day:'numeric'}):'';
  return day&&time?[day,time]:[day||time];
}
function chart(id,data,idx,isLoss){
  const cv=document.getElementById(id); const dpr=window.devicePixelRatio||1;
  const W=cv.clientWidth,H=cv.clientHeight; cv.width=W*dpr; cv.height=H*dpr;
  const g=cv.getContext('2d'); g.scale(dpr,dpr); g.clearRect(0,0,W,H);
  const padL=44,padR=10,padT=10,padB=34;
  let tmin=Infinity,tmax=-Infinity,vmax=isLoss?5:1;
  for(const [tier] of TIERS)for(const r of (data[tier]||[])){ if(r[0]<tmin)tmin=r[0]; if(r[0]>tmax)tmax=r[0]; const v=r[idx]; if(v!=null&&v>vmax)vmax=v; }
  if(tmin===Infinity){g.fillStyle='#8aa0bd';g.fillText('no data in window',padL,H/2);return;}
  vmax*=1.15;
  const X=t=>padL+(t-tmin)/(tmax-tmin||1)*(W-padL-padR);
  const Y=v=>padT+(1-v/vmax)*(H-padT-padB);
  // outage bands first, so the lines draw on top of them
  const bands=[];
  for(const o of (OUTAGES||[])){
    if(o.end<tmin||o.start>tmax)continue;
    const x1=X(Math.max(o.start,tmin)),x2=X(Math.min(o.end,tmax));
    const w=Math.max(3,x2-x1);          // a 3-min outage on a 7d axis is sub-pixel
    const col=OBAND[o.kind]||OBAND.nodata;
    g.fillStyle=col.fill; g.fillRect(x1,padT,w,H-padT-padB);
    g.fillStyle=col.edge; g.fillRect(x1,padT,Math.min(2,w),H-padT-padB);   // hard left edge
    g.fillRect(x1,padT,w,3);                                               // cap along the top
    bands.push({x:x1,w,o,col});
  }
  // grid + y labels
  g.strokeStyle='#22304a';g.fillStyle='#8aa0bd';g.font='11px sans-serif';g.lineWidth=1;
  for(let i=0;i<=4;i++){const v=vmax*i/4;const y=Y(v);g.beginPath();g.moveTo(padL,y);g.lineTo(W-padR,y);g.stroke();g.fillText((Math.round(v*10)/10)+'',4,y+3);}
  // x gridlines + labels at round clock boundaries
  const tk=xticks(tmin,tmax,W); let prev=null;
  g.textAlign='center';
  for(const {t,st} of tk){
    const x=X(t);
    const day=!prev||new Date(prev*1000).toDateString()!==new Date(t*1000).toDateString();
    g.strokeStyle=day?'#33456b':'#22304a';
    g.beginPath();g.moveTo(x,padT);g.lineTo(x,H-padB);g.stroke();
    const lines=tickLabel(t,st,prev);
    g.fillStyle=day?'#b9c8dd':'#8aa0bd';
    lines.forEach((s,i)=>g.fillText(s,x,H-padB+13+i*11));
    prev=t;
  }
  g.textAlign='left';
  for(const [tier,color] of TIERS){
    const rows=data[tier]||[]; g.strokeStyle=color;g.lineWidth=1.6;g.beginPath();let pen=false;
    for(const r of rows){const v=r[idx]; if(v==null){pen=false;continue;} const x=X(r[0]),y=Y(v); if(!pen){g.moveTo(x,y);pen=true;}else g.lineTo(x,y);}
    g.stroke();
  }
  // band captions last, so they sit above the traces
  g.font='10px sans-serif';
  for(const b of bands){
    const txt=b.o.cause||OKIND[b.o.kind][0];
    const tw=g.measureText(txt).width+8;
    // label to the right of the band, or left if it would run off the plot
    let lx=b.x+b.w+4;
    if(lx+tw>W-padR) lx=Math.max(padL+2,b.x-tw-4);
    g.fillStyle='rgba(11,18,32,.82)'; g.fillRect(lx-3,padT+1,tw,14);
    g.fillStyle=b.col.edge; g.fillText(txt,lx,padT+11);
  }
}
document.querySelectorAll('.seg').forEach(seg=>{
  seg.addEventListener('click',async e=>{
    const b=e.target.closest('button'); if(!b)return;
    seg.querySelectorAll('button').forEach(x=>x.classList.remove('on')); b.classList.add('on');
    const id=seg.dataset.chart; chartHours[id]=+b.dataset.h;
    const c=CH.find(c=>c.id===id); const j=await getData(chartHours[id],true); chart(id,j.data,c.idx,c.loss);
  });
});
document.getElementById('refresh').onclick=refreshAll;
function loop(){refreshAll();clearInterval(timer);timer=setInterval(refreshAll,20000);}
loop();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/data":
            q = parse_qs(u.query)
            hours = float(q.get("hours", ["3"])[0])
            hours = max(0.05, min(hours, 168))
            data = load(hours)
            state, detail = attribution(data)
            count = sum(len(v) for v in data.values())
            body = json.dumps({
                "data": data,
                "attribution": {"state": state, "detail": detail},
                "incidents": recent_incidents(24),
                "outages": outages(168),
                "dns": dns_latest(),
                "wan": wan_info(),
                "bufferbloat": bufferbloat_latest(),
                "count": count,
            }).encode()
            self._send(200, body, "application/json")
        elif u.path == "/api/factorygame":
            self._send(200, json.dumps(analyze_factorygame_log()).encode(), "application/json")
        elif u.path in ("/", "/index.html"):
            html = (PAGE
                    .replace("__TIERS__", json.dumps([[t[0], t[1], t[2]] for t in TIERS]))
                    .replace("__LABELS__", json.dumps(TIER_LABEL)))
            self._send(200, html.encode(), "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"WAN dashboard on http://0.0.0.0:{PORT}  (db={DB})", flush=True)
    srv.serve_forever()
