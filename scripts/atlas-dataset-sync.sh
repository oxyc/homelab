#!/bin/sh
# Keep the mounted den-atlas dataset in sync with the published den-dataset `data-latest` release.
# The atlas image is server-only (blobs are gitignored + shipped as a GitHub Release), so this polls
# the release, and when its datasetVersion changes it downloads + sha256-verifies the blobs, swaps
# them into the mounted data dir, and restarts atlas (the Rust server reads the dataset at boot).
#
# Runs on the LXC host (where docker + the mount live) via a systemd timer. Idempotent: a no-op when
# already current. Config via env:
#   ATLAS_DATA_DIR   dir bind-mounted into atlas at /app/data   (default /opt/atlas-data)
#   ATLAS_CONTAINER  container to restart after a refresh        (default atlas)
#   DEN_DATASET_REPO source release repo                         (default oxyc/den-dataset)
set -eu

REPO="${DEN_DATASET_REPO:-oxyc/den-dataset}"
BASE="https://github.com/$REPO/releases/download/data-latest"
DATA_DIR="${ATLAS_DATA_DIR:-/opt/atlas-data}"
CONTAINER="${ATLAS_CONTAINER:-atlas}"

# Minimal JSON string-field read (no jq/python dep on the host).
jval() { grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*"\([^"]*\)"$/\1/'; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/dataset.meta.json" -o "$TMP/dataset.meta.json"
NEW_VER="$(jval datasetVersion < "$TMP/dataset.meta.json")"
[ -n "$NEW_VER" ] || { echo "atlas-sync: no datasetVersion in release meta" >&2; exit 1; }
CUR_VER=""
[ -f "$DATA_DIR/dataset.meta.json" ] && CUR_VER="$(jval datasetVersion < "$DATA_DIR/dataset.meta.json")" || true
[ "$NEW_VER" = "$CUR_VER" ] && exit 0   # already current

echo "atlas-sync: dataset ${CUR_VER:-none} -> $NEW_VER, refreshing"
LABELS="$(jval labelsFile < "$TMP/dataset.meta.json")"
VECTORS="$(jval vectorsFile < "$TMP/dataset.meta.json")"
GZ="$(jval labelsGzFile < "$TMP/dataset.meta.json" || true)"
for f in "$LABELS" "$VECTORS" ${GZ:+$GZ}; do curl -fsSL "$BASE/$f" -o "$TMP/$f"; done

# sha256-verify what the meta pins (guards a truncated/tampered download before we swap).
echo "$(jval labelsSha256  < "$TMP/dataset.meta.json")  $TMP/$LABELS"  | sha256sum -c - >/dev/null
echo "$(jval vectorsSha256 < "$TMP/dataset.meta.json")  $TMP/$VECTORS" | sha256sum -c - >/dev/null

mkdir -p "$DATA_DIR"
for f in dataset.meta.json "$LABELS" "$VECTORS" ${GZ:+$GZ}; do mv -f "$TMP/$f" "$DATA_DIR/$f"; done
docker restart "$CONTAINER" >/dev/null 2>&1 || echo "atlas-sync: warn — could not restart $CONTAINER" >&2
echo "atlas-sync: refreshed to $NEW_VER and restarted $CONTAINER"
