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
docker compose up
```

## Notes

- ext4 (not ZFS); 16GB RAM is enough for this stack.
- Docker-in-one-LXC shares the iGPU (QuickSync) across Frigate + Scrypted.
- Scrypted camera setup and HomeKit pairing are manual (not automated).
- Backups: `restic` → Backblaze B2 (HA state); Proxmox `vzdump` → NVMe (local). Footage and Scrypted pairings are not backed up.
