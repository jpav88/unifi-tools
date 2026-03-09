# UniFi Network Tools

Shell scripts and Claude Code skills for managing a UniFi home network via the local API.

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

## Scripts

All in `scripts/`, all handle auth automatically via `unifi_auth.sh`.

| Script | Purpose | Args |
|--------|---------|------|
| `unifi_health.sh` | Network health summary | (none) |
| `unifi_clients.sh` | Client lookup | `[mac]` — omit for all wireless |
| `unifi_sessions.sh` | Session history | `<mac> [hours=24]` |
| `unifi_devices.sh` | AP/device radio stats | `[mac]` — omit for all |
| `unifi_events.sh` | Recent events | `[hours=24] [limit=50]` |
| `unifi_write.sh` | Write operations | `<cmd> <mac> [args]` |
| `unifi_snapshot.sh` | Full baseline snapshot | (none) — writes to `snapshots/session_baseline.json` |
| `unifi_syslog.py` | Syslog receiver (launchd) | `--install` / `--uninstall` / `--port N` |

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

## UDR Certificate (iOS/macOS)

To fix Safari "Connection Not Private" warnings for your controller:

1. `ssh admin@<controller-ip>` and `cat /data/unifi-core/unifi-core.crt`
2. Save output as `unifi-core.crt`
3. **iOS:** AirDrop/email the file > Install Profile > Settings > General > About > Certificate Trust Settings > Enable Full Trust
4. **macOS:** Double-click `.crt` > Keychain Access > Trust > Always Trust

Alternative: UniFi OS 4.1+ supports custom cert upload via Settings > System > Advanced > Custom Certificate.
