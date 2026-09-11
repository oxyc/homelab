# homelab

Single-host home server provisioned with Ansible. The host is **plain Debian 13 + [Incus](https://linuxcontainers.org/incus/)** (migrated off Proxmox VE — see `docs/decisions.md`; the tailnet name is still `pve` for historical reasons but there is no PVE control plane).

**Running today** — two podman-capable Incus containers, each self-provisioned by its own repo:
- **gondola** — the grocery-tracker app (reached via its Cloudflare tunnel)
- **den** — Stremio addons, plus **den-edge** (device log collector) and **den-remux** (video
  remuxing) (LAN, `192.168.x.193`, shares the iGPU)

Homelab owns only the container *shell* for these — sizing, snapshots, devices, host-level export.
Both are described in `incus_apps` (see `ansible/inventory.example.yml`); what runs *inside* belongs
to each app's own repo.

**Planned** (opt-in roles, not yet deployed on this box):
- **Frigate** — NVR + object detection (records native H.265, no transcode)
- **Scrypted** — HomeKit live + HomeKit Secure Video
- **Home Assistant** — HA Container + Mosquitto (podman, config-as-code — not a HAOS VM)
- **Caddy** — local HTTPS reverse proxy

The camera stack runs as an **unprivileged Incus container with an Incus `gpu` device** (QuickSync passthrough), and Home Assistant as its own podman container — everything's a container, no VM. All secrets are externalized (env vars / `!secret` / Bitwarden), so this repo is public-safe.

### The iGPU is shared, and nothing here enforces priority

The UHD 630 is attached to **den** today and will also be attached to the **cameras** container;
Incus is happy to hand one Intel GPU to several containers. Expected load barely overlaps — Frigate
decodes for detection (it records H.265 as-is), Scrypted transcodes only while someone is watching
over HomeKit, and den-remux only copies streams unless hardware transcoding is turned on.

Be clear about what that "cameras win if it gets tight" rule is, though: **a statement of intent, not
a control.** Incus has no GPU priority or share mechanism — `/dev/dri` access is first-come. The only
real lever is capping the *consumers*, which lives in their own repos (den-remux caps concurrent
hardware transcodes via `MAX_TRANSCODES`, default 1; plain remuxing copies video and never touches
the GPU). Homelab can attach the device and write the policy down; it cannot arbitrate it.

The device's `gid` is **not** hardcoded — it is the render group *inside each container*, which is
not the host's (den's is 991, the host's 993), so `incus_app` looks it up at provision time. Pinning
a literal would break silently on a new base image: the device appears, owned by the wrong group, and
a non-root process just cannot open it.

### `tailscale serve` is in Ansible now

It used to say here that the routes "will keep moving, so pinning them in Ansible would just create
churn", and that a rebuilt host simply would not have them. That stopped being defensible once
den-reel and den-remux had no Cloudflare route: the tailnet became the *only* way to reach video
from outside the house, and a hand-added proxy config recorded nowhere is exactly what left den's
export timer and its systemd units to be discovered by accident months later.

`ts_serve_routes` (role defaults, real targets in the gitignored vars) is now the source of truth.
There is no `serve set-raw`, so the role diffs the live config and only resets + re-adds when it
differs — a re-run with nothing to do reports `changed=0`.

## Layout

```
ansible/   # site.yml + roles: incus_host, host_hardening, tailscale, incus_app,
           #                    ha_container (future), camera_container (future), restic_backup, reolink_cameras
homeassistant/  # HA-Container config-as-code (configuration.yaml + packages) + Quadlet units + provision-ha.sh
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
| `ansible/group_vars/all.example.yml` | `ansible/group_vars/all.yml` | mostly defaults; set `ha_ip` to the HA container |
| `ansible/inventory.example.yml` | `ansible/inventory.yml` | Debian host IP, container IP + gateway |
| `tailscale/acl.hujson.example` | `tailscale/acl.hujson` | tailnet policy (`grants` + SSH); generic single-user, nothing to fill — paste into the console |
| `cloudflare/access.example.json` | `cloudflare/access.json` | private-tunnel desired state: hostnames, Access emails, rate limits (see `cloudflare/README.md`) |
| `cloudflare/ingress.example.yml` | `cloudflare/ingress.yml` | cloudflared's routing table — which hostname reaches which LAN service |
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
ansible-playbook site.yml --tags host       # then: ha, cameras, backup  (or `make deploy`)
```

Camera stack (podman + Quadlet, run inside the Incus `cameras` container — deployed by ansible):

```bash
# on the box, inside the cameras container (or via the camera_container role):
COMPOSE_PROFILES="homekit tunnel" docker/provision-cameras.sh   # omit profiles for frigate+caddy only
```

Common tasks via `make` (run `make help`): `validate`, `check`, `deploy`, `health`.

### Rebuilding a guest from nothing

Homelab creates the container *shell*; the app's own repo provisions what runs inside; the app's own
backup restores its state. All three are needed and the **order matters** — this is the sequence,
established by actually rehearsing it against den's restic backup on 2026-09-11.

1. **Host** — `--tags host`: `incus_host` (lvm-thin pool, the `default` profile that gives each guest
   its root disk and an `eth0` on `vmbr0`), then `host_hardening`, then `tailscale`.
2. **Shell** — `--tags app`: `incus_app` launches the container from the matching `incus_apps` entry
   (nesting + syscall intercepts, autostart, delete-protection, snapshot schedule, root disk), writes
   the static IP *inside* the guest as a systemd-networkd unit when `ip:` is set, installs ssh + your
   GitHub keys, then reconciles config and attaches devices (e.g. the shared iGPU, with the gid read
   from that container's own render group).
3. **Hand off to the app's repo.** Homelab stops here, deliberately. Two things it does NOT do, and
   which have bitten a rehearsal:
   - the app's `deploy/` tree is not a git checkout on the box — you push it from a laptop, and for a
     private app repo that means having GitHub access first;
   - the app's **secrets must land before its provisioner runs**, because provisioners typically
     render per-service env files *from* that one file. Restore secrets, then provision.
4. **Restore state last**, with the consuming service stopped if it keeps a log or database that a
   client tracks by sequence number. See the app repo for which paths and in what order.

What homelab does **not** capture, and would have to be redone by hand: `tailscale serve` (see above),
and anything an app's own updater writes on the box (e.g. pinned image digests — recoverable by
letting the updater run, but the record of *which* digest was live is not).

`ansible/inventory.yml` is gitignored and is the only description of your guests' shells. It is small
(~1.4 KB without comments) — keep a copy somewhere off this machine, or a rebuild starts by guessing
IP addresses.

Install the local pre-commit hook (scans for secrets, skips tools
you don't have): `make hooks`. The same checks run in GitHub Actions on every push
(public repo → free unlimited CI).

## Access

Real IPs live only in `docker/.env` (`PROXMOX_IP` — legacy var name, now the Debian host — `HA_IP`,
`SCRYPTED_HOST`) — the placeholders below stand in for them. `pve` is the Tailscale MagicDNS name (the
host's `ts_hostname`), so it resolves from any device on the tailnet with no IP to remember.

### The three ways in to den

Three doors into one room: the services listen on plain LAN ports, and both remote paths proxy to
those same ports. `<den>` is den's LAN address, `<tailnet>` the MagicDNS name, `<domain>` the zone.

| service | port | LAN | tailnet (`tailscale serve`) | Cloudflare |
|---|---|---|---|---|
| den-edge | 8094 | `<den>:8094` | `/` | `d.<domain>` *(Access)* + `d-api.<domain>` *(bypass)* |
| den-scout | 8080 | `<den>:8080` | `/scout` | `d-scout.<domain>` *(Access + TV token)* + `d-play.<domain>` *(bypass, `/p/…` only)* |
| den-atlas | 8081 | `<den>:8081` | `/atlas` | `d-atlas.<domain>` *(Access + TV token)* |
| den-subtitles | 8093 | `<den>:8093` | `/subs` | `d-subs.<domain>` *(Access + TV token)* |
| den-reel | 8092 | `<den>:8092` | `/reel` | — **video** |
| den-remux | 8095 | `<den>:8095` | `/remux` | — **video** |
| den-embed | — | — | — | — internal only |

```bash
https://<tailnet>:8443/scout/manifest.json    # tailnet, real public-CA TLS, no ports opened
```

**The two blanks are the design, not a gap.** Cloudflare's terms restrict serving video through the
CDN/Tunnel outside its paid video products, and a strike would land on the account that also serves
gondola — so den-reel and den-remux are deliberately absent from the tunnel, and the tailnet is
their only route in from outside. See `cloudflare/README.md`.

**den-embed is not reachable and should stay that way.** It is den-scout's embedding sidecar,
unpublished on den's podman network, reached only by scout over that network. Exposing it would
mean publishing a host port first (den's repo, not this one) and would hand an inference endpoint —
the most CPU-expensive thing on the box — to anything that could reach it, for no user-facing
benefit. Debug it with `incus exec den -- podman exec …`, not a route.

**Prefix handling bites.** A `serve` target *without* a path strips the prefix
(`/scout/manifest.json` → `:8080/manifest.json`); one *with* a path keeps it, which is what
den-remux expects (`:8095/remux`). Getting it backwards 404s.

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

> Tailscale SSH: the SSH rule in `tailscale/acl.hujson.example` defaults to `accept` (no re-auth
> prompt — the pragmatic choice for a single-user, tailnet-only box). If you switch it to `check`,
> the first `ssh …@pve` prints a `login.tailscale.com/a/…` URL to authenticate and re-auth recurs
> every 12h — a *custom* re-auth period (e.g. weekly) needs Tailscale Premium/Enterprise.

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
| Home Assistant | `http://<HA_IP>:8123` | `https://ha.<CADDY_LOCAL_DOMAIN>` |
| Frigate | `http://<SCRYPTED_HOST>:5000` | `https://frigate.<CADDY_LOCAL_DOMAIN>` |
| Scrypted (homekit profile) | `https://<SCRYPTED_HOST>:10443` | `https://scrypted.<CADDY_LOCAL_DOMAIN>` |

### Home Assistant on your phone

1. Install the **Home Assistant** Companion app (iOS/Android) and log in with your HA account.
2. **At home** (same LAN) the app auto-discovers HA, or enter the URL manually:
   `https://ha.<CADDY_LOCAL_DOMAIN>` (real cert) or `http://<HA_IP>:8123`.
3. **Away from home** — the box only exposes Tailscale, so put the phone on the tailnet:
   - Install **Tailscale** and sign in (this phone is already a tailnet node).
   - The host advertises the `192.168.10.0/24` route (`ts_advertise_routes`), so with
     Tailscale on, `http://<HA_IP>:8123` reaches HA directly — no Nabu Casa, nothing public.
4. In the HA app, set **both** the home and remote URL to the **same** value so it just works
   in either place. Most reliable over Tailscale is the IP (`http://<HA_IP>:8123`);
   `https://ha.<domain>` also works if MagicDNS split-DNS maps `<CADDY_LOCAL_DOMAIN>` to the box.

No-Tailscale alternatives: Nabu Casa Cloud (paid, one toggle) or a Cloudflare Tunnel + Access —
but Tailscale is the zero-exposure option you already run.

## HomeKit (off by default)

Scrypted's Quadlet unit is **not installed** unless the `homekit` profile is set, so the live stack is
Frigate + Caddy (+ the HA container). Test that first. The toggle is just the profile — no extra machinery:

- **On the box:** `COMPOSE_PROFILES="homekit" docker/provision-cameras.sh` (installs the scrypted unit).
- **Ansible:** set `compose_profiles: [homekit]` in `ansible/group_vars/all.yml`, then `make deploy`.

That brings up Scrypted with iGPU access. The remaining work is the **manual** Scrypted UI
setup + HomeKit pairing. The go2rtc restreams Scrypted consumes already exist in `frigate/config.yml`.

## Notes

- Host is plain **Debian 13 + Incus** (migrated off Proxmox — `docs/decisions.md` D14). Guests are
  **Incus containers** on an **lvm-thin** pool (snapshots via `incus snapshot`); the default profile
  bridges each guest onto `vmbr0` so it gets a LAN IP directly.
- ext4 (not ZFS); 16GB RAM is enough for this stack.
- The iGPU (QuickSync) is shared via an Incus `gpu` device (unprivileged) — cleaner than Proxmox's
  privileged-LXC `/dev/dri` share. Not camera-only: **den holds one today** and the future camera
  container will share it across Frigate + Scrypted. See "The iGPU is shared" above for why nothing
  here can enforce who wins, and why the device `gid` is looked up rather than pinned.
- CX820 main is H.265 (recorded raw); only the HomeKit path transcodes, on the iGPU.
- Doorbell is the **Reolink PoE Video Doorbell** (2K, 4:3) — keep its main H.264 if possible (HomeKit-friendly, no transcode).
- Scrypted camera setup and HomeKit pairing are manual (not automated).
- Remote access: **Tailscale** on the host (`--ssh`) — SSH from your phone, no ports/keys. (`ansible/roles/tailscale`)
- Home Assistant config-as-code under `homeassistant/` (Matter + Frigate cameras; no Zigbee). Most of it is code; Matter pairing + add-on install stay in the UI.
- Backups: the `restic_backup` role ships HA state → **Cloudflare R2** (S3-compatible); `incus export` → NVMe (local, the vzdump replacement). Each app container backs up its own data offsite from its own repo. Footage and Scrypted pairings are not backed up.
