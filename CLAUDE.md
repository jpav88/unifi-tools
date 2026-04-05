# CLAUDE.md — UniFi Project

## Session Startup

The SessionStart hook runs `unifi_snapshot.sh` which:
1. Captures a full baseline (health, iPad state, iPad session history 24h, all AP radio configs, switch port states) to `snapshots/session_baseline.json`
2. Outputs a 1-line summary with network status, iPad AP/signal, switch ports, and alerts for sub-1G links

Read `snapshots/session_baseline.json` for cached device configs instead of re-querying the API.

## Interacting with the UniFi Controller

Use the shell scripts in `scripts/` for all UniFi API calls. Never use raw curl.

| Script | Purpose | Args |
|--------|---------|------|
| `unifi_health.sh` | Network health summary | (none) |
| `unifi_clients.sh` | Client lookup | `[mac]` — omit for all wireless |
| `unifi_sessions.sh` | Session history | `<mac> [hours=24]` |
| `unifi_devices.sh` | AP radio stats + switch port status | `[mac]` — omit for all |
| `unifi_events.sh` | Recent events (v2 API) | `[hours=24] [limit=50] [class=all]` |
| `unifi_write.sh` | Write operations | `<cmd> <mac> [args]` |
| `unifi_ap_stats.sh` | Time-series AP load stats | `[5min\|hourly\|daily] [hours] [mac]` |
| `unifi_spectrum.sh` | RF spectrum scan viewer | `<mac> [ng\|na\|6e\|all] [width=20]` |
| `unifi_snapshot.sh` | Session baseline snapshot | (none) — writes to `snapshots/session_baseline.json` |
| `unifi_syslog.py` | Syslog receiver (launchd) | `--install` / `--uninstall` / `--port N` |

All scripts handle auth (login/CSRF/logout) automatically via `unifi_auth.sh`.

## Skills (slash commands)

| Command | Purpose |
|---------|---------|
| `/unifi-status` | Quick network health table |
| `/unifi-debug <mac>` | Full connectivity diagnosis (runs in subagent) |
| `/unifi-client-history <mac> [hours]` | Session timeline analysis (runs in subagent) |
| `/unifi-ap-health` | All AP radio stats and utilization |
| `/unifi-find-ipad` | Locate iPad across both known MACs |

Skills use `!`command`` preprocessing — scripts run before the prompt reaches Claude, injecting only filtered data.

## Config

- Credentials: `~/.unifi_credentials` (UNIFI_HOST, UNIFI_USER, UNIFI_PASS)
- Device MACs and AP mappings: `local/devices.sh` (sourced by scripts and skills)
- Hooks: `.claude/settings.json` (see `hooks.example.json` for template)
- If auto-memory exists, consult `memory/MEMORY.md` for network topology and known devices
