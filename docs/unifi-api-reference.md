# UniFi Network API Reference for Home Users

A practical guide to the UniFi Network Application API for home and small network administrators. Covers both the original v1 API and the newer v2 API, with shell/curl examples, documented gotchas, and real-world usage patterns.

**Tested on:** UniFi Network Application 9.x/10.x running on UDR, UDM, UDM-Pro, UDM-SE. Access points: U7 Pro Max, U7 Pro Outdoor, U6+, NanoHD, FlexHD. Switches: USW Flex, USW Flex 2.5G.

**Acknowledgment:** Endpoint coverage informed by the [Art-of-WiFi/UniFi-API-client](https://github.com/Art-of-WiFi/UniFi-API-client) project, the most comprehensive community-maintained API reference available. Their PHP client documents endpoints across UniFi Network Application versions 5.x through 8.x. This guide distills that knowledge into a curl/shell-friendly format focused on what home users actually need.

> **Note:** Ubiquiti does not publish official API documentation. Everything here is community-discovered through browser network inspection, firmware analysis, and testing. Endpoints may change between firmware versions without notice.

---

## Table of Contents

- [Authentication](#authentication)
- [API Versions (v1 vs v2)](#api-versions-v1-vs-v2)
- [Clients](#clients)
- [Devices and APs](#devices-and-aps)
- [Radio Configuration](#radio-configuration)
- [WLAN Configuration](#wlan-configuration)
- [Events and Logs](#events-and-logs)
- [Statistics and History](#statistics-and-history)
- [Spectrum and RF Analysis](#spectrum-and-rf-analysis)
- [Site Settings](#site-settings)
- [Switch Operations](#switch-operations)
- [Firmware Management](#firmware-management)
- [Known Gotchas](#known-gotchas)
- [Building Scripts](#building-scripts)

---

## Authentication

The UniFi controller uses cookie-based auth with CSRF tokens. Every session follows this flow:

```bash
# 1. Login — returns a TOKEN cookie (JWT)
curl -sk -X POST "https://CONTROLLER_IP/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"yourpassword"}' \
  -c /tmp/unifi_cookies.txt \
  -D /tmp/unifi_headers.txt

# 2. Extract CSRF token from the JWT payload
TOKEN=$(grep -i 'TOKEN' /tmp/unifi_cookies.txt | awk '{print $NF}')
PAYLOAD=$(echo "$TOKEN" | cut -d. -f2)
# Pad base64 if needed
PAD=$(( 4 - ${#PAYLOAD} % 4 ))
[ $PAD -lt 4 ] && for ((i=0; i<PAD; i++)); do PAYLOAD="${PAYLOAD}="; done
CSRF=$(echo "$PAYLOAD" | base64 -d 2>/dev/null | jq -r '.csrfToken')

# 3. Use CSRF token on all subsequent requests
curl -sk -b /tmp/unifi_cookies.txt \
  -H "X-Csrf-Token: $CSRF" \
  "https://CONTROLLER_IP/proxy/network/api/s/default/stat/health"

# 4. Logout when done
curl -sk -X POST "https://CONTROLLER_IP/api/auth/logout" \
  -b /tmp/unifi_cookies.txt
```

**Important:**
- Login is at `/api/auth/login` — NOT under `/proxy/network/`
- Always use `-k` to skip certificate verification (self-signed cert)
- The CSRF token is embedded in the JWT `TOKEN` cookie, not in a response header
- Rapid successive login/logout cycles trigger HTTP 429 rate limiting — batch operations in a single session

---

## API Versions (v1 vs v2)

UniFi has two coexisting API generations. Most guides only cover v1, but v2 endpoints are often better.

| | v1 (Original) | v2 (Newer) |
|---|---|---|
| **Base path** | `/proxy/network/api/s/default/` | `/proxy/network/v2/api/site/default/` |
| **Auth** | Same cookies + CSRF | Same cookies + CSRF |
| **Response format** | `{"meta":{"rc":"ok"},"data":[...]}` | Varies — often `{"data":[...]}` directly |
| **Available since** | All versions | Network Application 8.x+ |

**When to use v2:**
- `system-log` — replaces the often-broken `stat/event` endpoint
- `clients/active` and `clients/history` — richer client data with optional traffic inclusion
- `static-dns` — DNS record management

**Stick with v1 for:** device configuration, radio settings, WLAN config, client write operations, stats/reports.

---

## Clients

### List Connected Clients (v1)

```bash
# All wireless clients
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/sta" | jq '[.data[] | select(.is_wired==false) | {
    name: (.name // .hostname // .mac),
    mac, ip, essid, ap_mac, channel,
    signal, rssi, satisfaction,
    tx_rate, rx_rate, tx_retries
  }]'

# Single client by MAC
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/sta/aa:bb:cc:dd:ee:ff"
```

### List Connected Clients (v2 — Recommended)

```bash
# Active clients with traffic data
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE_V2/clients/active?includeTrafficUsage=true&includeUnifiDevices=true"

# Historical/offline clients (last 24 hours)
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE_V2/clients/history?withinHours=24"
```

The v2 endpoints return pre-resolved device names and support filtering parameters, reducing the need for client-side joins.

### Single Client Detail

Two different endpoints exist for client lookup:

| Endpoint | What it returns |
|----------|----------------|
| `stat/sta/{mac}` | Live connection data (signal, rates, AP) — only if currently connected |
| `stat/user/{mac}` | Historical client record (name, notes, first seen, last seen) — works even if offline |

### Rename a Client

**Use `upd/user/` for partial updates** — the `rest/user/` endpoint requires the full client object and returns 403 on partial payloads.

```bash
# Step 1: Get the client's _id
CLIENT_ID=$(curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/alluser" | jq -r '.data[] | select(.mac == "aa:bb:cc:dd:ee:ff") | ._id')

# Step 2: Update the name (partial update — only sends what changed)
curl -sk -X PUT -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"name":"My Device"}' \
  "$BASE/upd/user/$CLIENT_ID"
```

This also works for setting client notes:
```bash
curl -sk -X PUT -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"note":"Living room TV","noted":true}' \
  "$BASE/upd/user/$CLIENT_ID"
```

### Client Actions

All use POST to `cmd/stamgr`:

```bash
# Disconnect (kick) a client — forces reconnect
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"kick-sta","mac":"aa:bb:cc:dd:ee:ff"}' \
  "$BASE/cmd/stamgr"

# Block a client
-d '{"cmd":"block-sta","mac":"aa:bb:cc:dd:ee:ff"}'

# Unblock
-d '{"cmd":"unblock-sta","mac":"aa:bb:cc:dd:ee:ff"}'

# Forget a client (remove from known devices — takes up to 5 minutes)
-d '{"cmd":"forget-sta","macs":["aa:bb:cc:dd:ee:ff"]}'
```

---

## Devices and APs

### List All Devices

```bash
# Full detail (APs, switches, gateways — all in one call)
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/device" | jq '[.data[] | {
    name, mac, model, type,
    state: (if .state == 1 then "online" elif .state == 0 then "offline"
            elif .state == 4 then "updating" elif .state == 5 then "provisioning" else .state end),
    version, uptime: (.uptime / 3600 | round)
  }]'

# Minimal list (faster, less data)
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/device-basic"
```

**Device types in the response:**
- `uap` — access points (includes UDM/UDR Wi-Fi radios)
- `usw` — switches
- `ugw` — gateways (standalone, not UDM)
- `udm` — UniFi Dream Machine family

### Device State Codes

| Code | Meaning |
|------|---------|
| 0 | Offline |
| 1 | Connected/Online |
| 2 | Pending adoption |
| 4 | Updating firmware |
| 5 | Provisioning |
| 6 | Unreachable |
| 7 | Adopting |
| 9 | Adoption error |
| 10 | Adoption failed |
| 11 | Isolated |

### Device Actions

```bash
# Reboot a device
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"restart","mac":"aa:bb:cc:dd:ee:ff"}' \
  "$BASE/cmd/devmgr"

# Force provision (re-push config to device)
-d '{"cmd":"force-provision","mac":"aa:bb:cc:dd:ee:ff"}'

# Flash LED to locate a device
-d '{"cmd":"set-locate","mac":"aa:bb:cc:dd:ee:ff"}'
# Stop flashing
-d '{"cmd":"unset-locate","mac":"aa:bb:cc:dd:ee:ff"}'

# Adopt a new device
-d '{"cmd":"adopt","macs":["aa:bb:cc:dd:ee:ff"]}'
```

---

## Radio Configuration

Radio settings are managed through the device's `radio_table` array. **This is a replace-all operation** — you must send the complete radio_table, not just the fields you want to change.

### Read Current Radio Config

```bash
# Get radio config for a specific AP
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/device" | jq '.data[] | select(.mac == "aa:bb:cc:dd:ee:ff") | {
    name,
    config: [.radio_table[] | {radio, channel, ht, tx_power_mode, min_rssi_enabled, min_rssi}],
    live: [.radio_table_stats[] | {radio, channel, tx_power, cu_total, num_sta, satisfaction}]
  }'
```

**Critical distinction:**
- `radio_table` — the **configured** settings (what you PUT back)
- `radio_table_stats` — the **actual runtime** values (read-only)
- `tx_power` in `radio_table` is often a placeholder — always check `radio_table_stats.tx_power` for the actual dBm output

### Change Radio Settings

```bash
# Step 1: Get the device _id and current radio_table
DEVICE=$(curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/device" | jq '.data[] | select(.mac == "aa:bb:cc:dd:ee:ff")')

DEVICE_ID=$(echo "$DEVICE" | jq -r '._id')

# Step 2: Modify the radio_table (example: change 5GHz channel to 36)
UPDATED_RADIOS=$(echo "$DEVICE" | jq '[.radio_table[] |
  if .radio == "na" then .channel = 36 else . end]')

# Step 3: PUT the updated radio_table
curl -sk -X PUT -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"radio_table\": $UPDATED_RADIOS}" \
  "$BASE/rest/device/$DEVICE_ID"
```

### Common Radio Changes

```bash
# Change channel (5GHz to channel 149, 80MHz width)
jq '[.radio_table[] | if .radio == "na" then .channel = 149 | .ht = 80 else . end]'

# Set tx_power mode (auto, low, medium, high, custom)
jq '[.radio_table[] | if .radio == "na" then .tx_power_mode = "medium" else . end]'

# Enable min_rssi (kick clients below threshold)
jq '[.radio_table[] | if .radio == "na" then .min_rssi_enabled = true | .min_rssi = -75 else . end]'

# Disable min_rssi
jq '[.radio_table[] | if .radio == "na" then .min_rssi_enabled = false else . end]'

# Set 6GHz to a fixed channel (stops auto-hopping)
jq '[.radio_table[] | if .radio == "6e" then .channel = 37 else . end]'
```

**Radio identifiers:**
| Identifier | Band |
|-----------|------|
| `ng` | 2.4 GHz |
| `na` | 5 GHz |
| `6e` | 6 GHz |

> **Gotcha:** "medium" tx_power varies wildly by model. A U6+ at "medium" outputs ~6 dBm while a UDM at "high" outputs ~26 dBm. Always verify actual power via `radio_table_stats.tx_power` after making changes.

> **Gotcha:** Newly adopted devices may need initial configuration through the UI before API radio_table changes take effect.

---

## WLAN Configuration

### Read WLAN Settings

```bash
# All SSIDs with their full config
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/rest/wlanconf" | jq '[.data[] | {
    name, _id, enabled, security,
    wpa_mode, pmf_mode,
    wlan_bands, fast_roaming,
    bss_transition, rrm_enabled: .rrm,
    uapsd_enabled, mcastenhance,
    group_rekey, minrate_na_enabled
  }]'
```

### Update WLAN Settings

```bash
WLAN_ID="your_wlan_id_here"

# Enable 802.11r (fast roaming)
curl -sk -X PUT -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"fast_roaming":true}' \
  "$BASE/rest/wlanconf/$WLAN_ID"

# Enable PMF (optional mode — allows both WPA2 and WPA3 clients)
-d '{"pmf_mode":1}'
# PMF modes: 0 = disabled, 1 = optional, 2 = required

# Enable BSS Transition (802.11v)
-d '{"bss_transition":true}'

# Set group rekey interval (Apple recommends 3600)
-d '{"group_rekey":3600}'

# Enable multicast enhancement
-d '{"mcastenhance":2}'
# Values: 0 = off, 2 = enabled
```

### Create a New WLAN

Note: creation uses `add/wlanconf` (POST), not `rest/wlanconf`:

```bash
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "MyNetwork",
    "x_passphrase": "yourpassword",
    "security": "wpapsk",
    "wpa_mode": "wpa2",
    "wpa_enc": "ccmp",
    "enabled": true,
    "wlan_bands": ["5g"],
    "ap_group_ids": ["default_ap_group_id"]
  }' \
  "$BASE/add/wlanconf"
```

The `ap_group_ids` field is required on Network Application 6.0+.

> **Gotcha:** Changing `wpa_mode` or `security` via the API silently fails on some firmware versions — the PUT returns `rc: ok` but the setting doesn't change. You must use the UI for WPA2-to-WPA3 transitions. This is not documented anywhere, including Art-of-WiFi.

---

## Events and Logs

### v2 System Log (Recommended)

The v1 `stat/event` endpoint returns empty on many current firmware versions. Use the v2 system log instead:

```bash
# Device events (channel changes, offline/online, adoption)
NOW_MS=$(date +%s)000
START_MS=$(( $(date +%s) - 86400 ))000  # 24 hours ago

curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"start\":$START_MS,\"end\":$NOW_MS,\"page\":0,\"size\":50}" \
  "$BASE_V2/system-log/device-alert"
```

**Available log classes:**

| Class | What it contains |
|-------|-----------------|
| `device-alert` | AP channel changes, device online/offline, adoption events, rogue AP detection |
| `client-alert` | Client connect/disconnect alerts (if configured) |
| `admin-activity` | Admin logins, config changes (noisy — every API call generates entries) |
| `update-alert` | Firmware update notifications |
| `threat-alert` | IPS/IDS threat detections |
| `next-ai-alert` | UniFi AI-generated alerts |
| `triggers` | Traffic rule and firewall rule triggers |

The v2 response includes rich structured data:

```json
{
  "key": "AP_CHANGED_CHANNELS",
  "message": "U7 Pro Max moved to channel 36 from 100.",
  "severity": "LOW",
  "timestamp": 1774810564680,
  "parameters": {
    "DEVICE": {"name": "U7 Pro Max", "id": "aa:bb:cc:dd:ee:ff", "model": "U7PROMAX"},
    "CHANNEL": {"id": "36", "radio_band": "na"},
    "PREVIOUS_CHANNEL": {"id": "100", "radio_band": "na"}
  }
}
```

Device names, MACs, and models are pre-resolved in `parameters` — no need to cross-reference against `stat/device`.

### v1 Events (Legacy Fallback)

```bash
# POST, not GET — this trips up many people
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"within":24,"_limit":50,"_sort":"-time"}' \
  "$BASE/stat/event"
```

### Alarms

```bash
# List active (unarchived) alarms
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"archived":false}' \
  "$BASE/list/alarm"

# Archive all alarms
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"archive-all-alarms"}' \
  "$BASE/cmd/evtmgr"
```

---

## Statistics and History

### Session History

```bash
# Client sessions for the last 24 hours
START=$(( $(date +%s) - 86400 ))
END=$(date +%s)

curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"all\",\"start\":$START,\"end\":$END,\"mac\":\"aa:bb:cc:dd:ee:ff\"}" \
  "$BASE/stat/session"

# Latest 5 sessions for a client (sorted by most recent)
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"mac":"aa:bb:cc:dd:ee:ff","type":"all","_limit":5,"_sort":"-assoc_time"}' \
  "$BASE/stat/session"
```

### Time-Series AP Statistics

Historical per-AP data without needing UnPoller, InfluxDB, or Grafana:

```bash
# 5-minute intervals for the last 12 hours (per AP)
START=$(( $(date +%s) - 43200 ))
END=$(date +%s)

curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"attrs\":[\"bytes\",\"num_sta\",\"time\"],\"start\":$(($START * 1000)),\"end\":$(($END * 1000))}" \
  "$BASE/stat/report/5minutes.ap"
```

**Available intervals and default windows:**

| Endpoint | Granularity | Default Window |
|----------|------------|----------------|
| `stat/report/5minutes.ap` | 5 min | 12 hours |
| `stat/report/hourly.ap` | 1 hour | 7 days |
| `stat/report/daily.ap` | 1 day | 7 days |
| `stat/report/monthly.ap` | 1 month | 52 weeks |

Replace `.ap` with `.site` (aggregate), `.user` (per client), or `.gw` (gateway) for different perspectives.

**Default attributes:** `bytes, wan-tx_bytes, wan-rx_bytes, wlan_bytes, num_sta, lan-num_sta, wlan-num_sta, time`

**Timestamps** are in milliseconds in the request body, and the response returns `time` in milliseconds — divide by 1000 for epoch seconds.

> **Note:** This gives you client counts and traffic volumes per AP over time — useful for spotting load imbalances and traffic patterns. It does not include per-client RSSI history; the controller only stores live RSSI snapshots.

### Speed Test Results

```bash
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d "{\"start\":$(( ($(date +%s) - 86400) * 1000 )),\"end\":$(( $(date +%s) * 1000 ))}" \
  "$BASE/stat/report/archive.speedtest"
```

### Network Health

```bash
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/health" | jq '[.data[] | {
    subsystem, status,
    num_user, num_sta: .num_sta,
    tx_bytes: .["tx_bytes-r"], rx_bytes: .["rx_bytes-r"]
  }]'
```

---

## Spectrum and RF Analysis

UniFi APs periodically run background RF spectrum scans. You can retrieve cached scan data without triggering a new scan:

```bash
# Get cached spectrum scan data for an AP
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/spectrum-scan/aa:bb:cc:dd:ee:ff"
```

The response contains per-radio spectrum data grouped by channel width:

```json
{
  "data": [{
    "scans": [
      {
        "radio": "na",
        "spectrum_table": [
          {
            "channel": 36,
            "center_freq": 5180,
            "width": 20,
            "interference": -84,
            "utilization": 6,
            "interference_type": [],
            "other_bss_count": 0
          }
        ],
        "spectrum_table_time": 1775348992
      }
    ],
    "spectrum_scanning": true
  }]
}
```

**Key fields:**
- `interference` — detected interference level in dBm (-96 = noise floor, higher = more interference)
- `utilization` — channel utilization percentage (0-100)
- `interference_type` — array of interference sources (empty = clean)
- `other_bss_count` — number of other networks detected on this channel
- `width` — channel width in MHz (20, 40, 80, 160, 320). Multiple entries per channel at different widths.

**Reading the data:**
- Filter by `width: 20` for primary channel assessment
- Channels with `interference` at -96 and `utilization` at 0 are completely clean
- `interference` above -80 indicates meaningful interference from neighbors
- Compare your assigned channels against the scan to validate your channel plan

Each radio (2.4 GHz, 5 GHz, 6 GHz) has its own scan entry with its own `spectrum_table`.

> **Important — Three tiers of scanning capability:**
>
> **Dedicated scanning radio** (U7 Pro Max, U7 Pro XGS, E7, E7 Campus): These APs have a separate 4th radio chip for continuous background spectrum analysis. Data should populate automatically. Requires Network Application 8.2.93+. However, this feature is still maturing — some users report empty data even on supported models. A UI-triggered scan may be needed to seed initial data.
>
> **Software-based scan** (U7 Pro, U7 Pro Outdoor, U6+, U6 Pro, U6 Enterprise, NanoHD, UDM, and most other APs): The `spectrum_table` array is **empty by default**. Data only appears after triggering a scan through the UI: **Devices > [AP] > Insights > RF Environment > Scan**. The AP **stops serving clients during the scan** — run it during off-hours. The API trigger endpoint (`cmd/devmgr` with `spectrum-scan`) returns 400 on some firmware; use the UI instead.
>
> **Unsupported:** Very old models (UAP-AC-Lite and earlier) may not support scanning at all.

---

## Site Settings

### Read All Settings

```bash
# Two equivalent endpoints
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" "$BASE/rest/setting"
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" "$BASE/get/setting"
```

Returns all setting sections: `mgmt`, `super_mgmt`, `guest_access`, `connectivity`, `country`, `locale`, `ntp`, `radio_ai`, etc.

### Common Settings Changes

Site settings use two endpoint patterns — both work:

```bash
# Toggle all AP LEDs
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"led_enabled":false}' \
  "$BASE/set/setting/mgmt"

# IPS/IDS settings
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"ips_enabled":true}' \
  "$BASE/set/setting/ips"
```

> **Gotcha — Remote Syslog:** On Network Application v9.x+, the old `super_mgmt` syslog settings are silently dropped when you PUT them — the API returns success but nothing changes. Remote syslog must be configured through the UI under Integrations (Activity Logging) and CyberSecure (Traffic Logging). Both use the "SIEM Server" model with IP + port over UDP.

---

## Switch Operations

### Read Switch Port Status

Switch data comes from the same `stat/device` endpoint as APs — filter by `type == "usw"`:

```bash
curl -sk -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  "$BASE/stat/device" | jq '[.data[] | select(.type == "usw") | {
    name, mac,
    ports: [.port_table[] | {
      port: .port_idx,
      up: .up,
      speed: .speed,
      poe: (if .port_poe then "active" else "off" end),
      rx_bytes, tx_bytes
    }]
  }]'
```

### PoE Power Cycle

Remotely reboot a PoE-powered device (like an AP) by cycling its switch port:

```bash
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"power-cycle","mac":"SWITCH_MAC","port_idx":2}' \
  "$BASE/cmd/devmgr"
```

The port must be actively providing PoE power for this to work. Useful for remotely rebooting APs in hard-to-reach locations (attics, ceilings, garages) without physical access to the switch.

> **Note:** UniFi switches do not send device-level syslog like APs do. Switch port events (link up/down, speed changes) are only visible through API polling of `stat/device` → `port_table`, or through the v2 `system-log/device-alert` endpoint.

---

## Firmware Management

```bash
# Check for available firmware
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"check-firmware-update"}' \
  "$BASE/cmd/productinfo"

# List available firmware
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"cmd":"list-available"}' \
  "$BASE/cmd/firmware"

# Upgrade a specific device to latest stable
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"mac":"aa:bb:cc:dd:ee:ff"}' \
  "$BASE/cmd/devmgr/upgrade"

# Upgrade all APs
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"type":"uap"}' \
  "$BASE/cmd/devmgr/upgrade-all"
# Types: uap (APs), usw (switches), ugw (gateways)
```

> **Note:** UniFi firmware versioning can be confusing. Legacy devices run 6.x firmware while current-generation devices run 5.x — the 5.x track is newer despite the lower major version number.

---

## Known Gotchas

A collection of undocumented behaviors that will save you hours of debugging:

### API Quirks

| Issue | Details |
|-------|---------|
| **`stat/event` returns empty** | Common on current firmware. Use v2 `system-log/{class}` instead. |
| **`rest/user` PUT returns 403** | Requires the full client object. Use `upd/user/{_id}` for partial updates (name, note). |
| **`wpa_mode` changes silently fail** | PUT returns `rc: ok` but WPA2→WPA3 doesn't apply. Must use the UI. |
| **`super_mgmt` syslog fields dropped** | v9.x+ silently ignores syslog settings via API. Configure through UI. |
| **`radio_table` PUT replaces ALL radios** | Fetch the complete current `radio_table`, modify the target radio, send back the full array. |
| **`stat/event` is POST, not GET** | Unlike most read endpoints, events require a POST with a JSON body. |
| **tx_power is misleading** | `radio_table.tx_power` is a placeholder. Check `radio_table_stats.tx_power` for actual dBm. |
| **WLAN create endpoint differs** | Create: POST to `add/wlanconf`. Update: PUT to `rest/wlanconf/{id}`. Delete: DELETE to `rest/wlanconf/{id}`. |
| **Timestamps vary** | v1 `stat/session` uses epoch seconds. v2 `system-log` uses epoch milliseconds. Always check. |
| **Rate limiting** | Rapid login/logout cycles trigger 429. Batch operations in one session. |

### Device Behavior

| Issue | Details |
|-------|---------|
| **6GHz auto channel hopping** | APs with 6E radio set to "auto" channel will change channels daily even with Radio AI disabled. Set a fixed channel if the event noise bothers you. |
| **tx_power "medium" varies by model** | A U6+ at "medium" = ~6 dBm. A UDM at "high" = ~26 dBm. Always verify actual output. |
| **Newly adopted APs ignore API radio changes** | Fresh adoptions may need initial config through the UI before `rest/device` PUT works for radio_table. |
| **`forget-sta` is slow** | Takes up to 5 minutes to complete. Don't assume it failed if the client still appears briefly. |
| **Spectrum scan data is empty by default** | Most APs return an empty `spectrum_table` until a scan is triggered via the UI. Only U7 Pro Max, U7 Pro XGS, E7, and E7 Campus have dedicated scanning radios for continuous data — and even those may need a UI-triggered scan to start. Manual scans take the AP offline briefly. |

---

## Building Scripts

### Auth Library Pattern

For scripts that make multiple API calls, use a shared auth library:

```bash
#!/bin/bash
# unifi_auth.sh — source this from other scripts

UNIFI_COOKIE="/tmp/unifi_cookies_$$.txt"  # PID-unique to avoid conflicts
UNIFI_CSRF=""
UNIFI_BASE="https://$UNIFI_HOST/proxy/network/api/s/default"
UNIFI_BASE_V2="https://$UNIFI_HOST/proxy/network/v2/api/site/default"

unifi_login() {
    local token payload csrf
    curl -sk -X POST "https://$UNIFI_HOST/api/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$UNIFI_USER\",\"password\":\"$UNIFI_PASS\"}" \
      -c "$UNIFI_COOKIE" -o /dev/null

    token=$(grep -i TOKEN "$UNIFI_COOKIE" | awk '{print $NF}')
    payload=$(echo "$token" | cut -d. -f2)
    # Base64 padding
    local pad=$(( 4 - ${#payload} % 4 ))
    [ $pad -lt 4 ] && for ((i=0; i<pad; i++)); do payload="${payload}="; done
    UNIFI_CSRF=$(echo "$payload" | base64 -d 2>/dev/null | jq -r '.csrfToken')
}

unifi_get()  {
    curl -sk -b "$UNIFI_COOKIE" -H "X-Csrf-Token: $UNIFI_CSRF" \
      "$UNIFI_BASE/$1"
}

unifi_post() {
    curl -sk -X POST -b "$UNIFI_COOKIE" -H "X-Csrf-Token: $UNIFI_CSRF" \
      -H "Content-Type: application/json" -d "$2" "$UNIFI_BASE/$1"
}

unifi_put() {
    curl -sk -X PUT -b "$UNIFI_COOKIE" -H "X-Csrf-Token: $UNIFI_CSRF" \
      -H "Content-Type: application/json" -d "$2" "$UNIFI_BASE/$1"
}

unifi_post_v2() {
    curl -sk -X POST -b "$UNIFI_COOKIE" -H "X-Csrf-Token: $UNIFI_CSRF" \
      -H "Content-Type: application/json" -d "$2" "$UNIFI_BASE_V2/$1"
}

unifi_logout() {
    curl -sk -X POST "https://$UNIFI_HOST/api/auth/logout" \
      -b "$UNIFI_COOKIE" -o /dev/null
    rm -f "$UNIFI_COOKIE"
}
```

### Tips

- **Use `jq -n --arg` and `--argjson`** for safe JSON construction — never interpolate shell variables into JSON strings
- **PID-unique cookie files** (`/tmp/cookies_$$.txt`) prevent conflicts between concurrent scripts
- **Parse HTTP status** with `curl -w '%{http_code}'` to catch errors the API doesn't report in the response body
- **macOS ships bash 3.2** — no associative arrays (`declare -A`). Use `case` statements or jq for lookups.
- **Source auth in subshells** (`bash -c 'source auth.sh && ...'`) if calling from tools that might interfere with cookie state
- **Store credentials outside the repo** — use `~/.unifi_credentials` with `chmod 600`, never commit passwords

---

## Additional Resources

- [Art-of-WiFi/UniFi-API-client](https://github.com/Art-of-WiFi/UniFi-API-client) — The most comprehensive community API client (PHP). Their source code documents endpoints Ubiquiti doesn't.
- [Apple Wi-Fi Best Practices for UniFi Networks](apple-wifi-best-practices.md) — Recommended settings for reliable roaming with iPhones, iPads, and Macs.

---

*Tested and maintained as part of a home UniFi network with UDR, U7 Pro Max, U7 Pro Outdoor, U6+, NanoHD, USW Flex, and USW Flex 2.5G. Contributions and corrections welcome.*
