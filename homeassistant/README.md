# Home Assistant — config as code

Version-controlled HA config. Scope: **Matter + the Frigate cameras**. No Zigbee.

## What's in here
- `configuration.yaml` snippet — wires the `packages/` dir into HA.
- `packages/cameras.yaml` — doorbell/person notifications.
- `packages/monitoring.yaml` — self-monitoring → phone: backup dead-man's switch, a generic
  alert webhook (smartd + the host's systemd/restic alerts call it), and a single notify target.

## Monitoring setup (one-time)
1. Install the **HA mobile app** on your phone (creates `notify.mobile_app_<device>`).
2. In `packages/monitoring.yaml` → `script.homelab_notify`, change `notify.notify` to your
   `notify.mobile_app_<device>`.
3. **Host alerts → phone:** nothing to configure in a hypervisor UI — the Debian+Incus host has
   none. `host_hardening` installs the smartd alert script and the restic timers, which POST
   directly to `http://<ha-ip>:8123/api/webhook/homelab_alert` (SMART/temperature) and
   `.../homelab_backup_ok` (backup dead-man's switch). Just make sure those webhook automations
   exist in `packages/monitoring.yaml`.
- `secrets.yaml.example` — placeholder; real `secrets.yaml` is gitignored.

## How it's delivered
Sync these into HA's `/config` (Git Pull add-on, or the Samba/SSH add-on). Then add the
include line from `configuration.yaml` to your real `configuration.yaml` and restart HA.

## What stays manual (UI / not code)
- **Matter**: install the Matter Server add-on and commission devices in the app (pairing is UI).
- **Frigate integration**: added as a UI integration (it auto-discovers via MQTT); the
  notification logic lives here in `packages/`.
- **Add-ons**: Mosquitto (MQTT for Frigate), Matter Server, Google-Drive/restic backup —
  install via the Supervisor (one-time), or script via the Supervisor API later.
- Cloud OAuth integrations (if any) — UI.

Everything reproducible-from-code lives here; the rest is captured by the HA backup
(restic → B2).
