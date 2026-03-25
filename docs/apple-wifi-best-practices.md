# Apple Wi-Fi Best Practices for UniFi Networks

Recommended settings for reliable roaming and connectivity with iPhones, iPads, and Macs on UniFi networks. Based on Apple documentation, UniFi community experience, and hands-on testing.

## WLAN Settings (per SSID)

| Setting | Recommendation | Why |
|---------|---------------|-----|
| **802.11r (Fast Roaming)** | DISABLE | Known compatibility issues with UniFi. Apple devices use PMKID caching as a fallback, which works reliably. |
| **802.11v (BSS Transition)** | ENABLE | Low risk — the AP suggests a better AP, but the client decides whether to act. Improves roaming decisions. |
| **802.11k (RRM)** | ENABLE | Neighbor reports let clients scan specific channels instead of all channels, reducing roaming time from seconds to milliseconds. |
| **802.11w (PMF)** | Disabled for WPA2-only; Optional if WPA2/WPA3 transitional | Required for WPA3. "Optional" lets both WPA2 and WPA3 clients connect. |
| **U-APSD** | ENABLE on primary SSID | Significant battery savings for phones/tablets. Disable on IoT-only SSIDs where devices don't support it. |
| **Multicast Enhancement** | ENABLE on primary SSID | Converts multicast to unicast, improving AirPlay/AirDrop reliability. Disable on IoT SSIDs (can break mDNS for some devices). Monitor AirPlay after enabling. |
| **Group Rekey** | 3600 seconds | Default of 0 (never) can cause compatibility issues over long sessions. 3600 is Apple's recommendation. |

## Radio / Channel Settings

| Setting | Recommendation | Why |
|---------|---------------|-----|
| **2.4 GHz width** | 20 MHz | Wider channels on 2.4 GHz cause more interference than benefit. |
| **5 GHz width** | 80 MHz | Good balance of speed and reliability. 160 MHz has limited channel availability. |
| **6 GHz width** | 80-160 MHz | More spectrum available, wider channels work well. |
| **DFS channels** | AVOID | Radar detection forces all clients off the channel instantly — causes disconnections near airports, military, and weather radar. |
| **DTIM** | 1 (2.4 GHz) / 3 (5 GHz) | UniFi defaults are correct. Don't change these. |
| **Channel overlap** | None between APs | Every 5 GHz AP should be on a unique channel. Co-channel APs cause roaming cascades as clients bounce between them at similar signal levels. |
| **Radio AI (auto channels)** | DISABLE | Manual channel assignment prevents unexpected channel changes that disrupt clients. Set channels once and leave them. |

## Roaming Behavior

Apple devices have specific roaming characteristics worth understanding:

- **Scan threshold:** iPhones and iPads start scanning for better APs around **-70 dBm**
- **Roam hysteresis:** Requires the candidate AP to be **8-12 dB stronger** before roaming — Apple is conservative to avoid ping-ponging
- **Sticky clients:** Apple devices prefer to stay on a known-good AP rather than roam aggressively. This means they sometimes hold onto a weak connection longer than expected.
- **Band steering:** Apple handles band selection itself. Avoid aggressive AP-side band steering — it fights the client's logic.

### min_rssi (Minimum RSSI)

UniFi's min_rssi setting kicks clients off an AP when their signal drops below a threshold, forcing them to find a better one. Useful for Apple's sticky-client tendency, but tune carefully:

- **Too aggressive** (e.g., -70): Clients in marginal areas get kicked repeatedly, causing connection loops
- **Too loose** (e.g., -85): Clients stay on distant APs when a closer one is available
- **Recommended starting points:** -75 dBm for 5 GHz, -78 for 2.4 GHz
- **Test before committing:** Walk your space and check signal levels at boundaries. If a client oscillates between kick and reconnect at the same AP, loosen the threshold.

## Private MAC Addresses (iOS 18+)

- iOS 18.4+ defaults to **Fixed** private addresses per network (previously rotated)
- Each SSID gets a unique private MAC that persists across reconnections
- **"Forget This Network"** on iOS resets the private MAC — the device will generate a new one when it rejoins
- If a device disappears from your client list, check whether the network was forgotten and rejoin with a fixed address
- Set Private Wi-Fi Address to **Fixed** (not Rotating) in Settings > Wi-Fi > (i) for reliable tracking

## Site-Level Settings

| Setting | Recommendation | Why |
|---------|---------------|-----|
| **Roaming Assistant** | ENABLE at -75 dBm | Helps push sticky clients to better APs. Works with min_rssi. |
| **Network Optimization** | ENABLE | Reduces unnecessary broadcast traffic. |
| **mDNS** | Mode "all" | Required for AirPlay, AirDrop, HomeKit, and Bonjour discovery across APs. |
| **IGMP Snooping** | DISABLE (unless needed) | Can interfere with multicast discovery. Only enable if you have specific multicast routing needs. |

## Common Issues and Fixes

### Client stuck on distant AP
Apple's roam hysteresis means the client needs a significantly better option before moving. Solutions:
1. Enable min_rssi on the distant AP to force a disconnect
2. Ensure the closer AP is on a different channel (co-channel makes roaming worse)
3. Check that 802.11k and 802.11v are enabled so the client knows about better options

### Repeated disconnect/reconnect loops
Usually caused by min_rssi being too aggressive for the coverage area:
1. Check the client's RSSI at the problem location — if it's near the min_rssi threshold, loosen it by 3 dB
2. Verify there's actually a better AP in range for the client to roam to
3. Check for co-channel interference between nearby APs

### Device not connecting after "Forget Network"
The private MAC rotated. The old MAC entry in your client list is now stale:
1. Rejoin the network on the device
2. Set Private Wi-Fi Address to Fixed
3. Note the new MAC for future tracking

### AirPlay/casting issues after enabling multicast enhancement
Multicast enhancement converts multicast to unicast per-client, which occasionally breaks discovery:
1. Verify mDNS is set to mode "all"
2. If issues persist, disable multicast enhancement on the affected SSID
3. Check that the source and target devices are on the same SSID/VLAN

## AP Placement

- **Ceiling-mount when possible** — APs radiate downward in a dome pattern. Shelf or desk placement creates dead spots.
- **Avoid metal enclosures** — metal doors, steel framing, and filing cabinets cause multipath interference and unpredictable signal patterns
- **One AP per zone** — overlapping coverage is good, but co-channel overlap is bad. Plan channels before placing APs.
