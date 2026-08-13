#!/usr/bin/env bash
# Provision the camera stack (Frigate + Caddy [+ Scrypted/cloudflared]) as rootful podman + Quadlet
# INSIDE the unprivileged Incus `cameras` container. Idempotent; run as root from a synced copy of the
# repo's docker/ dir. Mirrors the den stack's podman-Quadlet shape (den/deploy/provision-podman.sh).
#
# The Incus container + `gpu` device + /mnt/nvr mount are created by the ansible docker_host role;
# THIS script sets up podman + the units inside it. NOT YET VALIDATED ON HARDWARE — the camera stack
# is not deployed. Enable optional services with COMPOSE_PROFILES (space/comma list):
#   COMPOSE_PROFILES="homekit tunnel" ./provision-cameras.sh
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"     # the synced docker/ dir
APP=/opt/homelab
PROFILES="${COMPOSE_PROFILES:-}"

log() { echo "cameras: $*"; }

log "podman + networking deps"
apt-get update -qq
apt-get install -y -qq podman catatonit netavark aardvark-dns

log "app dirs + configs"
mkdir -p "$APP"/frigate "$APP"/caddy/data "$APP"/caddy/config "$APP"/scrypted
install -m 0644 "$SRC/frigate/config.yml" "$APP/frigate/config.yml"
install -m 0644 "$SRC/caddy/Caddyfile" "$APP/caddy/Caddyfile"
if [ ! -f "$APP/.env" ]; then
  if [ -f "$SRC/.env" ]; then install -m 0600 "$SRC/.env" "$APP/.env"
  else log "WARN: no $APP/.env — copy docker/.env (from the Bitwarden homelab-env note) into place"; fi
fi

log "build the custom Caddy image (Caddy + cloudflare-dns module)"
podman build -t localhost/homelab-caddy:latest "$SRC/caddy"

log "place Quadlet units (frigate + caddy + network always; scrypted/cloudflared per COMPOSE_PROFILES)"
install -d /etc/containers/systemd
install -m 0644 "$SRC/quadlet/cameras.network"   /etc/containers/systemd/
install -m 0644 "$SRC/quadlet/frigate.container" /etc/containers/systemd/
install -m 0644 "$SRC/quadlet/caddy.container"   /etc/containers/systemd/
case " $PROFILES " in *" homekit "*|*,homekit,*|*homekit*)
  install -m 0644 "$SRC/quadlet/scrypted.container" /etc/containers/systemd/ ;;
  *) rm -f /etc/containers/systemd/scrypted.container ;; esac
case " $PROFILES " in *" tunnel "*|*,tunnel,*|*tunnel*)
  install -m 0644 "$SRC/quadlet/cloudflared.container" /etc/containers/systemd/ ;;
  *) rm -f /etc/containers/systemd/cloudflared.container ;; esac

log "generate + (re)start units"
systemctl daemon-reload
for u in frigate caddy scrypted cloudflared; do
  [ -f "/etc/containers/systemd/$u.container" ] && systemctl restart "$u.service" || true
done
log "done. verify:  podman ps  ;  systemctl --failed"
