# Reddit Post Draft — r/Ubiquiti

## Title
I built shell scripts for the most common UniFi home network pain points — open source

## Body

After spending months tuning my home UniFi network (UDR, U7 Pro Max, U7 Pro Outdoor, U6+, NanoHD), I kept running into the same issues everyone else posts about. So I built scripts to solve them.

**The repo:** https://github.com/jpav88/unifi-tools

Everything is shell scripts (`bash` + `curl` + `jq`) — no Docker, no Python dependencies, no cloud. Just your controller's local API.

### What it solves

**"Why is `stat/event` returning empty?"** — The v1 events endpoint is broken on current firmware. `unifi_events.sh` uses the v2 `system-log` API instead, with automatic fallback. Actually returns data.

**"Client rename gives me 403"** — The `rest/user` endpoint requires the full client object. `unifi_write.sh rename` uses `upd/user` which accepts partial updates. Just works.

**"How do I get alerted when a new device joins?"** — `unifi_new_devices.sh` maintains a known-devices list. Run `--learn` once, then run it on a cron to detect unknowns.

**"Who's eating all my bandwidth?"** — `unifi_bandwidth.sh` shows per-client usage sorted by total bytes. Run with `1` for the last hour to see who's hogging it right now.

**"My devices won't roam" / "Sticky clients"** — `unifi_wifi_check.sh` audits your entire network: flags weak signal clients, high retry rates, co-channel interference, and WLAN misconfigurations (missing 802.11k/v, wrong group_rekey, etc). Also published an [Apple Wi-Fi best practices guide](https://github.com/jpav88/unifi-tools/blob/main/docs/apple-wifi-best-practices.md) for iPhone/iPad-specific tuning.

**"Is my channel plan good?"** — `unifi_channel_plan.sh` pulls spectrum scan data from all your APs and cross-references against your current channels. Flags co-channel conflicts and suggests alternatives.

**"Historical AP stats without UnPoller/Grafana?"** — `unifi_ap_stats.sh` uses the built-in `stat/report` API for per-AP client counts and traffic over time. No extra stack needed.

### Bonus: UniFi API Reference

I also published a [practical API reference](https://github.com/jpav88/unifi-tools/blob/main/docs/unifi-api-reference.md) covering both v1 and v2 endpoints with curl examples. Documents the gotchas nobody else writes about — the `upd/user` vs `rest/user` 403, WPA3 changes silently failing via API, syslog config being silently dropped on v9+, spectrum scan data being empty by default, and more. Sourced from the [Art-of-WiFi](https://github.com/Art-of-WiFi/UniFi-API-client) PHP client + hands-on testing.

### What it's NOT

- Not an MCP server or AI wrapper — just simple scripts
- Not for MSPs managing 50 sites — it's for home/small networks with 3-10 APs
- Not a replacement for the UniFi UI — it supplements it with things the UI doesn't expose

Feedback welcome. If you've hit a UniFi API problem I haven't covered, open an issue.

---

# Forum Reply Drafts

## For "stat/event returns empty" threads

**Reply:**

The v1 `stat/event` endpoint is broken on current firmware — it returns empty even with valid parameters. The fix is to use the v2 `system-log` API instead:

```bash
curl -sk -X POST -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"start":START_MS,"end":END_MS,"page":0,"size":50}' \
  "https://CONTROLLER/proxy/network/v2/api/site/default/system-log/device-alert"
```

Available classes: `device-alert`, `client-alert`, `admin-activity`, `update-alert`, `threat-alert`.

I built a script that handles this automatically (tries v2, falls back to v1): https://github.com/jpav88/unifi-tools/blob/main/scripts/unifi_events.sh

Full API reference with more v2 endpoints: https://github.com/jpav88/unifi-tools/blob/main/docs/unifi-api-reference.md


## For "client rename 403" threads

**Reply:**

The `rest/user/{_id}` PUT endpoint requires the **full client object** — partial updates return 403. Use `upd/user/{_id}` instead, which accepts partial payloads:

```bash
curl -sk -X PUT -b "$COOKIES" -H "X-Csrf-Token: $CSRF" \
  -H "Content-Type: application/json" \
  -d '{"name":"My Device Name"}' \
  "https://CONTROLLER/proxy/network/api/s/default/upd/user/CLIENT_ID"
```

Get the `_id` from `stat/alluser` first. Full script with MAC lookup built in: https://github.com/jpav88/unifi-tools/blob/main/scripts/unifi_write.sh


## For "new device alert" threads

**Reply:**

I built a script that does this: https://github.com/jpav88/unifi-tools/blob/main/scripts/unifi_new_devices.sh

First run: `./unifi_new_devices.sh --learn` (seeds a known-devices list from all clients the controller has ever seen).

Then run periodically (cron, launchd, etc.): `./unifi_new_devices.sh` — shows any device not in the known list with its name, MAC, IP, AP, and signal.

Requires `curl` and `jq`. Works against the local controller API, no cloud needed.
