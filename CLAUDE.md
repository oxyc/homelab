# CLAUDE.md — repo conventions

Single-host home server on **Debian 13 + Incus** (migrated off Proxmox — see `docs/decisions.md` D14; tailnet name is still `pve`), provisioned with Ansible. Runs today: two podman-capable Incus containers — **gondola** (grocery-tracker) + **den** (Stremio addons), each self-provisioned by its own repo. Planned: Frigate (NVR) + Scrypted (HomeKit/HKSV, **disabled by default**) + Home Assistant + Caddy.

## Hard rules
- **This repo is public. Never commit secrets.** Real values come from a Bitwarden note (`homelab-env`) → `docker/.env`, or HA `secrets.yaml`. Use `{FRIGATE_*}` (Frigate), `!secret` (HA), `{env.*}` (Caddy), `${VAR}` (compose). Only `.env.example` (placeholders) is committed.
- **`docs/` is gitignored** — planning/decisions live there locally and must NOT be pushed.
- Don't add real IPs/passwords to tracked files; placeholders are `192.168.x.x` / `changeme`.

## Validate before committing
```
make validate     # yamllint + ansible-lint + docker compose config (both profiles)
make hooks        # install the local pre-commit hook (.githooks/)
```
The pre-commit hook skips tools that aren't installed; GitHub Actions (`.github/workflows/ci.yml`) runs the full set (public repo = free unlimited CI).

## Architecture (see docs/decisions.md locally for the "why")
- Host = plain Debian 13 + Incus (`incus-base`; containers only — the full `incus`/qemu goes on only when the HAOS VM lands). Guests on an **lvm-thin** pool (VG `pve`/thinpool `data`, snapshots via `incus snapshot`), bridged onto `vmbr0` for LAN IPs. Ansible: `incus_host` + `host_hardening` + `incus_app` roles.
- Containers run **rootful podman-in-Incus** (`security.nesting` + syscall intercepts), AppArmor-**confined** (only works on the Debian kernel; the proxmox kernel needed `apparmor=unconfined`).
- Future camera stack = an **unprivileged Incus container with an Incus `gpu` device** (QuickSync); HA = an **Incus KVM VM** (secureboot off). CX820 main is H.265 → recorded raw; only the HomeKit path transcodes (Scrypted, on the iGPU). HomeKit behind compose `profiles: ["homekit"]`.
- ext4 (not ZFS); backups = restic → Backblaze B2 (app/HA state) + `incus export` → NVMe (local; the vzdump replacement).

## Manual steps (not automated)
BIOS, Omada, Debian install, `incus admin init`, Scrypted camera config, HomeKit pairing. Documented in `docs/` (local).
