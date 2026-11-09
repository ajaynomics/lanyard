#!/usr/bin/env bash
# Nightly backup of the office (docs/office.md): the accessories in
# config/deploy.example.yml, which the app's own backup does not cover. Each
# container is <service>-<accessory>, as Kamal names it.
#
#   passbolt.sql            passbolt-db (MariaDB, mariadb-dump --single-transaction)
#   passbolt-keys.tar       passbolt /etc/passbolt/{gpg,jwt} (the server's keys)
#   wiki.dump               wiki-db (Postgres, pg_dump -Fc)
#   wiki-data.tar           wiki /var/lib/outline/data (its file storage)
#   crm.dump                crm-db (Postgres, pg_dump -Fc)
#   crm-files.tar           crm .local-storage (its file storage)
#   campfire.sqlite3        campfire's database (SQLite online backup)
#   campfire-storage.tar    campfire /rails/storage without db/
#   forgejo.tar             code `forgejo dump` (database as SQL, repositories, data, app.ini)
#
# The two Redis accessories hold only queues and caches, and are not kept.
# Every file is checked before it is published (pg_restore --list, the dump's
# last line, integrity_check, tar -t). Publishing is one rename of a prepared
# `current` link onto a new generation directory; the newest KEEP stay, and
# the host's own backup (borgmatic, say) keeps the history. Everything is read
# through `docker exec`, so the user needs the docker group and not root.
set -euo pipefail
umask 077

SERVICE="${BACKUP_SERVICE:-durable_assistants}"
STAGE_DIR="${BACKUP_STAGE_DIR:-/data/docker/${SERVICE}-office-backup}"
LOG="${BACKUP_LOG:-$STAGE_DIR/backup.log}"
KEEP="${BACKUP_KEEP:-2}"

mkdir -p "$STAGE_DIR"
note() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }
fail() { note "FAIL $*"; echo "office-backup: $*" >&2; exit 1; }

exec 9>"$STAGE_DIR/.incoming.lock"
flock -n 9 || fail "another backup is running"

for accessory in passbolt-db passbolt wiki-db wiki crm-db crm campfire code; do
  [ "$(docker inspect -f '{{.State.Running}}' "$SERVICE-$accessory" 2>/dev/null)" = true ] || fail "$SERVICE-$accessory is not running"
done

INCOMING=$(mktemp -d "$STAGE_DIR/.incoming.gen.XXXXXX")
cleanup() {
  rm -rf "${INCOMING:?}"; rm -f "$STAGE_DIR/.incoming.current"
  docker exec "$SERVICE-campfire" rm -f /tmp/backup-campfire.sqlite3 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- Passbolt -------------------------------------------------------------
docker exec "$SERVICE-passbolt-db" sh -c \
  'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb-dump -u"$MARIADB_USER" --single-transaction --routines --triggers --events --databases "$MARIADB_DATABASE"' \
  >"$INCOMING/passbolt.sql" || fail "mariadb-dump passbolt failed"
tail -n 1 "$INCOMING/passbolt.sql" | grep -q '^-- Dump completed' || fail "passbolt.sql has no completion trailer"
grep -q 'CREATE TABLE `secrets`' "$INCOMING/passbolt.sql" || fail "passbolt.sql has no secrets table"
docker exec "$SERVICE-passbolt" tar -C /etc/passbolt -cf - gpg jwt >"$INCOMING/passbolt-keys.tar" || fail "passbolt keys tar failed"
keys=$(tar -tf "$INCOMING/passbolt-keys.tar") && grep -qx 'gpg/serverkey_private.asc' <<<"$keys" || fail "passbolt-keys.tar lacks the server private key"

# --- Postgres (wiki, crm) -------------------------------------------------
pgdump() { # container out
  docker exec "$1" sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc -Z 0 -d "$POSTGRES_DB"' >"$2" || fail "pg_dump in $1 failed"
  [ -s "$2" ] || fail "$2 is empty"
  local toc
  toc=$(docker exec -i "$1" pg_restore --list <"$2") || fail "pg_restore --list rejected $2"
  grep -q '^;     Format: CUSTOM$' <<<"$toc" || fail "$2 is not a custom-format archive"
}
pgdump "$SERVICE-wiki-db" "$INCOMING/wiki.dump"
pgdump "$SERVICE-crm-db" "$INCOMING/crm.dump"

# --- File stores ----------------------------------------------------------
filetar() { # container dir out [tar args...]; tar's 1 is a file changed while read, harmless
  local c=$1 dir=$2 out=$3 rc=0; shift 3
  docker exec "$c" tar -C "$dir" "$@" -cf - . >"$out" || rc=$?
  [ "$rc" -le 1 ] && tar -tf "$out" >/dev/null || fail "tar of $c:$dir failed"
}
filetar "$SERVICE-wiki" /var/lib/outline/data "$INCOMING/wiki-data.tar"
filetar "$SERVICE-crm" /app/packages/twenty-server/.local-storage "$INCOMING/crm-files.tar"

# --- Campfire (SQLite) ----------------------------------------------------
docker exec -w /rails "$SERVICE-campfire" bundle exec ruby -rsqlite3 -e '
  s = SQLite3::Database.new("/rails/storage/db/production.sqlite3", readonly: true)
  File.delete(ARGV[0]) if File.exist?(ARGV[0])
  d = SQLite3::Database.new(ARGV[0])
  b = SQLite3::Backup.new(d, "main", s, "main"); b.step(-1); b.finish
  r = d.execute("PRAGMA integrity_check").flatten
  abort("integrity_check: #{r.inspect}") unless r == ["ok"]' /tmp/backup-campfire.sqlite3 \
  || fail "campfire SQLite snapshot failed"
docker cp "$SERVICE-campfire:/tmp/backup-campfire.sqlite3" "$INCOMING/campfire.sqlite3" >/dev/null || fail "could not copy campfire snapshot"
[ "$(sqlite3 "$INCOMING/campfire.sqlite3" 'PRAGMA integrity_check')" = ok ] || fail "campfire.sqlite3 failed integrity_check on the host"
filetar "$SERVICE-campfire" /rails/storage "$INCOMING/campfire-storage.tar" --exclude=./db

# --- Forgejo --------------------------------------------------------------
# forgejo dump refuses a missing repository root (nothing pushed yet), so
# repositories are skipped only while that directory does not exist.
skip=""
docker exec "$SERVICE-code" test -d /var/lib/gitea/git/repositories || skip="--skip-repository"
docker exec "$SERVICE-code" sh -c "cd /tmp && exec forgejo dump --type tar --file - --skip-log --skip-index $skip" \
  >"$INCOMING/forgejo.tar" 2>"$INCOMING/.forgejo.err" || { note "$(tail -3 "$INCOMING/.forgejo.err")"; fail "forgejo dump failed"; }
rm -f "$INCOMING/.forgejo.err"
fj=$(tar -tf "$INCOMING/forgejo.tar") || fail "forgejo.tar is not a readable tar"
grep -qx 'forgejo-db.sql' <<<"$fj" || fail "forgejo.tar has no forgejo-db.sql"
grep -qx 'app.ini' <<<"$fj" || fail "forgejo.tar has no app.ini"
[ -z "$skip" ] || note "forgejo: no repository root yet, repositories skipped"

# --- Publish --------------------------------------------------------------
(cd "$INCOMING" && sha256sum -- * >SHA256SUMS)
date -u +%FT%TZ >"$INCOMING/LAST_STAGED_AT"
chmod 600 "$INCOMING"/*

generation="generation-$(date -u +%Y%m%dT%H%M%S)"
mv -T "$INCOMING" "$STAGE_DIR/$generation"
ln -s "$generation" "$STAGE_DIR/.incoming.current"
mv -Tf "$STAGE_DIR/.incoming.current" "$STAGE_DIR/current"
trap - EXIT
docker exec "$SERVICE-campfire" rm -f /tmp/backup-campfire.sqlite3 >/dev/null 2>&1 || true

cur=$(readlink "$STAGE_DIR/current")
ls -1d "$STAGE_DIR"/generation-* | sort | head -n -"$KEEP" | while read -r old; do
  [ "$(basename "$old")" = "$cur" ] || rm -rf -- "$old"
done
note "$generation: office staged ($(du -sh "$STAGE_DIR/$generation" | cut -f1))"
