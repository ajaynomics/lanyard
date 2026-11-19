require "test_helper"
require "tmpdir"

# 20261116140000 gives an agent sending hours and 20261116150000 the mail held
# for them. Additive: every existing agent, and one made by code from before
# during a rolling deploy, has no hours and so holds nothing, and the new
# table starts empty. Run on a database of its own built by the migrations
# before them, then theirs alone.
class SendingHoursMigrationTest < ActiveSupport::TestCase
  VERSIONS = [ 20261116140000, 20261116150000 ].freeze
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("sending-hours")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSIONS.first }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents, and one made by code from before, have no sending hours, and nothing is held" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, personal, created_at, updated_at) VALUES (1, 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")

    run_migrations { it.in?(VERSIONS) }

    assert_equal [ [ 1, nil, nil, nil ] ], @connection.select_rows("SELECT id, send_from, send_until, send_time_zone FROM agents")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (2, 1, 1, 'Juno', 'Help.', 'm', 'juno', '#{now}', '#{now}')")
    assert_equal [ nil, nil, nil ], @connection.select_rows("SELECT send_from, send_until, send_time_zone FROM agents WHERE id = 2").sole
    assert_equal 0, @connection.select_value("SELECT COUNT(*) FROM held_emails")
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
