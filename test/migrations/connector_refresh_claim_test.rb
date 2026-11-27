require "test_helper"
require "tmpdir"

# 20261125180000 lets a renewal claim a connector's refresh token
# (McpServer::Renewal): every connector already there is claimed by none and
# is as it was; a write from code that doesn't know the columns still saves;
# it goes back down. Run on a database of its own built by the migrations
# before it, then it alone.
class ConnectorRefreshClaimTest < ActiveSupport::TestCase
  VERSION = 20261125180000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("connector_refresh_claim")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "connectors already there are claimed by no renewal and keep everything; a write from before still saves; it goes back down" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Acorn', 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO mcp_servers (id, user_id, workspace_id, name, url, oauth_tokens, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'slack', 'https://mcp.slack.com/mcp', 'ciphertext', '#{now}', '#{now}')")
    before = @connection.select_all("SELECT * FROM mcp_servers").to_a

    run_migrations(:up) { it == VERSION }

    assert_equal [ [ 1, nil, nil ] ], @connection.select_rows("SELECT id, refresh_claim, refresh_claimed_at FROM mcp_servers")
    assert_equal before, @connection.select_all("SELECT #{before.first.keys.join(", ")} FROM mcp_servers").to_a
    @connection.execute("INSERT INTO mcp_servers (id, user_id, workspace_id, name, url, created_at, updated_at) " \
      "VALUES (2, 1, 1, 'notes', 'https://notes.example.com/mcp', '#{now}', '#{now}')")

    run_migrations(:down) { it == VERSION }
    assert_not @connection.column_exists?(:mcp_servers, :refresh_claim)
    assert_not @connection.column_exists?(:mcp_servers, :refresh_claimed_at)
    assert_equal [ [ 1, "ciphertext" ], [ 2, nil ] ], @connection.select_rows("SELECT id, oauth_tokens FROM mcp_servers ORDER BY id")
  end

  private
    def run_migrations(direction)
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, direction) }
      end
    end
end
