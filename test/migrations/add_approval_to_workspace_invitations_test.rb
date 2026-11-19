require "test_helper"
require "tmpdir"

# 20261117031000 records an admin's yes to an invitation's email. Those made
# before were emailed at once or shared by hand: approved when made, by nobody
# recorded. Run on a database of its own built by the migrations before it.
class AddApprovalToWorkspaceInvitationsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261117031000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("invitation-approval")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an invitation made before is approved when it was made, by nobody recorded; an approver removed leaves it approved" do
    made = "2026-11-16T10:00:00Z"
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 'a', 'Maya', 'maya@example.com', '#{made}', '#{made}'), (2, 'b', 'Theo', 'theo@example.com', '#{made}', '#{made}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{made}', '#{made}')")
    @connection.execute("INSERT INTO workspace_invitations (id, workspace_id, inviter_id, email, created_at, updated_at) VALUES (1, 1, 1, 'guest@example.com', '#{made}', '#{made}')")

    run_migrations { it == VERSION }

    assert_equal [ [ 1, "guest@example.com", nil ] ], @connection.select_rows("SELECT id, email, approver_id FROM workspace_invitations")
    assert_equal [ made ], @connection.select_values("SELECT approved_at FROM workspace_invitations WHERE approved_at = created_at")

    @connection.execute("INSERT INTO workspace_invitations (id, workspace_id, inviter_id, email, approver_id, approved_at, created_at, updated_at) VALUES (2, 1, 1, 'other@example.com', 2, '#{made}', '#{made}', '#{made}')")
    @connection.execute("DELETE FROM users WHERE id = 2")
    assert_equal [ [ 2, nil ] ], @connection.select_rows("SELECT id, approver_id FROM workspace_invitations WHERE id = 2")
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
