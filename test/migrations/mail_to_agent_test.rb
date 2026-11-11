require "test_helper"
require "tmpdir"

# 20261112010000 adds the agent that takes an agent's mail once another has
# replaced it. Every existing agent keeps its own mail; deleting the agent
# named gives the mail back; and the step can be undone. Run on a database of
# its own built by the migrations before it.
class MailToAgentTest < ActiveSupport::TestCase
  VERSION = 20261112010000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("mail-to-agent")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing agents keep their own mail, deleting the agent named gives it back, and it undoes" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    [ [ 1, "old" ], [ 2, "new" ] ].each do |id, name|
      @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (#{id}, 1, '#{name}', 'Help.', 'm', '#{name}', '#{now}', '#{now}')")
    end
    before = @connection.columns(:agents).map(&:name)
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "old", nil ], [ 2, "new", nil ] ], @connection.select_rows("SELECT id, email_name, mail_to_agent_id FROM agents ORDER BY id")
    @connection.execute("UPDATE agents SET mail_to_agent_id = 2 WHERE id = 1")
    @connection.execute("DELETE FROM agents WHERE id = 2")
    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, mail_to_agent_id FROM agents")

    run_migrations(:down) { it == VERSION }
    assert_equal before, @connection.columns(:agents).map(&:name)
    assert_equal [ [ 1, "old" ] ], @connection.select_rows("SELECT id, email_name FROM agents")
  end

  private
    def run_migrations(direction = :up)
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
