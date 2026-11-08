require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"
require "yaml"

# The office's backup script (ops/backup/durable_assistants-office-backup.sh),
# executed rather than read. `docker` is a stand-in that answers each command
# the script sends an accessory as that accessory would, so the script's own
# decisions are the real thing: what it checks, what it refuses to publish,
# how it publishes and what it keeps. Restoring is by hand (docs/office.md),
# and the real proof is a drill on the host.
class OfficeBackupTest < ActiveSupport::TestCase
  BACKUP = Rails.root.join("ops/backup/durable_assistants-office-backup.sh")
  FILES = %w[ passbolt.sql passbolt-keys.tar wiki.dump wiki-data.tar crm.dump crm-files.tar
              campfire.sqlite3 campfire-storage.tar forgejo.tar ].freeze

  setup do
    @sandbox = Dir.mktmpdir("office-backup")
    @stage = File.join(@sandbox, "stage")
    FileUtils.mkdir_p(File.join(@sandbox, "bin"))
    stub_docker
  end

  teardown { FileUtils.remove_entry(@sandbox) }

  test "every office accessory that keeps data is backed up, and no other" do
    accessories = YAML.load_file(Rails.root.join("config/deploy.example.yml"), aliases: true).fetch("accessories")
    keeping = accessories.select { |_, accessory| accessory["volumes"] || accessory["directories"] }.keys
    # Redis holds the wiki's and the CRM's queues and caches; the worker shares the CRM's files.
    expected = keeping - %w[ wiki-redis crm-redis crm-worker ]

    assert_equal expected.sort, BACKUP.read[/^for accessory in (.+); do$/, 1].split.sort
  end

  test "a run publishes every file, checked and summed, as the current generation, read from the service's containers" do
    _out, stderr, status = run_backup

    assert_predicate status, :success?, stderr
    current = File.join(@stage, "current")
    assert File.symlink?(current)
    assert_equal (FILES + %w[ SHA256SUMS LAST_STAGED_AT ]).sort, Dir.children(current).sort
    _sums, sums_error, verified = Open3.capture3("sha256sum", "--check", "--quiet", "SHA256SUMS", chdir: current)
    assert_predicate verified, :success?, sums_error
    assert_equal "ok", `sqlite3 #{File.join(current, "campfire.sqlite3")} "PRAGMA integrity_check"`.strip
    assert_equal "2", `sqlite3 #{File.join(current, "campfire.sqlite3")} "SELECT count(*) FROM messages"`.strip
    assert_equal "gpg/serverkey_private.asc", `tar -tf #{File.join(current, "passbolt-keys.tar")}`.lines.map(&:strip).grep(/private/).sole
    containers = docker_log.map { it.split.last }.uniq
    assert containers.all? { it.start_with?("maya-") }, containers.inspect
    assert_empty Dir.glob(File.join(@stage, ".incoming.{gen.*,current}"))
  end

  test "the newest two generations stay" do
    3.times do |run|
      sleep 1.1 if run.positive? # a generation is named by the second
      assert_predicate run_backup.last, :success?
    end

    generations = Dir.glob(File.join(@stage, "generation-*")).map { File.basename(it) }.sort
    assert_equal 2, generations.size
    assert_equal generations.last, File.readlink(File.join(@stage, "current"))
  end

  test "a stopped accessory, or a dump cut short, publishes nothing and leaves no scratch" do
    _out, stderr, status = run_backup("FAKE_STOPPED" => "maya-wiki-db")
    assert_not_predicate status, :success?
    assert_match(/maya-wiki-db is not running/, stderr)

    _out, stderr, status = run_backup("FAKE_CUT_SHORT" => "1")
    assert_not_predicate status, :success?
    assert_match(/passbolt.sql has no completion trailer/, stderr)

    assert_not File.exist?(File.join(@stage, "current"))
    assert_empty Dir.glob(File.join(@stage, "{generation-*,.incoming.gen.*}"))
  end

  test "the units run it daily as the docker group, with its own dead-man push" do
    units = Rails.root.join("ops/backup/systemd")
    service = units.join("durable_assistants-office-backup.service").read

    assert_match(/^ExecStart=.*durable_assistants-office-backup\.sh$/, service)
    assert_match(/^SupplementaryGroups=docker$/, service)
    assert_match(/^OnFailure=durable_assistants-office-backup-failure\.service$/, service)
    assert_match(/^ExecStartPost=-.*durable_assistants-backup-monitor finish$/, service)
    failure = units.join("durable_assistants-office-backup-failure.service").read
    assert_match(/durable_assistants-backup-monitor fail/, failure)
    [ service, failure ].each { assert_includes it, "BACKUP_MONITOR_SECRET_FILE=/etc/durable_assistants-office-backup-uptime-kuma-url" }
    assert_match(/^OnCalendar=/, units.join("durable_assistants-office-backup.timer").read)
  end

  private
    def run_backup(extra = {})
      env = { "PATH" => "#{File.join(@sandbox, 'bin')}:#{ENV.fetch('PATH')}", "FAKE_SANDBOX" => @sandbox,
              "BACKUP_SERVICE" => "maya", "BACKUP_STAGE_DIR" => @stage }
      Open3.capture3(env.merge(extra), BACKUP.to_s)
    end

    def docker_log = File.readlines(File.join(@sandbox, "docker.log"), chomp: true)

    # Each accessory's answer to what the script asks it, by the command.
    def stub_docker
      File.write(File.join(@sandbox, "bin", "docker"), <<~'SH')
        #!/usr/bin/env bash
        set -e
        box="$FAKE_SANDBOX/box"; mkdir -p "$box"
        container=""
        case "$1" in
          inspect) echo "inspect $4" >>"$FAKE_SANDBOX/docker.log"
                   [ "$4" = "${FAKE_STOPPED:-}" ] && echo false || echo true; exit 0 ;;
          cp) echo "cp ${2%%:*}" >>"$FAKE_SANDBOX/docker.log"; cp "$box/campfire.sqlite3" "$3"; exit 0 ;;
          exec) shift
                while [[ "$1" == -* ]]; do [ "$1" = -w ] && shift; shift; done
                container=$1; shift ;;
        esac
        echo "exec $container" >>"$FAKE_SANDBOX/docker.log"
        command="$*"
        case "$command" in
          *mariadb-dump*)
            printf 'CREATE TABLE `secrets` (id int);\n'
            [ -n "${FAKE_CUT_SHORT:-}" ] || printf -- '-- Dump completed on 2026-11-08\n' ;;
          "tar -C /etc/passbolt"*)
            mkdir -p "$box/passbolt/gpg" "$box/passbolt/jwt"; echo key >"$box/passbolt/gpg/serverkey_private.asc"
            tar -C "$box/passbolt" -cf - gpg jwt ;;
          *pg_dump*) printf 'PGDMP' ;;
          "pg_restore --list") cat >/dev/null; printf ';\n;     Format: CUSTOM\n' ;;
          *ruby*) rm -f "$box/campfire.sqlite3"
                  sqlite3 "$box/campfire.sqlite3" "CREATE TABLE messages (body text); INSERT INTO messages VALUES ('hi'), ('there');" ;;
          "tar -C "*) mkdir -p "$box/files"; echo data >"$box/files/one"; tar -C "$box/files" -cf - . ;;
          "test -d "*) exit 0 ;;
          *"forgejo dump"*) mkdir -p "$box/forgejo"; touch "$box/forgejo/forgejo-db.sql" "$box/forgejo/app.ini"
                            tar -C "$box/forgejo" -cf - forgejo-db.sql app.ini ;;
          "rm -f "*) ;;
          *) echo "unexpected docker exec $command" >&2; exit 99 ;;
        esac
      SH
      FileUtils.chmod(0o755, File.join(@sandbox, "bin", "docker"))
    end
end
