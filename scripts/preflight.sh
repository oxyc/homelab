#!/usr/bin/env bash
# One-shot local validation before touching hardware. Needs docker; no local installs.
# Mirrors the GitHub Actions CI plus caddy + the toggle test.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1
fail=0

echo "▶ yamllint + ansible-lint + ansible syntax-check"
docker run --rm -v "$PWD":/w -w /w python:3.12-slim sh -lc '
  pip -q install yamllint ansible-lint ansible >/dev/null 2>&1
  yamllint -c .yamllint . &&
  cd ansible &&
  ansible-galaxy collection install -r requirements.yml >/dev/null 2>&1 &&
  ansible-lint &&
  cp inventory.example.yml inventory.yml &&
  ansible-playbook site.yml --syntax-check
' && echo "  ✓ lint + syntax" || fail=1

echo "▶ docker compose config (default + homekit)"
( cd docker && cp ../.env.example .env \
  && docker compose config -q \
  && docker compose --profile homekit config -q \
  && rm -f .env ) && echo "  ✓ compose" || fail=1

echo "▶ caddy validate (wildcard DNS-01)"
docker build -q -t homelab-caddy:2 docker/caddy >/dev/null 2>&1 \
&& docker run --rm -v "$PWD/docker/caddy/Caddyfile":/Caddyfile:ro \
   -e CADDY_LOCAL_DOMAIN=h.example.com -e ACME_EMAIL=you@example.com \
   -e CLOUDFLARE_API_TOKEN=0123456789abcdef0123456789abcdef01234567 \
   -e HAOS_IP=10.0.0.1 -e PROXMOX_IP=10.0.0.2 -e SCRYPTED_HOST=10.0.0.3 \
   homelab-caddy:2 caddy validate --adapter caddyfile --config /Caddyfile >/dev/null 2>&1 \
&& echo "  ✓ caddy" || fail=1

echo "▶ homekit toggle"
./scripts/test-toggle.sh >/dev/null 2>&1 && echo "  ✓ toggle" || fail=1

echo "▶ gitleaks (secret scan, full history)"
docker run --rm -v "$PWD":/repo zricethezav/gitleaks:latest detect --source=/repo --no-banner >/dev/null 2>&1 \
  && echo "  ✓ gitleaks" || fail=1

echo "▶ shellcheck"
docker run --rm -v "$PWD":/mnt koalaman/shellcheck:stable scripts/*.sh .githooks/pre-commit >/dev/null 2>&1 \
  && echo "  ✓ shellcheck" || fail=1

echo
[ "$fail" = 0 ] && echo "✅ preflight passed" || echo "❌ preflight failed"
exit "$fail"
