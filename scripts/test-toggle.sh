#!/usr/bin/env bash
# Proves the HomeKit toggle at the compose level (what the ansible role wires):
#   default      => frigate + caddy
#   --profile homekit => frigate + caddy + scrypted
# Runs anywhere with docker; no ansible needed.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)/docker" || exit 1
tmp=0; [ -f .env ] || { cp ../.env.example .env; tmp=1; }
cleanup() { [ "$tmp" = 1 ] && rm -f .env; }
trap cleanup EXIT

def=$(docker compose config --services | sort | tr '\n' ' ')
hk=$(docker compose --profile homekit config --services | sort | tr '\n' ' ')

echo "default profile : $def"
echo "homekit profile : $hk"

[ "$def" = "caddy frigate " ] || { echo "✘ default should be 'caddy frigate'"; exit 1; }
echo "$hk" | grep -q scrypted   || { echo "✘ homekit profile must include scrypted"; exit 1; }
echo "✔ toggle verified: scrypted is off by default, on with --profile homekit"
