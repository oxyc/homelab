# Home Assistant — config as code

Version-controlled HA config. Scope: **Matter + the Frigate cameras**. No Zigbee.

## What's in here
- `configuration.yaml` snippet — wires the `packages/` dir into HA.
- `packages/` — automations/helpers as code (e.g. doorbell/person notifications).
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
