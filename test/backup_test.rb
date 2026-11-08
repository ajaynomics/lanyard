require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"
require "shellwords"

# The backup scripts, executed rather than read: a real SQLite database is
# snapshotted, staged, restored to a scratch directory and counted. Only
# `docker` is a stub -- one that runs the command on the host with the
# container's /rails/storage mapped to a sandbox directory -- so everything
# the scripts decide for themselves (integrity checks, atomic publish, what
# they refuse to publish) is the real thing.
#
# A backup nobody has restored is a hope. This is the test that restores.
class BackupTest < ActiveSupport::TestCase
  BACKUP = Rails.root.join("ops/backup/durable_assistants-backup.sh")
  RESTORE = Rails.root.join("ops/backup/durable_assistants-restore.sh")
  MONITOR = Rails.root.join("ops/backup/durable_assistants-backup-monitor")
  DATABASES = %w[production production_cache production_queue production_cable].freeze
  # An upload as the Disk service lays it out: <k[0,2]>/<k[2,2]>/<key>.
  UPLOAD = "up10ad7key"

  setup do
    @sandbox = Dir.mktmpdir("backup")
    @storage = File.join(@sandbox, "storage")
    @stage = File.join(@sandbox, "stage")
    FileUtils.mkdir_p([ @storage, File.join(@sandbox, "bin") ])
    stub_docker
    DATABASES.each { |name| create_database(name) }
    create_agent_store
    FileUtils.mkdir_p(File.join(@storage, "up", "10"))
    File.write(File.join(@storage, "up", "10", UPLOAD), "uploaded words")
  end

  teardown { FileUtils.remove_entry(@sandbox) }

  test "the backup names every production database, and no other" do
    production = ActiveRecord::Base.configurations.configs_for(env_name: "production")

    assert_equal DATABASES.sort, production.map { |config| File.basename(config.database, ".sqlite3") }.sort
    assert_includes BACKUP.read, "DATABASES=(#{DATABASES.join(' ')})"
  end

  test "a backup stages every database, intact, with the marker last" do
    _out, stderr, status = run_backup

    assert_predicate status, :success?, stderr
    DATABASES.each do |name|
      staged = File.join(@stage, "backups", "#{name}.sqlite3")
      assert_equal "ok", sqlite(staged, "PRAGMA integrity_check"), name
    end
    assert_equal "2", sqlite(File.join(@stage, "backups", "production.sqlite3"), "SELECT count(*) FROM things")
    assert File.exist?(File.join(@stage, "LAST_STAGED_AT"))
    assert_empty Dir.glob(File.join(@stage, "**", ".incoming.*"), File::FNM_DOTMATCH),
      "scratch names are what borgmatic excludes; none may be left to be archived or mistaken for data"
  end

  test "the Active Storage files are staged beside the databases, without them" do
    _out, stderr, status = run_backup

    assert_predicate status, :success?, stderr
    members = tar_members(File.join(@stage, "backups", "storage.tar"))
    assert_includes members, "./up/10/#{UPLOAD}", "the file a blob row names is not in the backup"
    assert_empty members.grep(/sqlite3|\A\.\/backups/),
      "the live databases and their snapshots travel as snapshots, never inside the tarball"
  end

  test "a restore puts every file the record names back on disk" do
    assert_predicate run_backup.last, :success?
    scratch = File.join(@sandbox, "scratch")

    out, stderr, status = run_restore(File.join(@stage, "backups"), scratch)

    assert_predicate status, :success?, stderr
    assert_match(/storage\.tar: 1 blobs, every file present/, out)
    assert_equal "uploaded words", File.read(File.join(scratch, "storage", "up", "10", UPLOAD))
  end

  test "restore refuses a snapshot whose record names a file it does not have" do
    FileUtils.rm(File.join(@storage, "up", "10", UPLOAD))
    assert_predicate run_backup.last, :success?

    _out, stderr, status = run_restore(File.join(@stage, "backups"))

    assert_not status.success?, "a backup missing an upload was reported as restorable"
    assert_match(/1 of 1 Active Storage blobs have no file/, stderr)
  end

  # The reason `.backup` is used rather than cp: a committed write can still be
  # only in the -wal while a connection holds the database open.
  test "a write that is still only in the live -wal is in the snapshot" do
    live = File.join(@storage, "production.sqlite3")
    holder = IO.popen([ "sqlite3", live ], "r+")
    holder.puts "PRAGMA journal_mode=WAL;"
    holder.puts "INSERT INTO things (name) VALUES ('uncheckpointed');"
    holder.puts "SELECT 'ready';"
    holder.flush
    while (line = holder.gets)
      break if line.strip == "ready"
    end
    assert File.size?("#{live}-wal"), "the write was checkpointed; this test would prove nothing"
    assert_equal "2", sqlite_main_file_only(live), "a plain copy of the file would lose the write"

    _out, stderr, status = run_backup

    assert_predicate status, :success?, stderr
    assert_equal "3", sqlite(File.join(@stage, "backups", "production.sqlite3"), "SELECT count(*) FROM things")
  ensure
    holder&.close
  end

  test "restore proves a staged snapshot to a scratch directory and leaves the snapshot alone" do
    assert_predicate run_backup.last, :success?
    snapshot = File.join(@stage, "backups")
    before = Digest::SHA256.file(File.join(snapshot, "production.sqlite3")).hexdigest
    scratch = File.join(@sandbox, "scratch")

    out, stderr, status = run_restore(snapshot, scratch)

    assert_predicate status, :success?, stderr
    assert_match(/production\.sqlite3: integrity_check ok/, out)
    assert_match(/production\.sqlite3: things: 2/, out)
    assert_match(/restore ok/, out)
    assert_equal "2", sqlite(File.join(scratch, "production.sqlite3"), "SELECT count(*) FROM things"),
      "the restored copy answers the same query the live database does"
    assert_equal before, Digest::SHA256.file(File.join(snapshot, "production.sqlite3")).hexdigest,
      "restore opened the snapshot in place instead of a copy"
  end

  test "restore without a scratch argument cleans up after itself" do
    assert_predicate run_backup.last, :success?
    tmp = File.join(@sandbox, "tmp")
    FileUtils.mkdir_p(tmp)

    _out, stderr, status = run_restore(File.join(@stage, "backups"), nil, "TMPDIR" => tmp)

    assert_predicate status, :success?, stderr
    assert_empty Dir.children(tmp)
  end

  test "restore refuses a corrupt snapshot" do
    assert_predicate run_backup.last, :success?
    snapshot = File.join(@stage, "backups", "production.sqlite3")
    bytes = File.binread(snapshot)
    File.binwrite(snapshot, bytes[0, 4096] + ("\x00".b * 4096) + bytes[8192..].to_s)

    _out, stderr, status = run_restore(File.join(@stage, "backups"))

    assert_not status.success?, "a damaged snapshot was reported as restorable"
    assert_match(/production\.sqlite3/, stderr)
  end

  test "restore refuses a snapshot without the record" do
    FileUtils.mkdir_p(File.join(@sandbox, "empty"))

    _out, stderr, status = run_restore(File.join(@sandbox, "empty"))

    assert_not status.success?
    assert_match(/no production\.sqlite3/, stderr)
  end

  test "restore refuses a database whose schema did not come back" do
    FileUtils.mkdir_p(File.join(@sandbox, "bare"))
    sqlite(File.join(@sandbox, "bare", "production.sqlite3"), "CREATE TABLE unrelated (id integer)")

    _out, stderr, status = run_restore(File.join(@sandbox, "bare"))

    assert_not status.success?
    assert_match(/schema_migrations/, stderr)
  end

  test "a failed snapshot publishes nothing and keeps yesterday's set" do
    assert_predicate run_backup.last, :success?
    yesterday = File.read(File.join(@stage, "LAST_STAGED_AT"))
    File.binwrite(File.join(@storage, "production_queue.sqlite3"), "not a database" * 100)

    _out, stderr, status = run_backup

    assert_not status.success?
    assert_match(/production_queue\.sqlite3 snapshot failed/, stderr)
    assert_equal yesterday, File.read(File.join(@stage, "LAST_STAGED_AT"))
    assert_equal "2", sqlite(File.join(@stage, "backups", "production.sqlite3"), "SELECT count(*) FROM things")
    assert_empty Dir.glob(File.join(@stage, "**", ".incoming.*"), File::FNM_DOTMATCH)
  end

  test "no running web container is a failure, not an empty success" do
    _out, stderr, status = run_backup("FAKE_DOCKER_NO_CONTAINER" => "1")

    assert_not status.success?
    assert_match(/no running durable_assistants-web container/, stderr)
    assert_not File.exist?(File.join(@stage, "LAST_STAGED_AT"))
  end

  test "the monitor pushes up or down to the URL in the root-only file" do
    secret = File.join(@sandbox, "kuma-url")
    File.write(secret, "https://uptime.example.com/api/push/abc_123\n")
    curl = File.join(@sandbox, "bin", "curl")
    write_executable(curl, "#!/bin/sh\ncat >> #{File.join(@sandbox, 'curl.log').shellescape}\n")
    env = { "BACKUP_MONITOR_SECRET_FILE" => secret, "CURL_BIN" => curl }

    _out, stderr, status = Open3.capture3(env, MONITOR.to_s, "finish")
    assert_predicate status, :success?, stderr
    _out, stderr, status = Open3.capture3(env, MONITOR.to_s, "fail")
    assert_predicate status, :success?, stderr

    sent = File.read(File.join(@sandbox, "curl.log"))
    assert_includes sent, "https://uptime.example.com/api/push/abc_123"
    assert_includes sent, "status=up"
    assert_includes sent, "status=down"
  end

  test "the monitor refuses a missing or malformed push URL" do
    missing = Open3.capture3({ "BACKUP_MONITOR_SECRET_FILE" => File.join(@sandbox, "none") }, MONITOR.to_s, "finish")
    assert_equal 78, missing.last.exitstatus

    secret = File.join(@sandbox, "kuma-url")
    File.write(secret, "http://not-https.example.com/anything\n")
    malformed = Open3.capture3({ "BACKUP_MONITOR_SECRET_FILE" => secret }, MONITOR.to_s, "finish")
    assert_equal 78, malformed.last.exitstatus
  end

  test "the units that run the backup are files, and wire the dead-man push" do
    units = Rails.root.join("ops/backup/systemd")
    service = units.join("durable_assistants-backup.service").read

    assert_match(/^OnFailure=durable_assistants-backup-failure\.service$/, service)
    assert_match(/^ExecStartPost=-.*durable_assistants-backup-monitor finish$/, service)
    assert_match(/durable_assistants-backup-monitor fail/, units.join("durable_assistants-backup-failure.service").read)
    assert_match(/^OnCalendar=/, units.join("durable_assistants-backup.timer").read)
  end

  test "BACKUP_SERVICE names the containers an install's deployment runs as" do
    _out, stderr, status = run_backup("BACKUP_SERVICE" => "myapp")

    assert_predicate status, :success?, stderr
    assert_equal [ "stop myapp-agent-production-abc123", "start myapp-agent-production-abc123" ], docker_log
  end

  test "the sidecar is stopped for a consistent store snapshot and started again" do
    _out, stderr, status = run_backup

    assert_predicate status, :success?, stderr
    staged = File.join(@stage, "backups", "agent-durable.sqlite")
    assert_equal "ok", sqlite(staged, "PRAGMA integrity_check")
    assert_equal "1", sqlite(staged, "SELECT count(*) FROM conversations")
    manifest = JSON.parse(File.read("#{staged}.manifest.json"))
    assert_equal Digest::SHA256.file(staged).hexdigest, manifest.fetch("sha256")
    assert_equal [ "stop #{AGENT}", "start #{AGENT}" ], docker_log
    assert_empty tar_members(File.join(@stage, "backups", "storage.tar")).grep(%r{\A\./agent/.*\.(sqlite|sock)}),
      "the live agent store travels as its snapshot, never inside the tarball"
  end

  test "the sidecar is started again when its snapshot fails, and nothing is published" do
    File.binwrite(File.join(@storage, "agent", "durable.sqlite"), "not a database" * 100)

    _out, stderr, status = run_backup

    assert_not status.success?
    assert_match(/agent store snapshot failed/, stderr)
    assert_equal [ "stop #{AGENT}", "start #{AGENT}" ], docker_log
    assert_not File.exist?(File.join(@stage, "LAST_STAGED_AT"))
  end

  test "no running sidecar, or one that will not stop, is a failure" do
    _out, stderr, status = run_backup("FAKE_DOCKER_NO_AGENT" => "1")
    assert_not status.success?
    assert_match(/no running \S+-agent container/, stderr)

    _out, stderr, status = run_backup("FAKE_DOCKER_STOP_FAILS" => "1")
    assert_not status.success?
    assert_match(/could not stop the sidecar/, stderr)
    assert_not File.exist?(File.join(@stage, "LAST_STAGED_AT"))
  end

  test "restore proves the agent store against its manifest" do
    assert_predicate run_backup.last, :success?
    out, stderr, status = run_restore(File.join(@stage, "backups"))
    assert_predicate status, :success?, stderr
    assert_match(/agent-durable\.sqlite: manifest sha256 and integrity_check ok/, out)

    staged = File.join(@stage, "backups", "agent-durable.sqlite")
    File.open(staged, "ab") { |file| file.write("tampered") }
    _out, stderr, status = run_restore(File.join(@stage, "backups"))
    assert_not status.success?
    assert_match(/does not match its manifest/, stderr)

    File.delete("#{staged}.manifest.json")
    _out, stderr, status = run_restore(File.join(@stage, "backups"))
    assert_not status.success?
    assert_match(/no manifest/, stderr)
  end

  private
    AGENT = "durable_assistants-agent-production-abc123".freeze

    # A sidecar store with one table and row; the snapshot copies it with
    # the app's own bin/agent-store (node:sqlite), as production does.
    def create_agent_store
      FileUtils.mkdir_p(File.join(@storage, "agent"))
      sqlite(File.join(@storage, "agent", "durable.sqlite"),
        "PRAGMA journal_mode=WAL; CREATE TABLE conversations (id integer PRIMARY KEY); INSERT INTO conversations VALUES (1)")
    end

    def docker_log
      path = File.join(@sandbox, "docker.log")
      File.exist?(path) ? File.readlines(path, chomp: true) : []
    end

    def create_database(name)
      path = File.join(@storage, "#{name}.sqlite3")
      statements = [ "CREATE TABLE schema_migrations (version varchar PRIMARY KEY)",
                     "INSERT INTO schema_migrations VALUES ('20260901000000')" ]
      if name == "production"
        statements += [ "CREATE TABLE things (id integer PRIMARY KEY, name text)",
                        "INSERT INTO things (name) VALUES ('a'), ('b')",
                        "CREATE TABLE active_storage_blobs (id integer PRIMARY KEY, key text, service_name text)",
                        "INSERT INTO active_storage_blobs (key, service_name) VALUES ('#{UPLOAD}', 'local')" ]
      end
      sqlite(path, statements.join("; "))
    end

    def tar_members(path)
      out, err, status = Open3.capture3("tar", "-tf", path)
      assert_predicate status, :success?, err
      out.lines.map(&:chomp)
    end

    # What cp would have carried: the main file alone, with its -wal left behind.
    def sqlite_main_file_only(live)
      copy = File.join(@sandbox, "plain-copy.sqlite3")
      FileUtils.cp(live, copy)
      sqlite(copy, "SELECT count(*) FROM things")
    end

    def sqlite(path, sql)
      out, err, status = Open3.capture3("sqlite3", path, sql)
      assert_predicate status, :success?, err
      out.strip
    end

    def run_backup(extra = {})
      env = { "BACKUP_STAGE_DIR" => @stage, "BACKUP_LOG" => File.join(@sandbox, "backup.log") }.merge(extra)
      Open3.capture3(sandbox_env.merge(env), BACKUP.to_s)
    end

    def run_restore(snapshot, scratch = nil, extra = {})
      Open3.capture3(sandbox_env.merge(extra), RESTORE.to_s, snapshot, *scratch)
    end

    # A minimal environment, so a developer's own docker or BACKUP_* variables
    # cannot decide the outcome.
    def sandbox_env
      { "PATH" => "#{File.join(@sandbox, 'bin')}:#{ENV.fetch('PATH')}", "HOME" => ENV.fetch("HOME", nil),
        "FAKE_STORAGE" => @storage, "FAKE_RAILS_BIN" => Rails.root.join("bin").to_s }
    end

    # The container is the host, with /rails/storage pointing at the sandbox.
    def stub_docker
      write_executable(File.join(@sandbox, "bin", "docker"), <<~'SH')
        #!/bin/sh
        remap() { printf '%s' "$1" | sed -e "s#/rails/storage#$FAKE_STORAGE#g" -e "s#/rails/bin/#$FAKE_RAILS_BIN/#g"; }
        case "$1" in
          ps)
            # One running container, named as Kamal names it, for the filter asked.
            filter=$(printf '%s\n' "$@" | sed -n 's/^name=\^//p')
            case "$filter" in
              *-agent) [ -n "${FAKE_DOCKER_NO_AGENT:-}" ] || echo "$filter-production-abc123" ;;
              *) [ -n "${FAKE_DOCKER_NO_CONTAINER:-}" ] || echo "$filter-production-abc123" ;;
            esac
            ;;
          exec)
            shift 2
            for argument in "$@"; do set -- "$@" "$(remap "$argument")"; shift; done
            exec "$@"
            ;;
          cp)
            cp -- "$(remap "${2#*:}")" "$3"
            ;;
          stop|start)
            echo "$1 $2" >>"$FAKE_STORAGE/../docker.log"
            [ "$1" != stop ] || [ -z "${FAKE_DOCKER_STOP_FAILS:-}" ] || exit 1
            ;;
          *)
            echo "unexpected docker $*" >&2
            exit 99
            ;;
        esac
      SH
    end

    def write_executable(path, contents)
      File.write(path, contents)
      FileUtils.chmod(0o755, path)
    end
end
