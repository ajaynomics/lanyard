require "test_helper"
require "tmpdir"

# 20261125191000 adds who allowed each instruction revision. A
# revision kept before it records none of that, and keeps its text. Run on a
# database of its own built by the migrations before it.
class InstructionProvenanceMigrationTest < ActiveSupport::TestCase
  VERSION = 20261125191000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("instruction-provenance")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "a revision kept before keeps its text and invents no approval or call" do
    now = "2026-11-24T10:00:00Z"
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 'a', 'Maya', 'maya@example.com', '#{now}', '#{now}'), (2, 'b', 'Theo', 'theo@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, instructions, created_at, updated_at) VALUES (1, 'Studio', 0, 'Shared text', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, email_name, instructions, model, created_at, updated_at) VALUES (1, 1, 1, 'Editor', 'editor', 'Personal text', 'test-model', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agent_revisions (id, agent_id, instructions, model, created_at) VALUES (1, 1, 'Personal text', 'test-model', '#{now}')")
    @connection.execute("INSERT INTO workspace_revisions (id, workspace_id, instructions, changed_by_id, created_at) VALUES (1, 1, 'Shared text', 1, '#{now}')")

    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Personal text", nil, nil, nil, nil ] ], @connection.select_rows("SELECT id, instructions, approval_id, " \
      "approved_digest, instruction_workspace_id, invocation_id FROM agent_revisions")
    assert_equal [ [ 1, "Shared text", 1, nil, nil ] ], @connection.select_rows("SELECT id, instructions, changed_by_id, " \
      "approval_id, approved_digest FROM workspace_revisions")

    run_migrations { it == 20261125192000 }
    assert_equal [ [ 1, "Personal text", nil, nil ] ], @connection.select_rows("SELECT id, instructions, restored_by_id, restored_from_id FROM agent_revisions")
    @connection.execute("UPDATE agent_revisions SET restored_by_id = 2")
    @connection.execute("DELETE FROM users WHERE id = 2")
    assert_nil @connection.select_value("SELECT restored_by_id FROM agent_revisions WHERE id = 1")

    run_migrations { it == 20261125193000 }
    assert_equal [ [ 1, "Shared text", 1, nil, nil ] ], @connection.select_rows("SELECT id, instructions, changed_by_id, restored_by_id, restored_from_id FROM workspace_revisions")
    @connection.execute("INSERT INTO workspace_revisions (id, workspace_id, instructions, changed_by_id, created_at, restored_from_id) VALUES (2, 1, 'Restored text', 1, '#{now}', 1)")
    @connection.execute("DELETE FROM workspace_revisions WHERE id = 1")
    assert_nil @connection.select_value("SELECT restored_from_id FROM workspace_revisions WHERE id = 2")
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
