# homelab

Single-host home server: **Frigate** (NVR + object detection), **Scrypted** (HomeKit + HKSV), **Home Assistant**, behind a clean reverse proxy, provisioned with **Ansible**, on **Proxmox**.

Public repo by design — **all secrets are externalized** (see [Secrets](#secrets)), so nothing sensitive lives here.

---

## Hardware

| Part | Spec | Role |
|------|------|------|
| Dell OptiPlex 3060 Micro | i5-8500T (6c/35W), **UHD 630 (QuickSync)**, 16GB RAM | Proxmox host |
| 512GB SSD | — | Proxmox OS + VM/LXC disks + app data |
| 2TB NVMe | — | Frigate recordings (ext4) |
| Reolink **CX820** | 4K/8MP, main = **H.265 only**, PoE | Camera |
| Reolink **doorbell** | ~2K, PoE | Doorbell |
| TP-Link Omada | OC200 · ER707-M2 · SG2218P · EAP653 | Network (VLANs, WireGuard, PoE) |

## Architecture

```
                 Omada (camera VLAN, no internet)
CX820 (H265) ─┐
Doorbell      ─┤
              ▼
        Proxmox host (ext4; iGPU /dev/dri)
        ├── HAOS VM ............ Home Assistant (Matter, automations, notifications)
        └── Docker LXC (/dev/dri shared) 
              ├── Frigate ...... records native H265 (copy) + detect on H264 sub
              ├── Scrypted ..... HomeKit live + HKSV (transcodes H265→H264 on QuickSync)
              └── Caddy ........ local HTTPS reverse proxy (*.home)

Remote access: WireGuard on ER707-M2 (Frigate/HA/SSH).  HomeKit remote = Apple Home Hub (no VPN).
```

**Why this shape** (full rationale in [docs/decisions.md](docs/decisions.md)):
- **Scrypted owns both devices** for HomeKit — the doorbell *requires* it (ring event + 2-way audio aren't in the video stream). Frigate consumes Scrypted/go2rtc restreams.
- **H.265 only hurts the HomeKit path.** Frigate records H.265 raw (no transcode). The H.265→H.264 transcode happens once, in Scrypted, on the iGPU.
- **Docker-in-one-LXC**, not separate LXCs/VMs — multiple containers share `/dev/dri`; a VM would monopolize the iGPU.
- **ext4 everywhere** (not ZFS) — keeps RAM use low (16GB is enough) and avoids write-amplification on the NVR disk.

## Repo layout

```
homelab/
├── README.md                  # this file — master plan
├── .env.example               # placeholder secrets/IPs (real values NOT committed)
├── .gitignore
├── docs/
│   ├── decisions.md           # decision log (the "why" behind every choice)
│   ├── architecture-notes.md  # camera/HomeKit/HKSV deep-dive
│   ├── network.md             # Omada VLANs, ACLs, WireGuard, DDNS, IP plan
│   ├── bios.md                # OptiPlex BIOS prep
│   └── runbook.md             # disaster-recovery / rebuild steps
├── proxmox/
│   └── answer.toml.example    # optional unattended PVE install
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventory.example.yml
│   ├── site.yml               # proxmox_host → haos_vm → docker_host → restic_backup
│   └── roles/{proxmox_host,haos_vm,docker_host,restic_backup}/
└── docker/
    ├── compose.yml            # frigate + scrypted + caddy (share /dev/dri)
    ├── frigate/config.yml     # {FRIGATE_*} placeholders; CX820 + doorbell
    └── caddy/Caddyfile        # {env.*}
```

## Build plan (phased)

### Phase 0 — Before the disks arrive (do now)
- [ ] **BIOS**: enable VT-x + VT-d, AC Power Recovery → On, UEFI, Secure Boot off, keep iGPU on, update BIOS. ([docs/bios.md](docs/bios.md))
- [ ] **Omada**: camera VLAN + ACL (cameras → no internet), IP plan, DHCP reservations, **WireGuard server + DDNS**, CGNAT check. ([docs/network.md](docs/network.md))
- [ ] **Cameras** (if on hand): firmware to known-good, **simple alphanumeric password**, enable ONVIF, set substream as high as allowed, note stream URLs.
- [ ] **Accounts**: iCloud+ tier for 2 cameras (200GB), Apple Home Hub (wired Apple TV preferred), Backblaze B2 bucket + **scoped app key**.
- [ ] **Test the app layer on a laptop**: `docker compose up` Frigate+Caddy to validate config (see [Testing](#testing)).

### Phase 1 — Proxmox host
- [ ] Install PVE to the 512GB SSD (optionally unattended via `proxmox/answer.toml`).
- [ ] `ansible-playbook site.yml --tags host` → repos, NVMe ext4 storage, bridges/VLAN, `/dev/dri` perms.

### Phase 2 — Home Assistant
- [ ] `--tags haos` creates the HAOS VM.
- [ ] **Restore HA from the latest B2/restic backup** (that *is* HA provisioning), or onboard fresh.

### Phase 3 — App stack (Frigate + Scrypted + Caddy)
- [ ] `--tags docker` creates the Docker LXC (privileged, `/dev/dri` bound) and deploys `docker/compose.yml`.
- [ ] Pull secrets: `bw get notes homelab-env > docker/.env`.
- [ ] Verify Frigate records native H.265 + detects on the sub; Caddy serves `*.home` over HTTPS.

### Phase 4 — HomeKit (manual — not automatable)
- [ ] In Scrypted: add CX820 + doorbell via **Reolink plugin** (doorbell → tick Doorbell), enable Rebroadcast, HomeKit, HKSV; confirm transcode shows `h264_vaapi`/`qsv`.
- [ ] Pair to HomeKit (**accessory mode**); enable HKSV per device; verify a motion clip records.

### Phase 5 — Backups & remote
- [ ] `--tags backup`: `restic` → B2 (HA backups; optional secrets/vzdump copy), scheduled + encrypted.
- [ ] Proxmox `vzdump` of LXC/VM → 2TB NVMe (local fast restore).
- [ ] Confirm WireGuard from phone reaches HA/Frigate.

## Secrets

Nothing secret is committed. Externalized per service:

| Service | Mechanism |
|---------|-----------|
| Frigate | `{FRIGATE_*}` env vars referenced in `config.yml` |
| Caddy | `{env.*}` |
| compose | `${VAR}` from `docker/.env` |
| Home Assistant | `!secret` → `secrets.yaml` (gitignored); full state via HA backup |

Real values live in a **Bitwarden secure note** (`homelab-env`), pulled at deploy time:
```bash
bw get notes homelab-env > docker/.env
```
Committed instead: **`.env.example`** (placeholder keys only).

## Backup & recovery

| What | Where | Recovers |
|------|-------|----------|
| Configs (this repo) | public Git | fat-finger, SSD death |
| Secrets | Bitwarden note | SSD/box death |
| HA full state (incl. `.storage`) | **restic → B2** (encrypted, scoped key) | SSD/box death |
| LXC/VM | `vzdump` → 2TB NVMe | SSD death (fast local restore) |
| Scrypted HomeKit pairings | *not backed up* — re-pair on disaster (~20 min) | — |
| Footage | *not backed up* (disposable) | — |

Full steps in [docs/runbook.md](docs/runbook.md).

## Testing

De-risk before the hardware (see [docs/decisions.md](docs/decisions.md) for detail):
1. `ansible-lint` + `ansible-playbook --syntax-check` (instant).
2. **`docker compose up` on your laptop** — validates Frigate/Caddy config now.
3. **Molecule** (Docker driver) for the `docker_host` / `restic_backup` roles (apply + idempotence).
4. **Nested Proxmox VM** — point the inventory at it, run the *whole* playbook as a dress rehearsal.
5. On the real box: `ansible-playbook --check --diff` first.

Can't be pre-tested (hardware/Apple only): iGPU passthrough, camera streams, HomeKit pairing.

## Manual steps (intentionally not automated)
- BIOS settings · Proxmox ISO boot · **Scrypted camera/plugin config** · **HomeKit pairing**. These are clickops or Apple-side; documented in the runbook rather than faked in code.
