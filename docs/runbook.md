# Runbook — rebuild & recovery

## Full rebuild (SSD died / new box)
1. BIOS prep ([bios.md](bios.md)).
2. Install Proxmox to the 512GB SSD (USB installer or `proxmox/answer.toml`).
3. `git clone <this repo>` on your workstation.
4. Secrets: `bw get notes homelab-env > docker/.env` (Bitwarden).
5. `cd ansible && cp inventory.example.yml inventory.yml` and fill in.
6. `ansible-galaxy collection install -r requirements.yml`
7. `ansible-playbook site.yml --check --diff` then for real, by tag: `host` → `haos` → `docker` → `backup`.
8. **Home Assistant**: in the HAOS VM, restore the latest backup from B2/restic (or HA's restore-from-backup at onboarding).
9. **Scrypted (manual)**: add CX820 + doorbell (Reolink plugin; doorbell → tick Doorbell), enable Rebroadcast/HomeKit/HKSV.
10. **HomeKit (manual)**: pair both (accessory mode), enable HKSV, verify a motion clip records.

## Restore just Home Assistant
```bash
# on the docker LXC where restic runs
restic snapshots --tag ha
restic restore <id> --target /restore
# copy the .tar to HA and restore via Settings → System → Backups
```

## What is NOT recoverable from backup (by design)
- **Scrypted HomeKit pairings** → re-pair (~20 min for 2 devices).
- **Footage** → disposable.

## Local fast restore (SSD died, NVMe survived)
Proxmox `vzdump`s live on the 2TB NVMe (`nvr` storage). After reinstalling PVE, restore the LXC/VM from there instead of rebuilding — faster than the full path above.

## Routine checks
- Scrypted transcode uses `h264_vaapi`/`qsv` (not software x264) — check logs / `intel_gpu_top`.
- restic timer green: `systemctl status restic-backup.timer`.
- Don't auto-update Scrypted blindly (Jan–May 2026 Reolink regressions). Update deliberately, keep `reolink ≥ 0.0.111`.
