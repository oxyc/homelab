#!/usr/bin/env bash
# Pre-deploy gate: required files exist, required .env keys are present, no placeholders
# remain, and the Proxmox unattended answer (if used) has root pw + email + fqdn.
# Run before `make deploy`.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
fail=0
ph='changeme|192\.168\.x\.x|tskey-auth-x|ACCOUNT_ID|example\.com|r2_access_key|r2_secret_key|cf_dns_token|replace-with|xxxxxxxx|<your|CHANGE_ME'

echo "▶ required files (copy from the .example)"
for pair in \
  "docker/.env.example=docker/.env" \
  "ansible/group_vars/all.example.yml=ansible/group_vars/all.yml" \
  "ansible/inventory.example.yml=ansible/inventory.yml"; do
  ex="${pair%%=*}"; real="${pair##*=}"
  if [ -f "$real" ]; then echo "  ✓ $real"; else echo "  ✗ MISSING $real   (cp $ex $real)"; fail=1; fi
done

if [ -f docker/.env ]; then
  echo "▶ required .env keys present (those still placeholder in the example)"
  while IFS= read -r k; do
    grep -qE "^${k}=" docker/.env || { echo "  ✗ .env missing key: $k"; fail=1; }
  done < <(grep -hE "^[A-Z_]+=.*(${ph})" docker/.env.example | grep -oE '^[A-Z_]+')
fi

echo "▶ no leftover placeholders"
for f in docker/.env ansible/group_vars/all.yml ansible/inventory.yml; do
  [ -f "$f" ] || continue
  grep -HnEi "$ph" "$f" && fail=1
done

echo "▶ proxmox unattended answer (only if you use it)"
if [ -f proxmox/answer.toml ]; then
  for kv in 'root_password|root_password_hashed' mailto fqdn; do
    grep -qE "^[[:space:]]*(${kv})" proxmox/answer.toml || { echo "  ✗ answer.toml missing: ${kv}"; fail=1; }
  done
  grep -qiE 'CHANGE_ME|changeme' proxmox/answer.toml && { echo "  ✗ answer.toml still has a placeholder"; fail=1; }
else
  echo "  • manual install (no answer.toml) — skip"
fi

echo "  i  tailscale/acl.hujson stays a template — swap you@example.com + CIDR when pasting into Tailscale"
echo
if [ "$fail" = 0 ]; then echo "✅ config complete — safe to deploy"; else echo "❌ fix the above before deploying"; fi
exit "$fail"
