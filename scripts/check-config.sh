#!/usr/bin/env bash
# Pre-deploy gate (run automatically by `make deploy`): required files + keys present, no
# placeholders, values sane, cross-file consistency, and the Proxmox answer complete.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
fail=0
ph='changeme|192\.168\.x\.x|tskey-auth-x|ACCOUNT_ID|example\.com|r2_access_key|r2_secret_key|cf_dns_token|replace-with|xxxxxxxx|<your|CHANGE_ME'
bad() { echo "  ✗ $*"; fail=1; }
# read KEY's value from an env file (strip inline comment, quotes, surrounding whitespace)
getenv() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- \
  | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//'; }

echo "▶ required files (copy from the .example)"
for pair in \
  "docker/.env.example=docker/.env" \
  "ansible/group_vars/all.example.yml=ansible/group_vars/all.yml" \
  "ansible/inventory.example.yml=ansible/inventory.yml"; do
  ex="${pair%%=*}"; real="${pair##*=}"
  if [ -f "$real" ]; then echo "  ✓ $real"; else bad "MISSING $real   (cp $ex $real)"; fi
done

echo "▶ required keys present"
if [ -f docker/.env ]; then
  while IFS= read -r k; do grep -qE "^$k=" docker/.env || bad ".env missing key: $k"; done \
    < <(grep -hE "^[A-Z_]+=.*($ph)" docker/.env.example | grep -oE '^[A-Z_]+')
fi
if [ -f ansible/group_vars/all.yml ]; then
  while IFS= read -r k; do grep -qE "^$k:" ansible/group_vars/all.yml || bad "all.yml missing var: $k"; done \
    < <(grep -oE '^[a-z_]+:' ansible/group_vars/all.example.yml | tr -d ':')
fi
if [ -f ansible/inventory.yml ]; then
  for v in nvr_disk_device docker_ctid docker_lxc_ip docker_lxc_gw haos_vmid; do
    grep -qE "$v" ansible/inventory.yml || bad "inventory.yml missing: $v"
  done
fi

echo "▶ no leftover placeholders"
for f in docker/.env ansible/group_vars/all.yml ansible/inventory.yml; do
  [ -f "$f" ] || continue
  grep -HnEi "$ph" "$f" && fail=1
done

echo "▶ value sanity"
if [ -f docker/.env ]; then
  # shellcheck source=/dev/null
  if ! ( set -a; . docker/.env ) >/dev/null 2>&1; then
    bad ".env doesn't source cleanly — a value has spaces/\$/backticks (use hex: openssl rand -hex 24)"
  fi
  cp=$(getenv FRIGATE_CAM_PASS docker/.env)
  if [ -n "$cp" ] && [ "$cp" != "changeme" ] && ! printf '%s' "$cp" | grep -qE '^[A-Za-z0-9]+$'; then
    bad "FRIGATE_CAM_PASS must be alphanumeric only (Reolink RTMP bug)"
  fi
  ae=$(getenv ACME_EMAIL docker/.env)
  case "$ae" in "" | *@*.*) : ;; *) bad "ACME_EMAIL doesn't look like an email: $ae" ;; esac
fi

echo "▶ cross-file consistency"
if [ -f docker/.env ] && [ -f ansible/group_vars/all.yml ]; then
  he=$(getenv HAOS_IP docker/.env); hm=$(getenv FRIGATE_MQTT_HOST docker/.env)
  hg=$(grep -E '^haos_ip:' ansible/group_vars/all.yml | sed -E 's/^haos_ip:[[:space:]]*//; s/[[:space:]]*#.*//; s/"//g')
  if [ -n "$he" ] && ! printf '%s' "$he" | grep -q 'x\.x'; then
    [ "$he" = "$hm" ] || bad "HAOS_IP ($he) != FRIGATE_MQTT_HOST ($hm) — both are the HA VM"
    [ "$he" = "$hg" ] || bad "HAOS_IP ($he, .env) != haos_ip ($hg, group_vars) — keep them equal"
  fi
fi

echo "▶ proxmox unattended answer (only if you use it)"
if [ -f proxmox/answer.toml ]; then
  for kv in 'root_password|root_password_hashed' mailto fqdn; do
    grep -qE "^[[:space:]]*($kv)" proxmox/answer.toml || bad "answer.toml missing: $kv"
  done
  if grep -vE '^[[:space:]]*#' proxmox/answer.toml | grep -qiE 'CHANGE_ME|changeme'; then
    bad "answer.toml still has a placeholder (on a non-comment line)"
  fi
else
  echo "  • manual install (no answer.toml) — skip"
fi

echo "  i  tailscale/acl.hujson stays a template — swap you@example.com + CIDR when pasting into Tailscale"
echo
if [ "$fail" = 0 ]; then echo "✅ config complete — safe to deploy"; else echo "❌ fix the above before deploying"; fi
exit "$fail"
