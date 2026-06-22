# Network (Omada) — do entirely before the server arrives

Gear: OC200 · ER707-M2 · SG2218P (PoE) · EAP653.

## VLANs
| VLAN | Purpose | Internet? |
|------|---------|-----------|
| Main/Mgmt | Proxmox host, services, your devices, **Apple devices** | yes |
| Cameras | CX820 + doorbell (PoE ports) | **no** (or NTP-only) |

Keep Scrypted + Apple devices (iPhone, Apple TV hub) on the **same L2** so HomeKit mDNS works. If you ever split them, enable Omada's mDNS reflector.

## ACLs
- Cameras VLAN → **deny internet** (Reolink phones home). Allow NTP if you want correct timestamps.
- Allow **Proxmox/Frigate/Scrypted host → cameras VLAN** (RTSP/RTMP/ONVIF).
- Deny cameras VLAN → everything else.

## Addressing
- Plan a subnet scheme; create **DHCP reservations** for: Proxmox host, Docker LXC, HAOS VM, CX820, doorbell.
- Reolink password: **simple alphanumeric** (go2rtc/Scrypted RTMP percent-encoding bug).

## Remote access — WireGuard on the ER707-M2
- Enable the gateway's **WireGuard server** + **Omada DDNS**.
- Scope the client's allowed reach with firewall rules (e.g. Mgmt VLAN only).
- **CGNAT check first:** compare the ER707-M2 WAN IP to `whatismyip`. Match → good. Differ → CGNAT → request a public IP from Antel, or fall back to Tailscale.
- HomeKit needs none of this — Apple Home Hub handles remote viewing.
