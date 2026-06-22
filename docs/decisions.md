# Decision log

Why the setup is the way it is. Each entry: decision → reasoning → status.

## D1 — Scrypted owns HomeKit for *both* devices (not go2rtc/Frigate)
HomeKit live **and** HKSV require H.264; Frigate's bundled go2rtc can only export a **live** HomeKit tile (no HKSV recording), and the **doorbell ring event + two-way audio are not in the video stream** — they require Scrypted talking directly to the device. go2rtc native HKSV exists only as an unmerged PR (#2130, skrashevich) and is enthusiast-grade. So Scrypted is the HomeKit/HKSV endpoint for both the CX820 and the doorbell. **Status: firm.**

## D2 — Frigate records native H.265; transcode is isolated to the HomeKit path
The CX820 main stream is **H.265-only**. Frigate is a pure NVR — it stores H.265 raw (`-c copy`), no transcode, full 4K, near-zero CPU. The only consumer that forces H.264 is HomeKit, so the H.265→H.264 transcode happens **once, in Scrypted, on the iGPU**. "Reolink 4K is bad with Scrypted" is really "HomeKit forced a transcode" — bounded and hardware-mitigated, not a mystery. **Status: firm.**

## D3 — Scrypted-first does NOT decode before Frigate
Scrypted's Rebroadcast is a **passthrough** restreamer (one camera connection, fanned out, codec preserved). Transcoding is opt-in per-consumer ("Synthetic Streams"). Frigate pulls the H.265 main rebroadcast untouched; the HomeKit transcode is a separate stream off the same source. Hub order changes *who holds the connection* and *dependency*, not codecs. **Status: firm.**

## D4 — Docker-in-one-LXC, not separate LXCs or VMs
Both Frigate and Scrypted need QuickSync. A VM grabs the iGPU via PCIe passthrough **exclusively (one VM)**. Containers sharing `/dev/dri` can all use it. So: one privileged **Docker LXC** runs Frigate + Scrypted + Caddy via Compose (declarative, shares the iGPU). HA stays a separate **HAOS VM** (doesn't need the iGPU; HAOS is the supported HA deployment). **Status: firm.**

## D5 — ext4, not ZFS
ZFS ARC would eat 4–8GB — the main reason 16GB would feel tight. ext4 keeps the host lean and avoids write-amplification on the NVR disk (24/7 4K writes). **Status: firm.** Consequence: **16GB RAM is enough** for this 2-camera stack (~8–10GB used). 32GB only when expanding.

## D6 — Remote access: WireGuard on the ER707-M2 (not Tailscale)
Antel provides a public dynamic IP, and the Omada gateway has a **built-in WireGuard server** → self-hosted, terminates at the gateway, scoped by Omada ACLs, no third-party control plane, no extra container. Covers SSH + web UIs + HA. Tailscale only as a fallback if a CGNAT check fails. HomeKit needs neither (Apple Home Hub handles remote). **Status: firm (pending CGNAT check).**

## D7 — DNS filtering optional; NextDNS over self-hosted AdGuard
Not required. If wanted, NextDNS (hosted, zero-maintenance, protects devices off-network) beats self-hosting AdGuard, which makes the whole network's DNS depend on a box being up. Local hostnames come from Omada's DNS, not AdGuard. **Status: optional.**

## D8 — Secrets externalized → public repo is safe
`{FRIGATE_*}` / `!secret` / `{env.*}` / `${VAR}` keep all secrets out of committed files; real values live in a **Bitwarden secure note** pulled at deploy time. Avoids private repos and ansible-vault. **Status: firm.**

## D9 — Backups: restic → Backblaze B2 (not Google Drive)
Once committed to IaC tooling, a programmatic **S3-compatible** target fits better than a consumer Drive add-on, and B2 becomes the *single* offsite (HA state + optionally secrets/vzdump). **restic** gives client-side encryption + dedup + scoped app key (B2 sees only ciphertext — addresses the "secrets in cloud" worry). ~free at this size (10GB free tier). Google Drive add-on only wins on pure turnkey-ness, which we've moved past. **Status: firm.** Scrypted pairing state deliberately **not** backed up (re-pair on disaster).

## D10 — Provisioning: Ansible (+ Docker Compose), ~85% automatable
Ansible creates host config + HAOS VM + Docker LXC and deploys the compose stack; reusable for the future dev box. Not automatable: BIOS, Proxmox ISO boot, **Scrypted config**, **HomeKit pairing** — documented as manual. Testable pre-hardware via lint → laptop `compose up` → Molecule → nested Proxmox → `--check`. **Status: firm.**
