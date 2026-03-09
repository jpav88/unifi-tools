#!/bin/bash
# Interactive setup for UniFi Network Tools
# Walks through credentials, connection test, AP discovery, and config
# Compatible with macOS bash 3.2+
set -euo pipefail

# --- Helpers ---
info()  { echo "ℹ️  $*"; }
ok()    { echo "✅ $*"; }
warn()  { echo "⚠️  $*"; }
fail()  { echo "❌ $*" >&2; }
ask()   { printf "❓ %s " "$*"; }

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRED_FILE="$HOME/.unifi_credentials"
LOCAL_DIR="${PROJECT_DIR}/local"
DEVICES_FILE="${LOCAL_DIR}/devices.sh"

# --- Phase 1: Prerequisites ---
echo ""
echo "=== UniFi Network Tools Setup ==="
echo ""
info "Checking prerequisites..."

missing=()
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required tools: ${missing[*]}"
    echo "    Install with: brew install ${missing[*]}"
    exit 1
fi
ok "curl and jq found"

if command -v shellcheck &>/dev/null; then
    ok "shellcheck found (optional, used by hooks)"
else
    warn "shellcheck not found (optional — install with: brew install shellcheck)"
fi

# --- Phase 2: Credentials ---
echo ""
info "Setting up UniFi controller credentials..."

if [[ -f "$CRED_FILE" ]]; then
    warn "Credentials file already exists at $CRED_FILE"
    ask "Overwrite? (y/N):"
    read -r overwrite
    if [[ "${overwrite:-n}" != "y" && "${overwrite:-n}" != "Y" ]]; then
        info "Keeping existing credentials"
        # shellcheck source=/dev/null
        source "$CRED_FILE"
        skip_creds=true
    fi
fi

if [[ "${skip_creds:-false}" != "true" ]]; then
    ask "Controller IP/hostname [192.168.1.1]:"
    read -r input_host
    UNIFI_HOST="${input_host:-192.168.1.1}"

    ask "Username [admin]:"
    read -r input_user
    UNIFI_USER="${input_user:-admin}"

    ask "Password:"
    read -rs input_pass
    echo ""

    if [[ -z "$input_pass" ]]; then
        fail "Password cannot be empty"
        exit 1
    fi
    UNIFI_PASS="$input_pass"
fi

# --- Phase 3: Connection Test ---
echo ""
info "Testing connection to ${UNIFI_HOST}..."

COOKIE_FILE="/tmp/unifi_install_cookies_$$.txt"
cleanup() { rm -f "$COOKIE_FILE"; }
trap cleanup EXIT

http_code=$(curl -sk -w '%{http_code}' -X POST "https://${UNIFI_HOST}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${UNIFI_USER}\",\"password\":\"${UNIFI_PASS}\"}" \
    -c "$COOKIE_FILE" \
    -o /dev/null 2>/dev/null) || http_code="000"

if [[ "$http_code" == "000" ]]; then
    fail "Cannot reach controller at ${UNIFI_HOST}"
    echo "    Check the IP/hostname and make sure you're on the same network."
    exit 1
elif [[ "$http_code" != "200" ]]; then
    fail "Login failed (HTTP ${http_code}) — check username/password"
    exit 1
fi
ok "Connected and authenticated"

# Extract CSRF for API calls during setup
token=$(grep -i 'TOKEN' "$COOKIE_FILE" 2>/dev/null | awk '{print $NF}')
csrf=""
if [[ -n "$token" ]]; then
    payload=$(echo "$token" | cut -d. -f2)
    pad=$(( 4 - ${#payload} % 4 ))
    if [[ $pad -lt 4 ]]; then
        for ((i=0; i<pad; i++)); do payload="${payload}="; done
    fi
    csrf=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.csrfToken // empty' 2>/dev/null)
fi

# --- Phase 4: Write Credentials ---
if [[ "${skip_creds:-false}" != "true" ]]; then
    cat > "$CRED_FILE" << EOF
UNIFI_HOST=${UNIFI_HOST}
UNIFI_USER=${UNIFI_USER}
UNIFI_PASS=${UNIFI_PASS}
EOF
    chmod 600 "$CRED_FILE"
    ok "Credentials saved to $CRED_FILE (mode 600)"
fi

# --- Phase 5: Discover APs ---
echo ""
info "Discovering access points..."

api_get() {
    curl -sk -b "$COOKIE_FILE" -H "X-Csrf-Token: ${csrf}" \
        "https://${UNIFI_HOST}/proxy/network/api/s/default/$1" 2>/dev/null
}

DEVICES=$(api_get "stat/device")
AP_COUNT=$(echo "$DEVICES" | jq '[.data[] | select(.type == "uap" or .type == "udm")] | length' 2>/dev/null)

if [[ "${AP_COUNT:-0}" -eq 0 ]]; then
    warn "No APs found via API. You can manually edit local/devices.sh later."
else
    ok "Found ${AP_COUNT} access point(s):"
    echo ""

    # Display discovered APs
    echo "$DEVICES" | jq -r '.data[] | select(.type == "uap" or .type == "udm") |
        "  \(.mac)  \(.name // "unnamed")  (\(.model // "unknown"))"' 2>/dev/null

    echo ""
    info "You can assign locations to each AP (e.g., 'Living room', 'Garage')"
    info "Press Enter to skip any AP."
    echo ""

    # Build AP_MAP entries
    ap_entries=()
    while IFS=$'\t' read -r mac name _model; do
        ask "${name:-unnamed} (${mac}) location:"
        read -r location
        location="${location:-Unknown}"
        ap_entries+=("    \"${mac}|${name:-unnamed}|${location}\"")
    done < <(echo "$DEVICES" | jq -r '.data[] | select(.type == "uap" or .type == "udm") |
        [.mac, (.name // "unnamed"), (.model // "unknown")] | @tsv' 2>/dev/null)
fi

# --- Phase 6: iPad MACs (Optional) ---
echo ""
ask "Do you have an iPad to track? (y/N):"
read -r track_ipad

ipad_ft="xx:xx:xx:xx:xx:xx"
ipad_ft2="xx:xx:xx:xx:xx:xx"

if [[ "${track_ipad:-n}" == "y" || "${track_ipad:-n}" == "Y" ]]; then
    info "Find your iPad's Wi-Fi MAC in Settings > Wi-Fi > (i) next to your network"
    info "If using Private Address, set it to 'Fixed' first."
    echo ""
    ask "iPad MAC for primary SSID (or Enter to skip):"
    read -r input_mac
    if [[ -n "$input_mac" ]]; then
        ipad_ft=$(echo "$input_mac" | tr '[:upper:]' '[:lower:]')
    fi
    ask "iPad MAC for secondary SSID (or Enter to skip):"
    read -r input_mac2
    if [[ -n "$input_mac2" ]]; then
        ipad_ft2=$(echo "$input_mac2" | tr '[:upper:]' '[:lower:]')
    fi
fi

# --- Phase 7: Write local/devices.sh ---
echo ""
mkdir -p "$LOCAL_DIR"

# Build AP_MAP string
ap_map_str=""
if [[ ${#ap_entries[@]} -gt 0 ]]; then
    ap_map_str=$(printf '%s\n' "${ap_entries[@]}")
else
    ap_map_str='    "xx:xx:xx:xx:xx:xx|AP-Name-1|Location"'
fi

cat > "$DEVICES_FILE" << EOF
#!/bin/bash
# Local device config — generated by install.sh
# Edit this file to update device MACs or AP mappings

# iPad MACs (Fixed private address per SSID)
IPAD_FISH_TANK="${ipad_ft}"
IPAD_FISH_TANK2="${ipad_ft2}"

# AP MAC → friendly name mapping
# Format: MAC|Name|Location
AP_MAP=(
${ap_map_str}
)

# Format AP_MAP for display
ap_list() {
    for entry in "\${AP_MAP[@]}"; do
        IFS='|' read -r mac name loc <<< "\$entry"
        echo "- \${name} (\\\`\${mac}\\\`): \${loc}"
    done
}
EOF
ok "Device config saved to local/devices.sh"

# --- Phase 8: Claude Code Hooks ---
echo ""
if [[ -f "${PROJECT_DIR}/hooks.example.json" ]]; then
    CLAUDE_DIR="${PROJECT_DIR}/.claude"
    SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

    if [[ -f "$SETTINGS_FILE" ]]; then
        warn "Claude Code settings already exist at .claude/settings.json"
        ask "Overwrite with template? (y/N):"
        read -r overwrite_hooks
    else
        overwrite_hooks="y"
    fi

    if [[ "${overwrite_hooks:-n}" == "y" || "${overwrite_hooks:-n}" == "Y" ]]; then
        mkdir -p "$CLAUDE_DIR"
        # Replace /path/to/unifi with actual project path
        sed "s|/path/to/unifi|${PROJECT_DIR}|g" "${PROJECT_DIR}/hooks.example.json" > "$SETTINGS_FILE"
        ok "Claude Code hooks configured at .claude/settings.json"
    else
        info "Keeping existing hooks configuration"
    fi
else
    warn "hooks.example.json not found — skipping Claude Code hook setup"
fi

# --- Phase 9: Logout & Validation ---
echo ""
info "Running validation health check..."

# Logout from setup session
curl -sk -X POST "https://${UNIFI_HOST}/api/auth/logout" \
    -b "$COOKIE_FILE" -o /dev/null 2>/dev/null
rm -f "$COOKIE_FILE"

# Run the actual health script as validation
if bash "${PROJECT_DIR}/scripts/unifi_health.sh" >/dev/null 2>&1; then
    ok "Health check passed"
else
    warn "Health check failed — scripts may need troubleshooting"
    echo "    Try running: ./scripts/unifi_health.sh"
fi

# --- Done ---
echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Credentials:  $CRED_FILE"
echo "  Device config: local/devices.sh"
echo "  Hooks:         .claude/settings.json"
echo ""
echo "  Quick test:    ./scripts/unifi_health.sh"
echo "  Full snapshot: ./scripts/unifi_snapshot.sh"
echo ""
echo "  For Claude Code: run 'claude' in this directory"
echo ""
