# homelab

Single-host home server provisioned with Ansible on Proxmox:

- **Frigate** — NVR + object detection (records native H.265, no transcode)
- **Scrypted** — HomeKit live + HomeKit Secure Video
- **Home Assistant** — HAOS VM
- **Caddy** — local HTTPS reverse proxy

All secrets are externalized (env vars / `!secret` / Bitwarden), so this repo is public-safe.

## Layout

```
ansible/   # site.yml + roles: proxmox_host, haos_vm, docker_host, restic_backup
docker/    # compose.yml (frigate + scrypted + caddy, shared /dev/dri) + configs
proxmox/   # optional unattended install answer file
```

## Usage

```bash
# secrets (from Bitwarden note `homelab-env`)
bw get notes homelab-env > docker/.env

# ansible
cd ansible
cp inventory.example.yml inventory.yml      # fill in
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --check --diff    # dry run
ansible-playbook site.yml --tags host       # then: haos, docker, backup
```

App stack alone (e.g. to test on a laptop):

```bash
cd docker && cp ../.env.example .env        # fill in
docker compose up                           # frigate + caddy (HomeKit OFF by default)
```

Common tasks via `make` (run `make help`): `validate`, `up`, `homekit`, `check`, `down`.

Install the local pre-commit hook (validates compose + scans for secrets, skips tools
you don't have): `make hooks`. The same checks run in GitHub Actions on every push
(public repo → free unlimited CI).

## HomeKit (off by default)

Scrypted is built in but **disabled**, so the live stack is Frigate + Caddy (+ HA in
its VM). Test that first. Turning HomeKit on later is a one-line toggle — no config rework:

- **Ansible:** set `enable_homekit: true` in `ansible/group_vars/all.yml`, then `make deploy`.
- **Compose directly:** `docker compose --profile homekit up -d` (or `make homekit`).

That brings up Scrypted with iGPU access. The only remaining work is the **manual**
Scrypted UI setup + HomeKit pairing (not automatable). The go2rtc restreams Scrypted
consumes already exist in `frigate/config.yml`.

Verify the toggle anytime: `make test` (proves Scrypted is off by default, on with the profile).

## Notes

- ext4 (not ZFS); 16GB RAM is enough for this stack.
- Docker-in-one-LXC shares the iGPU (QuickSync) across Frigate + Scrypted.
- CX820 main is H.265 (recorded raw); only the HomeKit path transcodes, on the iGPU.
- Doorbell is the **Reolink PoE Video Doorbell** (2K, 4:3) — keep its main H.264 if possible (HomeKit-friendly, no transcode).
- Scrypted camera setup and HomeKit pairing are manual (not automated).
- Backups: `restic` → Backblaze B2 (HA state); Proxmox `vzdump` → NVMe (local). Footage and Scrypted pairings are not backed up.
