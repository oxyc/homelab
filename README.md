# homelab

Single-host home server provisioned with Ansible. The host is **plain Debian 13 + [Incus](https://linuxcontainers.org/incus/)** (migrated off Proxmox VE — see `docs/decisions.md`; the tailnet name is still `pve` for historical reasons but there is no PVE control plane).

**Running today** — two podman-capable Incus containers, each self-provisioned by its own repo:
- **gondola** — the grocery-tracker app (reached via its Cloudflare tunnel)
- **den** — Stremio addons (LAN, `192.168.x.193`)

**Planned** (opt-in roles, not yet deployed on this box):
- **Frigate** — NVR + object detection (records native H.265, no transcode)
- **Scrypted** — HomeKit live + HomeKit Secure Video
- **Home Assistant** — as an Incus KVM VM
- **Caddy** — local HTTPS reverse proxy

The camera stack will run as an **unprivileged Incus container with an Incus `gpu` device** (QuickSync passthrough) + HAOS as an Incus VM. All secrets are externalized (env vars / `!secret` / Bitwarden), so this repo is public-safe.

## Layout

```
ansible/   # site.yml + roles: incus_host, host_hardening, tailscale, incus_app,
           #                    haos_vm (future), camera_container (future), restic_backup, reolink_cameras
docker/    # podman Quadlet units (frigate + caddy + scrypted, shared /dev/dri) + configs + provision-cameras.sh — the future camera container
```

## Configuration

Every file with real values has a committed `*.example` template and a **gitignored** real
file you create from it. Fill them in, then `make check-config` verifies nothing's missing or
left as a placeholder — and `make deploy` runs that check first, so a half-configured setup
won't deploy.

| Copy this template | → to (gitignored) | What goes in it |
|--------------------|-------------------|-----------------|
| `docker/.env.example` | `docker/.env` | secrets + IPs — pull from your password manager: `bw get notes homelab-env > docker/.env` |
| `ansible/group_vars/all.example.yml` | `ansible/group_vars/all.yml` | mostly defaults; set `haos_ip` to your HA VM |
| `ansible/inventory.example.yml` | `ansible/inventory.yml` | Debian host IP, container IP + gateway |
| `tailscale/acl.hujson.example` | `tailscale/acl.hujson` | your tailnet login + LAN CIDR (then paste into the Tailscale console) |
| `proxmox/answer.toml.example` | `proxmox/answer.toml` | *(optional)* unattended install: hashed root pw + email |

- Secrets never live in the Ansible files — e.g. `ts_authkey` is an `env` lookup into `docker/.env`,
  so run `set -a; . docker/.env; set +a` before deploying. (Incus is managed over the local socket,
  so there's no PVE API password to export anymore.)
- Optional values you aren't using yet (e.g. `TUNNEL_TOKEN`) — **comment them out**;
  `check-config` skips commented lines.
- Validate anytime: **`make check-config`**.

## Usage

```bash
set -a; . docker/.env; set +a               # export secrets for Ansible's env lookups
make check-config                           # verify config is complete
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --check --diff    # dry run
ansible-playbook site.yml --tags host       # then: haos, docker, backup  (or `make deploy`)
```

Camera stack (podman + Quadlet, run inside the Incus `cameras` container — deployed by ansible):

```bash
# on the box, inside the cameras container (or via the camera_container role):
COMPOSE_PROFILES="homekit tunnel" docker/provision-cameras.sh   # omit profiles for frigate+caddy only
```

Common tasks via `make` (run `make help`): `validate`, `check`, `deploy`, `health`.

Install the local pre-commit hook (scans for secrets, skips tools
you don't have): `make hooks`. The same checks run in GitHub Actions on every push
(public repo → free unlimited CI).

## Access

Real IPs live only in `docker/.env` (`PROXMOX_IP` — legacy var name, now the Debian host — `HAOS_IP`,
`SCRYPTED_HOST`) — the placeholders below stand in for them. `pve` is the Tailscale MagicDNS name (the
host's `ts_hostname`), so it resolves from any device on the tailnet with no IP to remember.

**Incus (CLI — there is no web UI)**

Guests are managed over SSH with the `incus` CLI (the host runs plain Debian + Incus, no Proxmox web UI):

```bash
ssh root@pve
incus list                       # instances + IPs
incus exec gondola -- bash       # shell into a container
incus snapshot create den        # point-in-time snapshot (lvm-thin pool)
incus export gondola /mnt/nvr/... # full instance backup (the vzdump replacement)
```

**SSH** — key-only after hardening (`PasswordAuthentication no`, `PermitRootLogin
prohibit-password`). Keys are pulled from `github.com/<admin_github_user>.keys` for both
`oxyc` and `root`, so any device holding a matching private key gets in.

```bash
# LAN, direct
ssh oxyc@<PROXMOX_IP>          # admin (passwordless sudo)
ssh root@<PROXMOX_IP>          # root (key-only)

# Over Tailscale (MagicDNS) — works from anywhere, no port-forward
ssh oxyc@pve
ssh root@pve
```

> Tailscale SSH: if the tailnet ACL has the admin→host rule set to `check` (the default in
> `tailscale/acl.hujson.example`), the first `ssh …@pve` prints a
> `login.tailscale.com/a/…` URL you must open once to authenticate. For non-interactive use
> (Ansible over the tailnet) set that rule to `accept`, or run Ansible over the LAN IP instead.

**Ansible** runs from your workstation over whichever address is in `ansible/inventory.yml`
(`ansible_host` = the LAN IP now, `pve` once you're off-site). Always export the env first:

```bash
set -a; . docker/.env; set +a
cd ansible && ansible-playbook site.yml --check --diff
```

**Services (once the guest roles are deployed)** — reached by IP, or by name if Caddy + DNS
are configured:

| Service | Direct | Via Caddy |
|---------|--------|-----------|
| Home Assistant | `http://<HAOS_IP>:8123` | `https://ha.<CADDY_LOCAL_DOMAIN>` |
| Frigate | `http://<SCRYPTED_HOST>:5000` | `https://frigate.<CADDY_LOCAL_DOMAIN>` |
| Scrypted (homekit profile) | `https://<SCRYPTED_HOST>:10443` | `https://scrypted.<CADDY_LOCAL_DOMAIN>` |

### Home Assistant on your phone

1. Install the **Home Assistant** Companion app (iOS/Android) and log in with your HA account.
2. **At home** (same LAN) the app auto-discovers HA, or enter the URL manually:
   `https://ha.<CADDY_LOCAL_DOMAIN>` (real cert) or `http://<HAOS_IP>:8123`.
3. **Away from home** — the box only exposes Tailscale, so put the phone on the tailnet:
   - Install **Tailscale** and sign in (this phone is already a tailnet node).
   - The host advertises the `192.168.10.0/24` route (`ts_advertise_routes`), so with
     Tailscale on, `http://<HAOS_IP>:8123` reaches HA directly — no Nabu Casa, nothing public.
4. In the HA app, set **both** the home and remote URL to the **same** value so it just works
   in either place. Most reliable over Tailscale is the IP (`http://<HAOS_IP>:8123`);
   `https://ha.<domain>` also works if MagicDNS split-DNS maps `<CADDY_LOCAL_DOMAIN>` to the box.

No-Tailscale alternatives: Nabu Casa Cloud (paid, one toggle) or a Cloudflare Tunnel + Access —
but Tailscale is the zero-exposure option you already run.

## HomeKit (off by default)

Scrypted is built in but **disabled** via a Docker Compose profile, so the live stack is
Frigate + Caddy (+ HA in its VM). Test that first. The toggle is just the compose profile —
no extra machinery:

- **Compose:** `docker compose --profile homekit up -d` (or `make homekit`).
- **Ansible:** set `compose_profiles: [homekit]` in `ansible/group_vars/all.yml`, then `make deploy`.

That brings up Scrypted with iGPU access. The remaining work is the **manual** Scrypted UI
setup + HomeKit pairing. The go2rtc restreams Scrypted consumes already exist in `frigate/config.yml`.

## Notes

- Host is plain **Debian 13 + Incus** (migrated off Proxmox — `docs/decisions.md` D14). Guests are
  **Incus containers** on an **lvm-thin** pool (snapshots via `incus snapshot`); the default profile
  bridges each guest onto `vmbr0` so it gets a LAN IP directly.
- ext4 (not ZFS); 16GB RAM is enough for this stack.
- The future camera container shares the iGPU (QuickSync) across Frigate + Scrypted via an Incus
  `gpu` device (unprivileged) — cleaner than Proxmox's privileged-LXC `/dev/dri` share.
- CX820 main is H.265 (recorded raw); only the HomeKit path transcodes, on the iGPU.
- Doorbell is the **Reolink PoE Video Doorbell** (2K, 4:3) — keep its main H.264 if possible (HomeKit-friendly, no transcode).
- Scrypted camera setup and HomeKit pairing are manual (not automated).
- Remote access: **Tailscale** on the host (`--ssh`) — SSH from your phone, no ports/keys. (`ansible/roles/tailscale`)
- Home Assistant config-as-code under `homeassistant/` (Matter + Frigate cameras; no Zigbee). Most of it is code; Matter pairing + add-on install stay in the UI.
- Backups: the `restic_backup` role ships HA state → **Cloudflare R2** (S3-compatible); `incus export` → NVMe (local, the vzdump replacement). Each app container backs up its own data offsite from its own repo. Footage and Scrypted pairings are not backed up.
