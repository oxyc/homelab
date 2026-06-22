#!/usr/bin/env bash
# Pre-deploy guard: scan your REAL (gitignored) config for unfilled placeholders so none
# slip through. Run after filling docker/.env, group_vars/all.yml, inventory.yml.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

pat='changeme|192\.168\.x\.x|tskey-auth-x|ACCOUNT_ID|example\.com|r2_access_key|r2_secret_key|cf_dns_token|replace-with|xxxxxxxx|<your|<FILL'
found=0

echo "▶ scanning your filled config for leftover placeholders"
for f in docker/.env ansible/group_vars/all.yml ansible/inventory.yml; do
  if [ ! -f "$f" ]; then
    echo "  • $f — not created yet (copy it from the .example)"
    continue
  fi
  if grep -HnEi "$pat" "$f"; then
    found=1
  else
    echo "  ✓ $f"
  fi
done

echo "  i  tailscale/acl.hujson stays a template — swap you@example.com + the CIDR when you paste it into Tailscale"
echo
if [ "$found" = 0 ]; then
  echo "✅ no leftover placeholders — safe to deploy"
else
  echo "❌ fill the values listed above before deploying"
fi
exit "$found"
