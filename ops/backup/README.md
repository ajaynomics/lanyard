# Backups

One deployment's backup, run on its host by a systemd timer. The scripts take
`BACKUP_SERVICE`, the deployment's Kamal service name (`durable_assistants`
unless its destination sets its own `service:`), and name everything after it:
the containers `<service>-web-…` and `<service>-agent-…`, the stage directory
`/data/docker/<service>-backup` and the monitor's URL file
`/etc/<service>-backup-uptime-kuma-url`. Each path can also be set on its own
(`BACKUP_STAGE_DIR`, `BACKUP_LOG`, `BACKUP_MONITOR_SECRET_FILE`).

`durable_assistants-backup.sh` snapshots every production SQLite database inside
the web container (`sqlite3 .backup`, then `PRAGMA integrity_check`), streams
the Active Storage files out of the same volume as `storage.tar`, and publishes
the whole set atomically into the stage directory, which the host's borgmatic
archives. Nothing is published unless every snapshot passed, and the
`LAST_STAGED_AT` marker is written last.

`durable_assistants-restore.sh` proves a set: it restores into a scratch
directory, checks integrity, reads every table of the record, unpacks
`storage.tar` and checks that every blob the record names has its file.

    BACKUP_SERVICE=<service> ops/backup/durable_assistants-restore.sh     # the latest stage
    ops/backup/durable_assistants-restore.sh <extracted-archive>/backups /tmp/look-here

`durable_assistants-backup-monitor` pushes each run's result to an Uptime Kuma
push monitor (a dead-man: a missed heartbeat means the timer, the script, or the
host stopped). The push URL is a credential and lives in a root-only file, never
in the repository.

`test/backup_test.rb` runs the real scripts against real SQLite files and a real
tarball, with only `docker` stubbed. `test/standards_test.rb` (S11) fails if a
database is added to `config/database.yml` and not to the backup.

## The office

`durable_assistants-office-backup.sh` backs up the office's accessories
(`docs/office.md`, which has the restore steps) into
`/data/docker/<service>-office-backup`, one checked generation per run, the
newest two kept. Its units in `systemd/` run as the docker group, before the
app's backup, with a push monitor of their own
(`/etc/<service>-office-backup-uptime-kuma-url`). Install them as below, the
same way. `test/office_backup_test.rb` runs the real script against a stand-in
`docker`.

## Installing the units (operator steps; CI never installs them)

`ops/backup/systemd/` holds example units. An install copies them into its own
folder (for example `ops/backup/<host>/`), renamed after its service, with
`BACKUP_SERVICE` set to it, and keeps them as its own files
(`docs/deployments.md`). The scripts are copied to the host:

    sudo install -d /usr/local/lib/<service>-backup
    sudo install -m 755 ops/backup/durable_assistants-backup.sh \
      ops/backup/durable_assistants-office-backup.sh \
      ops/backup/durable_assistants-backup-monitor /usr/local/lib/<service>-backup/
    sudo cp ops/backup/<host>/* /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now <service>-backup.timer

Create a push monitor in Uptime Kuma (heartbeat just over 24 hours), then write
its URL where the service user cannot read it:

    sudo install -m 600 -o root -g root /dev/stdin /etc/<service>-backup-uptime-kuma-url
    # paste https://<kuma>/api/push/<token>, newline, ctrl-d

Re-copy the two scripts whenever they change in the repository.

A host whose borgmatic cannot reach another host's stage directory needs that
set pulled to it, with its own monitor so a stale set pages: refuse a set
older than 26 hours. There is no pull script here yet.

### Proving it

    sudo systemctl start <service>-backup.service
    BACKUP_SERVICE=<service> ops/backup/durable_assistants-restore.sh

The Kuma monitor should show a fresh `up` push.

## The agent sidecar's store (PI_DURABLE=1)

`durable_assistants-backup.sh` also stops the `agent` container, snapshots its
retained store with `bin/agent-store` in the web container, takes the database
snapshots in the same window and starts the sidecar again, whatever happens.
If the sidecar does not start, the run still publishes a good backup but ends
as a failure, so the monitor pushes `down`: start the `agent` container by hand.
The set gains `agent-durable.sqlite` and its manifest;
`durable_assistants-restore.sh` checks the snapshot's SHA-256 against the
manifest and runs `integrity_check`. `docs/agent.md` has the restore-to-live
steps.
