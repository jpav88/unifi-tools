# UniFi Network Tools

Shell scripts and Claude Code skills for managing a UniFi home network via the local API. No cloud dependencies, no Docker, no extra databases — just `curl`, `jq`, and your controller.

## Quick Start

```bash
# 1. Clone and enter the repo
git clone https://github.com/jpav88/unifi-tools.git
cd unifi-tools

# 2. Run the interactive setup
./install.sh
```

The installer walks you through credentials, tests the connection, auto-discovers your APs, and configures everything. Or set up manually:

<details>
<summary>Manual setup</summary>

```bash
# Create credentials file
cat > ~/.unifi_credentials << 'EOF'
UNIFI_HOST=192.168.1.1        # Your controller IP
UNIFI_USER=admin               # Your controller username
UNIFI_PASS=yourpassword        # Your controller password
EOF
chmod 600 ~/.unifi_credentials

# Set up local device config
cp local/devices.sh.example local/devices.sh
# Edit local/devices.sh with your device MACs and AP names

# Test it
./scripts/unifi_health.sh
```
</details>

Requires `jq` and `curl` (both pre-installed on macOS).

## Name Your Devices First

The single most important thing you can do before using these tools: **name your devices in the UniFi controller** (or use the `rename` command below). Every script resolves MAC addresses to device names automatically, so instead of seeing:

```json
{"ap_mac": "8c:ed:e1:e4:15:95", "signal": -52}
```

You'll see:

```json
{"ap": "U7 Pro Max", "signal": -52}
```

This applies to all client, session, and AP stats output. Name your APs, name your clients — the scripts do the rest.

## Scripts

All in `scripts/`, all handle auth automatically via `unifi_auth.sh`. Supports both the v1 and v2 UniFi APIs.

### Read Operations

| Script | Purpose | Usage |
|--------|---------|-------|
| `unifi_health.sh` | Network health overview | `./scripts/unifi_health.sh` |
| `unifi_clients.sh` | Client lookup with signal/AP info | `./scripts/unifi_clients.sh [mac]` |
| `unifi_sessions.sh` | Wi-Fi session history for a client | `./scripts/unifi_sessions.sh <mac> [hours=24]` |
| `unifi_devices.sh` | AP radio config + switch port status | `./scripts/unifi_devices.sh [mac]` |
| `unifi_events.sh` | Recent events (v2 system-log API) | `./scripts/unifi_events.sh [hours=24] [limit=50] [class]` |
| `unifi_ap_stats.sh` | Historical AP load and traffic | `./scripts/unifi_ap_stats.sh [5min\|hourly\|daily] [hours] [mac]` |
| `unifi_spectrum.sh` | RF spectrum scan data | `./scripts/unifi_spectrum.sh <mac> [ng\|na\|6e\|all]` |
| `unifi_snapshot.sh` | Full baseline snapshot | `./scripts/unifi_snapshot.sh` |

### Network Analysis

| Script | Purpose | Usage |
|--------|---------|-------|
| `unifi_wifi_check.sh` | Full Wi-Fi health audit | `./scripts/unifi_wifi_check.sh` |
| `unifi_bandwidth.sh` | Per-client bandwidth usage | `./scripts/unifi_bandwidth.sh [hours=24] [top_n=20]` |
| `unifi_new_devices.sh` | Detect unknown devices | `./scripts/unifi_new_devices.sh [--learn\|--all]` |
| `unifi_channel_plan.sh` | Channel plan validation | `./scripts/unifi_channel_plan.sh [na\|ng\|6e\|all]` |

### Write Operations

```bash
./scripts/unifi_write.sh <command> <mac> [args]
```

| Command | What it does | Example |
|---------|-------------|---------|
| `reboot` | Reboot a device | `./scripts/unifi_write.sh reboot aa:bb:cc:dd:ee:ff` |
| `kick` | Disconnect a client | `./scripts/unifi_write.sh kick aa:bb:cc:dd:ee:ff` |
| `block` / `unblock` | Block/unblock a client | `./scripts/unifi_write.sh block aa:bb:cc:dd:ee:ff` |
| `rename` | Set a client's display name | `./scripts/unifi_write.sh rename aa:bb:cc:dd:ee:ff "Living Room TV"` |
| `poe_cycle` | Power-cycle a PoE switch port | `./scripts/unifi_write.sh poe_cycle <switch_mac> 2` |
| `min_rssi` | Set min signal threshold on an AP | `./scripts/unifi_write.sh min_rssi <ap_mac> na -75` |
| `provision` | Force re-provision a device | `./scripts/unifi_write.sh provision aa:bb:cc:dd:ee:ff` |

Radio bands: `ng` = 2.4GHz, `na` = 5GHz, `6e` = 6GHz

### Examples

```bash
# See all wireless clients with AP names and signal strength
./scripts/unifi_clients.sh

# Check a specific client's connection
./scripts/unifi_clients.sh aa:bb:cc:dd:ee:ff

# What happened on the network in the last 7 days?
./scripts/unifi_events.sh 168

# Which APs are busiest? (last 12 hours, 5-min samples)
./scripts/unifi_ap_stats.sh

# How loaded was a specific AP over the last 2 days?
./scripts/unifi_ap_stats.sh hourly 48 aa:bb:cc:dd:ee:ff

# RF environment from your outdoor AP's perspective
./scripts/unifi_spectrum.sh aa:bb:cc:dd:ee:ff na

# Rename a device so all future output shows a friendly name
./scripts/unifi_write.sh rename aa:bb:cc:dd:ee:ff "Kitchen Echo"

# Remotely reboot an AP by power-cycling its switch port
./scripts/unifi_write.sh poe_cycle <switch_mac> 4

# Full Wi-Fi health audit — checks signal, retries, co-channel, WLAN config
./scripts/unifi_wifi_check.sh

# Who's using all the bandwidth? (last 24h, top 20 clients)
./scripts/unifi_bandwidth.sh

# Who's hogging bandwidth RIGHT NOW? (last hour)
./scripts/unifi_bandwidth.sh 1

# Any unknown devices on the network?
./scripts/unifi_new_devices.sh --learn    # first run: seed known devices
./scripts/unifi_new_devices.sh            # subsequent: flag unknowns

# Validate your channel plan against RF spectrum data
./scripts/unifi_channel_plan.sh
```

## Remote Syslog Receiver

UniFi devices can forward syslog messages to an external server. On firmware v9.x+, this must be configured through the UniFi UI (the API silently ignores syslog settings). `unifi_syslog.py` is a lightweight syslog receiver that runs on any Mac on your network.

### How it works

1. **UniFi controller** sends UDP syslog to your Mac's IP on a configurable port
2. **`unifi_syslog.py`** listens on that port, filters out noise, and writes to rotating log files
3. Runs as a macOS LaunchAgent — starts automatically on login, restarts on crash

### Setup

**On your Mac (the syslog receiver):**

```bash
# Install and start the receiver (runs on port 5514 by default)
./scripts/unifi_syslog.py --install

# Or use a custom port
./scripts/unifi_syslog.py --install --port 5514

# Test it manually first (shows messages in terminal)
./scripts/unifi_syslog.py --port 5514

# Remove when done
./scripts/unifi_syslog.py --uninstall
```

**In the UniFi controller UI:**

1. Go to **Settings > Control Plane > Integrations > Activity Logging**
2. Enable **SIEM Server**, enter your Mac's IP and port (e.g., `192.168.1.100:5514`)
3. For firewall/IPS logs: **Settings > CyberSecure > Traffic Logging > Activity Logging** — same server config

> **Why not use the API?** On Network Application v9.x+, the old `super_mgmt` syslog API fields are silently dropped — PUT returns success but nothing changes. The UI's SIEM integration model is the only way to configure it now.

### Logs and filtering

Logs are written to `~/Library/Logs/unifi-syslog/unifi.log` with automatic rotation (1 GB per file, 10 files kept). The receiver filters out known noisy messages that don't provide actionable information:

- `wevent` service crash-loop spam (start/stop/restart cycles)
- `ubnt-protocol` initialization noise
- `L2UF` subsystem messages
- `UBNT_DEVICE` status broadcasts

To customize filters, edit the `FILTER_SUBSTRINGS` list in `unifi_syslog.py`.

## Claude Code Integration

This repo is designed to be used with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). The skills and hooks turn Claude into a network management assistant that can query, diagnose, and configure your UniFi network conversationally.

### Skills (slash commands)

Skills live in `.claude/skills/` and use `!` backtick preprocessing to pull live API data before the prompt reaches Claude — zero context cost for data gathering.

| Command | Purpose |
|---------|---------|
| `/unifi-status` | Quick network health table |
| `/unifi-debug <mac>` | Full connectivity diagnosis (runs in subagent) |
| `/unifi-client-history <mac> [hours]` | Session timeline analysis (runs in subagent) |
| `/unifi-ap-health` | All AP radio stats and utilization |
| `/unifi-find-ipad` | Locate iPad across known MACs |

### Hooks

Hooks automate the workflow so each Claude session starts with full network context. Copy `hooks.example.json` into `.claude/settings.json` in the project root and update the paths.

| Hook | Trigger | What it does |
|------|---------|-------------|
| **SessionStart** | Every new conversation | Runs `unifi_snapshot.sh` — captures network baseline (health, client state, AP configs) so Claude has context without extra API calls |
| **PreCompact** | Before context compression | Injects critical device info (MACs, AP names) into the compressed context so Claude doesn't lose track of your network during long sessions |
| **PostToolUse** | After any `Edit` or `Write` | Auto-runs `shellcheck` on `.sh` files to catch bugs immediately |

Setup: `install.sh` configures hooks automatically, or manually copy `hooks.example.json` to `.claude/settings.json` and replace `/path/to/unifi` with your project path.

## Local Config

All device-specific data lives in two files (both gitignored):

| File | Contains |
|------|----------|
| `~/.unifi_credentials` | Controller IP, username, password |
| `local/devices.sh` | Device MACs, AP name/location mappings |

Scripts, skills, and hooks all source these files at runtime. See `local/devices.sh.example` for the template.

## Documentation

- **[UniFi API Reference](docs/unifi-api-reference.md)** — Practical guide to the v1 and v2 UniFi APIs with curl examples, undocumented endpoints, and known gotchas. Everything you need to build your own scripts.
- **[Apple Wi-Fi Best Practices](docs/apple-wifi-best-practices.md)** — Recommended UniFi settings for iPhones, iPads, and Macs. Covers roaming, 802.11k/v/r, private MAC addresses, min_rssi tuning, and common issues.

## UDR Certificate (iOS/macOS)

To fix Safari "Connection Not Private" warnings for your controller:

1. `ssh admin@<controller-ip>` and `cat /data/unifi-core/unifi-core.crt`
2. Save output as `unifi-core.crt`
3. **iOS:** AirDrop/email the file > Install Profile > Settings > General > About > Certificate Trust Settings > Enable Full Trust
4. **macOS:** Double-click `.crt` > Keychain Access > Trust > Always Trust

Alternative: UniFi OS 4.1+ supports custom cert upload via Settings > System > Advanced > Custom Certificate.
