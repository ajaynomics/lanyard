require "test_helper"
require "tmpdir"

# 20261117050000 adds a workspace's contact routes, and 20261117050100 a
# member's sole contact and number. Existing members are as they were, with
# no sole contact, and no contact is routed; deleting an agent clears a
# member's choice of it and its routes. Run on a database of its own built by
# the migrations before them.
class WorkspaceContactsMigrationTest < ActiveSupport::TestCase
  VERSIONS = [ 20261117050000, 20261117050100 ].freeze
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-contacts")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSIONS.first }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "members are as they were, with no sole contact, nothing is routed, and an agent's deletion clears both" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Olive', 'olive@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Harbour', 0, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspace_memberships (id, workspace_id, user_id, role, created_at, updated_at) VALUES (1, 1, 1, 'owner', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, email_name, instructions, model, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Ada', 'ada', 'Help.', 'local/stand-in', '#{now}', '#{now}')")
    run_migrations { VERSIONS.include?(it) }

    assert_equal [ [ 1, 1, "owner", nil, nil ] ], @connection.select_rows("SELECT workspace_id, user_id, role, sole_contact_id, phone_number FROM workspace_memberships")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_contact_routes")

    @connection.execute("UPDATE workspace_memberships SET sole_contact_id = 1")
    route = -> { @connection.execute("INSERT INTO workspace_contact_routes (workspace_id, agent_id, contact, created_at, updated_at) VALUES (1, 1, 'client@example.net', '#{now}', '#{now}')") }
    route.()
    assert_raises(ActiveRecord::RecordNotUnique) { route.() }

    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM agents WHERE id = 1")
    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, sole_contact_id FROM workspace_memberships")
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM workspace_contact_routes")
  end

  private
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
