#!/usr/bin/env bash
# Provision the camera stack (Frigate + Caddy [+ Scrypted/cloudflared]) as rootful podman + Quadlet
# INSIDE the unprivileged Incus `cameras` container. Idempotent; run as root from a synced copy of the
# repo's docker/ dir. Mirrors the den stack's podman-Quadlet shape (den/deploy/provision-podman.sh).
#
# The Incus container + `gpu` device + /mnt/nvr mount are created by the ansible camera_container role;
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

# Detection model: Frigate bundles no YOLOv9, so build the ONNX once (idempotent) into model_cache/,
# where config.yml's `model.path: /config/model_cache/yolo.onnx` expects it. Recipe adapted from
# https://docs.frigate.video/configuration/object_detectors (git clone vs BuildKit ADD, for podman).
# UNTESTED ON HARDWARE. If this build fails, switch config.yml to the ssdlite fallback to boot, re-run.
MODEL_SIZE=s; IMG_SIZE=640    # 640 = better small/distant detection (far gates); must match config.yml model.width/height
MODEL_CACHE="$APP/frigate/model_cache"
mkdir -p "$MODEL_CACHE"
if [ -f "$MODEL_CACHE/yolo.onnx" ]; then
  log "detection model: yolo.onnx already present — skipping build"
else
  log "detection model: building YOLOv9-$MODEL_SIZE ONNX (one-time; pulls torch + weights, ~several min)"
  _ctx="$(mktemp -d)"
  podman build --build-arg MODEL_SIZE="$MODEL_SIZE" --build-arg IMG_SIZE="$IMG_SIZE" \
    --output "type=local,dest=$MODEL_CACHE" -f- "$_ctx" <<'DOCKERFILE'
FROM python:3.11 AS build
RUN apt-get update && apt-get install --no-install-recommends -y cmake libgl1 git && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
WORKDIR /yolov9
RUN git clone --depth 1 https://github.com/WongKinYiu/yolov9.git .
RUN uv pip install --system -r requirements.txt
RUN uv pip install --system onnx==1.18.0 onnxruntime onnx-simplifier==0.4.* onnxscript
ARG MODEL_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt yolov9-${MODEL_SIZE}.pt
RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py
ARG IMG_SIZE
RUN python3 export.py --weights ./yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx
FROM scratch
ARG MODEL_SIZE
ARG IMG_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /yolov9-${MODEL_SIZE}-${IMG_SIZE}.onnx
DOCKERFILE
  mv "$MODEL_CACHE/yolov9-$MODEL_SIZE-$IMG_SIZE.onnx" "$MODEL_CACHE/yolo.onnx"
  rm -rf "$_ctx"
  podman builder prune -f >/dev/null 2>&1 || true    # reclaim the ~5GB one-shot build cache
  log "detection model: wrote $MODEL_CACHE/yolo.onnx"
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
