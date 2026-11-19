require "test_helper"
require "tmpdir"

# 20261119020000 lets a workspace have its own mail domain (#229), a row of
# its own. Existing workspaces have none, so every agent keeps its address at
# the install's domain; a domain is one workspace's, and goes with it. Run on
# a database of its own built by the migrations before it.
class WorkspaceMailDomainsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261119020000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-mail-domains")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    @connection.execute("PRAGMA foreign_keys = ON")
    run_migrations { it < VERSION }
    @now = Time.current.utc.iso8601
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces have no mail domain and are otherwise unchanged; a domain is one workspace's and goes with it" do
    sql "INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{@now}', '#{@now}'), (2, NULL, 1, '#{@now}', '#{@now}')"
    before = @connection.select_rows("SELECT * FROM workspaces ORDER BY id")
    run_migrations { it == VERSION }

    assert_equal before, @connection.select_rows("SELECT * FROM workspaces ORDER BY id")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_mail_domains")

    sql "INSERT INTO workspace_mail_domains (workspace_id, domain, smtp_host, vault_entry, created_at, updated_at) VALUES (1, 'team.example.net', 'mail.example.net', 'Team mail', '#{@now}', '#{@now}')"
    assert_equal [ [ 587, nil, 993, 0 ] ], @connection.select_rows("SELECT smtp_port, imap_host, imap_port, inbox_last_uid FROM workspace_mail_domains")
    assert_raises(ActiveRecord::RecordNotUnique) { sql "INSERT INTO workspace_mail_domains (workspace_id, domain, smtp_host, vault_entry, created_at, updated_at) VALUES (2, 'team.example.net', 'm', 'e', '#{@now}', '#{@now}')" }
    assert_raises(ActiveRecord::RecordNotUnique) { sql "INSERT INTO workspace_mail_domains (workspace_id, domain, smtp_host, vault_entry, created_at, updated_at) VALUES (1, 'two.example.net', 'm', 'e', '#{@now}', '#{@now}')" }

    sql "DELETE FROM workspaces WHERE id = 1"
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_mail_domains")
  end

  private
    def sql(statement) = @connection.execute(statement)

    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, :up) }
      end
    end
end
