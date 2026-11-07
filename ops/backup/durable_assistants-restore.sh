#!/usr/bin/env bash
# Prove a deployment's snapshot restores. Copies the staged databases into a
# scratch directory, never touching the snapshot or any live database, then
# checks each with `PRAGMA integrity_check`, reads every table of the record,
# and unpacks storage.tar there to check every Active Storage blob the record
# names has its file.
#
# usage: durable_assistants-restore.sh [SNAPSHOT_DIR [SCRATCH_DIR]]
#   SNAPSHOT_DIR  defaults to /data/docker/<BACKUP_SERVICE>-backup/backups (the
#                 borgmatic stage dir, or a directory extracted from an archive)
#   SCRATCH_DIR   defaults to a fresh temp directory, removed afterwards. A
#                 directory you name is kept, so you can open the restored files.
#
# Exit status is 0 only if the primary database restored, passed
# integrity_check, carries its migrations, can be read table by table, and every
# blob it names came back as a file. A fresh production database has empty
# tables, so emptiness is reported, not failed: the failures worth stopping for
# are a database that will not open, tables that are gone, or a file the record
# points at and the backup does not have.
#
# To put a snapshot live: stop both Kamal roles, copy the verified files over
# storage/ on the <service>_storage volume together, and boot again.
set -euo pipefail
umask 077

SERVICE="${BACKUP_SERVICE:-durable_assistants}"
SNAPSHOT_DIR="${1:-${BACKUP_STAGE_DIR:-/data/docker/${SERVICE}-backup}/backups}"
SCRATCH_DIR="${2:-}"
DATABASES=(production production_cache production_queue production_cable)

fail() { echo "${SERVICE}-restore: $*" >&2; exit 1; }

[ -d "$SNAPSHOT_DIR" ] || fail "$SNAPSHOT_DIR is not a directory"
[ -s "$SNAPSHOT_DIR/production.sqlite3" ] || fail "$SNAPSHOT_DIR has no production.sqlite3"

if [ -z "$SCRATCH_DIR" ]; then
  SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${SERVICE}-restore.XXXXXX")
  trap 'rm -rf "$SCRATCH_DIR"' EXIT
else
  mkdir -p "$SCRATCH_DIR"
fi

for db in "${DATABASES[@]}"; do
  source="$SNAPSHOT_DIR/$db.sqlite3"
  if [ ! -s "$source" ]; then
    # The record is mandatory; a missing rebuildable database is a warning
    # because Rails recreates it on boot.
    echo "warning: $db.sqlite3 is not in the snapshot"
    continue
  fi
  restored="$SCRATCH_DIR/$db.sqlite3"
  cp -- "$source" "$restored"

  result=$(sqlite3 "$restored" "PRAGMA integrity_check") || fail "$db.sqlite3 will not open"
  [ "$result" = "ok" ] || fail "$db.sqlite3 integrity_check: $result"
  echo "$db.sqlite3: integrity_check ok"
done

# The record. schema_migrations proves the schema came back; reading every
# table proves the data did. Reading the tables the snapshot itself lists means
# there is no list here to forget to update when a model is added.
migrations=$(sqlite3 "$SCRATCH_DIR/production.sqlite3" "SELECT count(*) FROM schema_migrations") \
  || fail "production.sqlite3 has no schema_migrations"
[ "$migrations" -gt 0 ] || fail "production.sqlite3 has no migrations recorded"
echo "production.sqlite3: $migrations migrations"

tables=$(sqlite3 "$SCRATCH_DIR/production.sqlite3" \
  "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") \
  || fail "production.sqlite3: cannot list tables"
for table in $tables; do
  count=$(sqlite3 "$SCRATCH_DIR/production.sqlite3" "SELECT count(*) FROM \"$table\"") \
    || fail "production.sqlite3: cannot read $table"
  echo "production.sqlite3: $table: $count"
done

# Active Storage's Disk service keeps a blob at <root>/<k[0,2]>/<k[2,2]>/<key>.
mkdir -p "$SCRATCH_DIR/storage"
if [ -s "$SNAPSHOT_DIR/storage.tar" ]; then
  tar -C "$SCRATCH_DIR/storage" -xf "$SNAPSHOT_DIR/storage.tar" || fail "storage.tar will not unpack"
fi
if sqlite3 "$SCRATCH_DIR/production.sqlite3" "SELECT 1 FROM sqlite_master WHERE name = 'active_storage_blobs'" | grep -q 1; then
  keys=$(sqlite3 "$SCRATCH_DIR/production.sqlite3" "SELECT key FROM active_storage_blobs WHERE service_name = 'local'") \
    || fail "production.sqlite3: cannot read active_storage_blobs"
  blobs=0 missing=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    blobs=$((blobs + 1))
    if [ ! -f "$SCRATCH_DIR/storage/${key:0:2}/${key:2:2}/$key" ]; then
      missing=$((missing + 1))
      [ "$missing" -le 5 ] && echo "missing file for blob $key" >&2
    fi
  done <<<"$keys"
  [ "$missing" -eq 0 ] || fail "$missing of $blobs Active Storage blobs have no file in storage.tar"
  echo "storage.tar: $blobs blobs, every file present"
fi

# The Pi Durable sidecar's store: present, complete (its manifest is written
# last), the bytes the manifest names, and a database that passes
# integrity_check. Copied, never opened in place.
agent_store="$SNAPSHOT_DIR/agent-durable.sqlite"
[ -s "$agent_store" ] || fail "$SNAPSHOT_DIR has no agent-durable.sqlite"
[ -s "$agent_store.manifest.json" ] || fail "agent-durable.sqlite has no manifest; the snapshot is incomplete"
expected=$(sed -n 's/.*"sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$agent_store.manifest.json")
cp -- "$agent_store" "$SCRATCH_DIR/agent-durable.sqlite"
actual=$(sha256sum "$SCRATCH_DIR/agent-durable.sqlite" | cut -d' ' -f1)
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "agent-durable.sqlite does not match its manifest"
result=$(sqlite3 "$SCRATCH_DIR/agent-durable.sqlite" "PRAGMA integrity_check") || fail "agent-durable.sqlite will not open"
[ "$result" = "ok" ] || fail "agent-durable.sqlite integrity_check: $result"
echo "agent-durable.sqlite: manifest sha256 and integrity_check ok"

echo "restore ok: $SNAPSHOT_DIR -> $SCRATCH_DIR"
