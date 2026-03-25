---
name: unifi-find-ipad
description: Locate the iPad on the UniFi network, checking both known MAC addresses across SSIDs.
argument-hint:
disable-model-invocation: true
allowed-tools: Bash, Read
---

## iPad on my_network (5GHz)
!`source local/devices.sh && ./scripts/unifi_clients.sh $IPAD_PRIMARY`

## iPad on my_network_iot (2.4GHz)
!`source local/devices.sh && ./scripts/unifi_clients.sh $IPAD_SECONDARY`

## Known AP Locations
!`source local/devices.sh && ap_list`

## Instructions
Report the iPad's current location:
- Which SSID is it on (my_network = 5GHz, my_network_iot = 2.4GHz)?
- Which AP (use friendly name + location)?
- Signal strength, satisfaction, uptime
- If on 2.4GHz, note this may indicate the device is far from APs or had 5GHz issues
- If neither MAC is found, the iPad may be asleep, off-network, or its private MAC may have rotated (check Settings > Wi-Fi > my_network > Private Wi-Fi Address on the iPad)
