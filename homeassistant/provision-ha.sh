#!/usr/bin/env bash
# Provision Home Assistant (Container) + Mosquitto as rootful podman + Quadlet INSIDE the Incus `ha`
# container. Idempotent; run as root from a synced copy of the repo's homeassistant/ dir. Mirrors the
# camera stack (docker/provision-cameras.sh). The Incus container + NVMe mount + LAN IP are created by
# the ansible ha_container role. NOT YET VALIDATED ON HARDWARE — HA is not deployed.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
APP=/opt/homeassistant

log() { echo "ha: $*"; }

log "podman + networking deps"
apt-get update -qq
apt-get install -y -qq podman catatonit netavark aardvark-dns

log "config dirs + config-as-code"
mkdir -p "$APP"/config/packages "$APP"/mosquitto/data /mnt/nvr/ha
# Seed configuration.yaml/secrets only if absent (don't clobber a running HA's edits); packages are
# ours, always refreshed.
[ -f "$APP/config/configuration.yaml" ] || install -m 0644 "$SRC/configuration.yaml" "$APP/config/configuration.yaml"
cp -f "$SRC/packages/"*.yaml "$APP/config/packages/" 2>/dev/null || true
if [ ! -f "$APP/config/secrets.yaml" ]; then
  if [ -f "$SRC/secrets.yaml" ]; then install -m 0600 "$SRC/secrets.yaml" "$APP/config/secrets.yaml"
  else log "WARN: no secrets.yaml — copy homeassistant/secrets.yaml (from the Bitwarden note) into $APP/config/"; fi
fi
install -m 0644 "$SRC/mosquitto.conf" "$APP/mosquitto/mosquitto.conf"

log "place Quadlet units (mosquitto + homeassistant)"
install -d /etc/containers/systemd
install -m 0644 "$SRC/quadlet/mosquitto.container"     /etc/containers/systemd/
install -m 0644 "$SRC/quadlet/homeassistant.container" /etc/containers/systemd/

log "generate + (re)start units"
systemctl daemon-reload
systemctl restart mosquitto.service homeassistant.service
log "done. HA at http://<ha_ip>:8123 (first boot: create the owner account). Verify: podman ps"
