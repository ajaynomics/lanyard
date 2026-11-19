require "test_helper"
require "tmpdir"

class SendApprovalsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261112170000
  FLAGS = %w[ asks_every_email asks_every_text asks_every_imessage asks_every_concourse_send ].freeze
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("send_approvals")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations(:up) { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing and new agents keep existing sending rules, with independent non-null flags and a reversible schema" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Robin', 'robin@example.com', '#{now}', '#{now}')")
    insert_agent(1, "Robin", now)
    run_migrations(:up) { it == VERSION }
    insert_agent(2, "Helper", now)
    assert_equal [ [ 1, 0, 0, 0, 0 ], [ 2, 0, 0, 0, 0 ] ], @connection.select_rows("SELECT id, #{FLAGS.join(', ')} FROM agents ORDER BY id")
    FLAGS.each do |flag|
      assert_raises(ActiveRecord::NotNullViolation) { @connection.execute("UPDATE agents SET #{flag} = NULL WHERE id = 1") }
      @connection.execute("UPDATE agents SET #{flag} = 1 WHERE id = 1")
    end
    assert_equal [ 1, 1, 1, 1 ], @connection.select_rows("SELECT #{FLAGS.join(', ')} FROM agents WHERE id = 1").sole
    assert_equal [ 0, 0, 0, 0 ], @connection.select_rows("SELECT #{FLAGS.join(', ')} FROM agents WHERE id = 2").sole
    run_migrations(:down) { it == VERSION }
    FLAGS.each { assert_not_includes @connection.columns(:agents).map(&:name), it }
    assert_equal [ [ 1, "Robin" ], [ 2, "Helper" ] ], @connection.select_rows("SELECT id, name FROM agents ORDER BY id")
  end

  private
    def insert_agent(id, name, now)
      @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (#{id}, 1, '#{name}', 'Help.', 'example/model', 'agent-#{id}', '#{now}', '#{now}')")
    end

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
