# CLAUDE.md — repo conventions

Single-host home server (Proxmox): Frigate (NVR) + Scrypted (HomeKit/HKSV, **disabled by default**) + Home Assistant + Caddy, provisioned with Ansible.

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
- One privileged Docker LXC runs Frigate + Scrypted + Caddy, sharing `/dev/dri` (QuickSync). HA is a separate HAOS VM.
- CX820 main is H.265 → Frigate records it raw; only the HomeKit path transcodes (in Scrypted, on the iGPU).
- HomeKit is built but behind compose `profiles: ["homekit"]` → `docker compose --profile homekit up -d` to enable.
- ext4 (not ZFS); backups = restic → Backblaze B2 (HA state) + vzdump → NVMe (local).

## Manual steps (not automated)
BIOS, Omada, Proxmox ISO install, Scrypted camera config, HomeKit pairing. Documented in `docs/` (local).
