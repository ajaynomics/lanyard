require "test_helper"
require "tmpdir"

# 20261115110000 lets an operator hold an agent's computer while rebuilding its
# Sprite. Additive: every existing computer, and one made by code from before
# the change during a rolling deploy, is not held. Run on a database of its
# own built by the migrations before it, then its own alone: later ones
# (20261115120000) require what code from before does not write.
class ComputerHeldAtTest < ActiveSupport::TestCase
  VERSION = 20261115110000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("held-at")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing computers, and one made by code from before, are not held" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO computers (id, agent_id, name, created_at, updated_at) VALUES (1, 1, 'ss-b1', '#{now}', '#{now}')")

    run_migrations { it == VERSION }

    assert_equal [ [ 1, nil ] ], @connection.select_rows("SELECT id, held_at FROM computers")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (2, 1, 'Juno', 'Help.', 'm', 'juno', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO computers (id, agent_id, name, created_at, updated_at) VALUES (2, 2, 'ss-b2', '#{now}', '#{now}')")
    assert_nil @connection.select_value("SELECT held_at FROM computers WHERE id = 2")
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
