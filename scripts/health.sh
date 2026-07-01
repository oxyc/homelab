#!/usr/bin/env bash
# One-shot health sweep for the headless Proxmox host: memory, disks, SMART/NVMe wear +
# temperature, PVE storage, failed units, Tailscale, recent journal errors.
#
# Host resolution (first hit wins): $HOST env → ansible_host in ansible/inventory.yml → `pve`
# (Tailscale MagicDNS). Override user with $SSH_USER (default root — uses the key, so it
# avoids the Tailscale-SSH browser check that intercepts port 22 on the tailnet IP).
#
#   make health                 # uses inventory / pve
#   HOST=192.168.1.50 make health
set -euo pipefail

HOST="${HOST:-}"
if [ -z "$HOST" ] && [ -f ansible/inventory.yml ]; then
  HOST="$(awk -F'[:#]' '/ansible_host/{gsub(/[ \t]/,"",$2); print $2; exit}' ansible/inventory.yml || true)"
fi
HOST="${HOST:-pve}"
SSH_USER="${SSH_USER:-root}"
echo "→ health check: ${SSH_USER}@${HOST}"

ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "${SSH_USER}@${HOST}" 'bash -s' <<'REMOTE'
set -u
echo "===== HOST / UPTIME ====="; hostname; uptime
echo; echo "===== MEMORY ====="; free -h
echo; echo "===== DISK USAGE ====="; df -h -x tmpfs -x devtmpfs | grep -vE 'overlay|shm'
echo; echo "===== nvr MOUNT ====="; findmnt /mnt/nvr 2>/dev/null || echo "(nvr not mounted)"
echo; echo "===== PVE STORAGE ====="; pvesm status 2>/dev/null || echo "(pvesm n/a)"
echo; echo "===== SMART HEALTH ====="
for d in /dev/nvme?n1 /dev/sd?; do [ -b "$d" ] || continue
  echo "--- $d ---"; smartctl -H "$d" 2>/dev/null | grep -iE 'result|health' || echo "  (no smartctl)"; done
echo; echo "===== NVMe WEAR / TEMP ====="
for d in /dev/nvme?n1; do [ -b "$d" ] || continue; echo "--- $d ---"
  smartctl -A "$d" 2>/dev/null | grep -iE 'Percentage Used|Available Spare|Temperature:|Data Units Written'; done
echo; echo "===== CPU TEMP ====="
sensors 2>/dev/null | grep -iE 'Package|Composite' \
  || awk '{printf "  zone: %.1f C\n",$1/1000}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
  || echo "(no temp source)"
echo; echo "===== TOP MEM PROCS ====="; ps -eo pmem,pcpu,comm --sort=-pmem | head -6
echo; echo "===== FAILED UNITS ====="; systemctl --failed --no-legend --no-pager || true
echo; echo "===== MAINT TIMERS ====="; systemctl is-active fstrim.timer smartd 2>/dev/null || true
echo; echo "===== TAILSCALE ====="; tailscale status 2>/dev/null | head -4 || echo "(tailscale n/a)"
echo; echo "===== RECENT ERRORS (this boot) ====="; journalctl -p err -b --no-pager 2>/dev/null | tail -8 || echo "(none)"
REMOTE
