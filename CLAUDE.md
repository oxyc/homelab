# CLAUDE.md — repo conventions

Single-host home server on **Debian 13 + Incus** (migrated off Proxmox — see `docs/decisions.md` D14; tailnet name is still `pve`), provisioned with Ansible. Runs today: two podman-capable Incus containers — **gondola** (grocery-tracker) + **den** (Stremio addons), each self-provisioned by its own repo. Planned: Frigate (NVR) + Scrypted (HomeKit/HKSV, **disabled by default**) + Home Assistant + Caddy.

## Hard rules
- **This repo is public. Never commit secrets.** Real values come from a Bitwarden note (`homelab-env`) → `docker/.env`, or HA `secrets.yaml`. Use `{FRIGATE_*}` (Frigate), `!secret` (HA), `{env.*}` (Caddy), `${VAR}` (shell/`.env`). Only `.env.example` (placeholders) is committed.
- **`docs/` is gitignored** — planning/decisions live there locally and must NOT be pushed.
- Don't add real IPs/passwords to tracked files; placeholders are `192.168.x.x` / `changeme`.

## Validate before committing
```
make validate     # yamllint + ansible-lint (camera stack is podman-Quadlet — units validate at deploy)
make hooks        # install the local pre-commit hook (.githooks/)
```
The pre-commit hook skips tools that aren't installed; GitHub Actions (`.github/workflows/ci.yml`) runs the full set (public repo = free unlimited CI).

## Architecture (see docs/decisions.md locally for the "why")
- Host = plain Debian 13 + Incus (`incus-base`; **containers only — no qemu ever**, since HA is now a container too, not a VM). Guests on an **lvm-thin** pool (VG `pve`/thinpool `data`, snapshots via `incus snapshot`), bridged onto `vmbr0` for LAN IPs. Ansible: `incus_host` + `host_hardening` + `incus_app` roles.
- Containers run **rootful podman-in-Incus** (`security.nesting` + syscall intercepts), AppArmor-**confined** (only works on the Debian kernel; the proxmox kernel needed `apparmor=unconfined`).
- Future camera stack = an **unprivileged Incus container with an Incus `gpu` device** (QuickSync), running **rootful podman + Quadlet** (units in `docker/quadlet/`, provisioned by `docker/provision-cameras.sh` — same shape as gondola/den, no docker-compose). HA = **Home Assistant Container** + Mosquitto (podman + Quadlet) in its own Incus container — config-as-code in `homeassistant/`, provisioned by `homeassistant/provision-ha.sh`, recorder DB on the NVMe (not a HAOS VM → box stays `incus-base`). CX820 main is H.265 → recorded raw; only the HomeKit path transcodes (Scrypted, on the iGPU). HomeKit/tunnel are opt-in via `compose_profiles: [homekit, tunnel]` (the provisioner only installs those Quadlet units).
- ext4 (not ZFS); backups = restic → Cloudflare R2 (HA state, per `restic_backup`; each app does its own offsite) + `incus export` → NVMe (local; the vzdump replacement).

## Manual steps (not automated)
BIOS, Omada, Debian install, `incus admin init`, Scrypted camera config, HomeKit pairing. Documented in `docs/` (local).
