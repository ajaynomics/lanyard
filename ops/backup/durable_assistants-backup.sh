#!/usr/bin/env bash
# Nightly backup of one deployment, run on its host by a systemd timer
# (ops/backup/systemd). BACKUP_SERVICE is the deployment's Kamal service name
# (config/deploy.yml, or the destination's own `service:`); the volume,
# containers and stage directory are named after it.
#
# Why this exists: the production data is SQLite databases on the
# `<service>_storage` Docker volume. Copying a live SQLite file is not a valid
# backup (mid-transaction pages, separate -wal), so sqlite3's `.backup` takes a
# consistent snapshot INSIDE the running web container, the snapshot is
# integrity-checked there, and it is published into STAGE_DIR, which the host's
# borgmatic archives. Live *.sqlite3* files are never staged.
#
# All four databases are snapshotted. Only `production` is the record; cache
# and cable are rebuildable and queue holds pending jobs that are re-enqueued
# by their callers. They are included anyway because
# each is under a megabyte, a restored app then boots without recreating them,
# and "which databases matter" is a decision this script should not make again
# every time a table moves between them. The restore script checks the record
# harder than the rest.
#
# Active Storage's files (uploads, under storage/ beside the
# databases) are not rows, so they travel as storage.tar, a tarball of the
# volume without the databases. It is taken after the snapshots: a blob row is
# saved only once its file is written, so every file the snapshot names was on
# disk before the tarball began. A file still being written as tar reads it
# (tar exit 1) belongs to a row the snapshot cannot name yet, and is harmless.
#
# Publishing is a rename, so borgmatic, which reads STAGE_DIR on its own
# schedule and takes no lock against this script, never archives a half-written
# file. Scratch names live INSIDE STAGE_DIR (the backup user holds only --x on
# /data/docker and cannot create siblings there) and borgmatic excludes the
# .incoming.* names. Nothing is published unless every snapshot passed.
#
# A pull from another host (a host whose borgmatic cannot reach this one)
# depends on this layout: STAGE_DIR/backups/*.sqlite3,
# STAGE_DIR/backups/storage.tar and STAGE_DIR/LAST_STAGED_AT.
set -euo pipefail
umask 077

SERVICE="${BACKUP_SERVICE:-durable_assistants}"
STAGE_DIR="${BACKUP_STAGE_DIR:-/data/docker/${SERVICE}-backup}"
LOG="${BACKUP_LOG:-/var/log/${SERVICE}-backup.log}"
WEB_FILTER="${BACKUP_WEB_FILTER:-^${SERVICE}-web}"
AGENT_FILTER="${BACKUP_AGENT_FILTER:-^${SERVICE}-agent}"
STORAGE=/rails/storage
# config/database.yml's production databases, primary first. test/standards_test.rb
# (S11) fails if one is added there and not here.
DATABASES=(production production_cache production_queue production_cable)

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
note() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }
fail() { note "FAIL $*"; echo "${SERVICE}-backup: $*" >&2; exit 1; }

# Name is <service>-web-<destination>-<sha>; the job role has its own prefix.
web=$(docker ps --filter "name=$WEB_FILTER" --format '{{.Names}}' | head -1)
[ -n "$web" ] || fail "no running ${SERVICE}-web container; nothing backed up"

# Runs inside the container. The snapshot is removed first so a stale one can
# never pass for today's, and the check reads the snapshot, not the source:
# the question is whether the copy restores.
# shellcheck disable=SC2016 # expands inside the container, not here
snapshot='
  set -e
  source=$1; target=$2
  rm -f "$target" "$target-wal" "$target-shm"
  sqlite3 "$source" ".backup \"$target\""
  result=$(sqlite3 "$target" "PRAGMA integrity_check")
  [ "$result" = "ok" ] || { echo "integrity_check: $result" >&2; exit 1; }
'

docker exec "$web" mkdir -p "$STORAGE/backups" || fail "$web: could not create $STORAGE/backups"

# The Pi Durable sidecar (docs/agent.md). Its store's ownership lock refuses
# a snapshot while the sidecar runs, so the sidecar is stopped for the
# snapshots -- its own and the Rails databases', which then come from one
# point in time -- and started again on every path out of this script. Kamal's
# restart policy never starts a container stopped by hand, so a sidecar that
# does not start again fails the run even when the backup itself is good.
agent=$(docker ps --filter "name=$AGENT_FILTER" --format '{{.Names}}' | head -1)
[ -n "$agent" ] || fail "no running ${SERVICE}-agent container; nothing backed up"
not_restarted=
restart_agent() {
  [ -n "${agent:-}" ] || return 0
  if ! docker start "$agent" >/dev/null; then
    not_restarted=$agent
    note "FAIL $agent did not start again"
    echo "${SERVICE}-backup: $agent did not start again; start it by hand" >&2
  fi
  agent=
}
trap restart_agent EXIT
docker stop "$agent" >/dev/null || fail "$agent: could not stop the sidecar for its snapshot"
note "$agent: stopped for the snapshot"
docker exec "$web" rm -f "$STORAGE/backups/agent-durable.sqlite" "$STORAGE/backups/agent-durable.sqlite.manifest.json"
docker exec "$web" env AGENT_STORE="$STORAGE/agent/durable.sqlite" /rails/bin/agent-store snapshot "$STORAGE/backups/agent-durable.sqlite" \
  || fail "$web: the agent store snapshot failed or did not pass integrity_check"
note "$web: agent-durable.sqlite snapshot OK"
for db in "${DATABASES[@]}"; do
  docker exec "$web" sh -c "$snapshot" snapshot "$STORAGE/$db.sqlite3" "$STORAGE/backups/$db.sqlite3" \
    || fail "$web: ${db}.sqlite3 snapshot failed or did not pass integrity_check"
  note "$web: ${db}.sqlite3 snapshot OK"
done
restart_agent

mkdir -p "$STAGE_DIR/backups" 2>/dev/null || true
[ -d "$STAGE_DIR/backups" ] || fail "$STAGE_DIR/backups is missing and could not be created"
[ -w "$STAGE_DIR/backups" ] || fail "$STAGE_DIR/backups is not writable by $(id -un)"
rm -f "$STAGE_DIR"/backups/.incoming.* "$STAGE_DIR"/.incoming.LAST_STAGED_AT

for name in agent-durable.sqlite agent-durable.sqlite.manifest.json; do
  docker cp "$web:$STORAGE/backups/$name" "$STAGE_DIR/backups/.incoming.$name" \
    || { rm -f "$STAGE_DIR"/backups/.incoming.*; fail "could not copy $name out of $web"; }
done
for db in "${DATABASES[@]}"; do
  docker cp "$web:$STORAGE/backups/$db.sqlite3" "$STAGE_DIR/backups/.incoming.$db.sqlite3" \
    || { rm -f "$STAGE_DIR"/backups/.incoming.*; fail "could not copy ${db}.sqlite3 out of $web"; }
done

files=0
docker exec "$web" tar -C "$STORAGE" --exclude=./backups --exclude='./*.sqlite3*' --exclude='./agent/*.sqlite*' --exclude='./agent/*.sock' --exclude='./agent/claude-subscription.json*' --exclude='./agent/chatgpt-subscription.json*' -cf - . \
  >"$STAGE_DIR/backups/.incoming.storage.tar" || files=$?
[ "$files" -le 1 ] && tar -tf "$STAGE_DIR/backups/.incoming.storage.tar" >/dev/null \
  || { rm -f "$STAGE_DIR"/backups/.incoming.*; fail "$web: could not archive the Active Storage files"; }
note "$web: storage.tar OK"

for name in "${DATABASES[@]/%/.sqlite3}" storage.tar agent-durable.sqlite agent-durable.sqlite.manifest.json; do
  mv -f "$STAGE_DIR/backups/.incoming.$name" "$STAGE_DIR/backups/$name" \
    || fail "could not publish $name into $STAGE_DIR"
done

# Last, so the marker never claims a set that is not fully in place.
date -u +%FT%TZ >"$STAGE_DIR/.incoming.LAST_STAGED_AT"
mv -f "$STAGE_DIR/.incoming.LAST_STAGED_AT" "$STAGE_DIR/LAST_STAGED_AT" \
  || fail "could not publish LAST_STAGED_AT into $STAGE_DIR"

note "backup complete: ${DATABASES[*]}, storage.tar and agent-durable.sqlite staged to $STAGE_DIR"
[ -z "$not_restarted" ] || fail "the backup is staged, but $not_restarted did not start again"
