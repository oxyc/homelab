# reolink_cameras

Configures Reolink cameras (encoder + NTP) via their HTTP API — the same API the Reolink
app and Home Assistant's `reolink_aio` use. Idempotent, snapshots before changing.

## Usage
```bash
export FRIGATE_CAM_USER=admin FRIGATE_CAM_PASS=... FRIGATE_CX820_IP=... FRIGATE_DOORBELL_IP=...
# (or: set -a; . docker/.env; set +a)
ansible-playbook site.yml --tags cameras --check --diff   # preview only
ansible-playbook site.yml --tags cameras                  # apply
```

## What it does
- **Snapshots** each camera's current encoder config to `.reolink-snapshots/<name>-enc.json` before any change (so you can revert).
- Applies your per-camera `main`/`sub` overrides (fps, bitrate, and `vType: h264` for the doorbell) **only if different** from current.
- Sets NTP.

## Caveats (verify on YOUR firmware before trusting it)
- Field names/values vary by model/firmware — run `--check` first and eyeball the preview.
- **Codec (`vType`) changes are ignored where the model locks it** — the CX820 main is 4K H.265 only.
- **GOP / I-frame interval is generally NOT exposed by the Reolink API.** For HKSV, the 4×fps
  keyframe requirement is satisfied by Scrypted's transcode output, not the camera.
- Untested against live hardware — treat the defaults as a starting point.
