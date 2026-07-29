#!/bin/sh
# Keep the mounted den-atlas dataset in sync with the published den-dataset `data-latest` release.
# The atlas image is server-only (blobs are gitignored + shipped as a GitHub Release), so this polls
# the release and swaps the mounted data dir when it changes, then restarts atlas (it reads the
# dataset at boot). Runs on the LXC host (docker + the mount live there) via a systemd timer.
# Idempotent: a no-op when already current.
#
# HARDENED (2026-07): the trigger is now "the release meta differs from what's on disk in ANY way" —
# not just a bumped datasetVersion. New artifacts (the poster metadata sidecar, then the premise
# index) were both ADDED under an UNCHANGED datasetVersion, and the old version-only gate skipped
# them, stranding the homelab. It also fetches EVERY "<name>File" the meta declares (labels, gz,
# vectors, metadata, premise, and anything future), verifying each against its "<name>Sha256". So a
# new dataset artifact goes live on the next tick with no edit here — that recurring "homelab didn't
# pick up the new files" bug can't recur. (Contract: the producer MAY add files without bumping
# datasetVersion; this copes either way.)
#
# Config via env:
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
# Every key that names a data file (ends in "File"): labelsFile, labelsGzFile, premiseVectorsFile, ...
jfilekeys() { grep -oE "\"[A-Za-z0-9]+File\"" | tr -d '"' | sort -u; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/dataset.meta.json" -o "$TMP/dataset.meta.json"
NEW_VER="$(jval datasetVersion < "$TMP/dataset.meta.json")"
[ -n "$NEW_VER" ] || { echo "atlas-sync: no datasetVersion in release meta" >&2; exit 1; }

# Content-aware gate: identical meta => already current. cmp catches added files / changed shas even
# when datasetVersion is unchanged — the exact failure that stranded the sidecar and premise indexes.
if [ -s "$DATA_DIR/dataset.meta.json" ] && cmp -s "$TMP/dataset.meta.json" "$DATA_DIR/dataset.meta.json"; then
  exit 0
fi
CUR_VER="$( ([ -s "$DATA_DIR/dataset.meta.json" ] && jval datasetVersion < "$DATA_DIR/dataset.meta.json") || echo none )"
echo "atlas-sync: dataset meta changed (${CUR_VER} -> ${NEW_VER}), refreshing"

# Fetch every declared file + sha-verify each (a file may legitimately carry no sha, e.g. the gz — skip).
FETCHED=""
for key in $(jfilekeys < "$TMP/dataset.meta.json"); do
  f="$(jval "$key" < "$TMP/dataset.meta.json")"
  [ -n "$f" ] || continue
  curl -fsSL "$BASE/$f" -o "$TMP/$f"
  want="$(jval "${key%File}Sha256" < "$TMP/dataset.meta.json" || true)"
  if [ -n "$want" ]; then
    echo "$want  $TMP/$f" | sha256sum -c - >/dev/null
  fi
  FETCHED="$FETCHED $f"
done

mkdir -p "$DATA_DIR"
# Remove exactly the previously-laid set (read from the OLD meta) so renamed/removed artifacts across a
# taxonomy/model change don't linger — fully generic, no filename globs to keep in sync.
if [ -s "$DATA_DIR/dataset.meta.json" ]; then
  for k in $(jfilekeys < "$DATA_DIR/dataset.meta.json"); do
    of="$(jval "$k" < "$DATA_DIR/dataset.meta.json")"
    [ -n "$of" ] && rm -f "$DATA_DIR/$of"
  done
fi
rm -f "$DATA_DIR/dataset.meta.json"

for f in $FETCHED; do mv -f "$TMP/$f" "$DATA_DIR/$f"; done
mv -f "$TMP/dataset.meta.json" "$DATA_DIR/dataset.meta.json"
docker restart "$CONTAINER" >/dev/null 2>&1 || echo "atlas-sync: warn — could not restart $CONTAINER" >&2
echo "atlas-sync: refreshed to $NEW_VER ($(echo "$FETCHED" | wc -w) files) and restarted $CONTAINER"
