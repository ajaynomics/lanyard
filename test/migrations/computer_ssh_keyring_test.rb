require "test_helper"
require "tmpdir"

# 20261115100000 gives each agent's SSH computer its own keyring (issue #59).
# Existing SSH computers keep the keyring their person had, so the key on
# their machines and the hosts they trust stay as they are; every other
# computer is left empty and uses its agent's own. Run on a database of its
# own built by the migrations before it.
class ComputerSshKeyringTest < ActiveSupport::TestCase
  VERSION = 20261115100000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("computer-ssh-keyring")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "each existing SSH computer keeps its person's keyring; the rest are left to their agent's own" do
    insert "users", id: 1, oidc_sub: "sub-1", name: "Maya", email: "maya@example.com", ssh_keyring: "shared"
    insert "users", id: 2, oidc_sub: "sub-2", name: "Robin", email: "robin@example.com"
    [ [ 1, 1 ], [ 2, 2 ], [ 3, 2 ], [ 4, 2 ] ].each do |id, user_id|
      insert "agents", id: id, user_id: user_id, name: "A#{id}", instructions: "Help.", model: "m", email_name: "a#{id}"
    end
    insert "computers", agent_id: 1, name: "c1", provider: "ssh", ssh_host: "homeserver", ssh_user: "maya"
    insert "computers", agent_id: 2, name: "c2", provider: "ssh", ssh_host: "homeserver", ssh_user: "robin"
    insert "computers", agent_id: 3, name: "c3", provider: "ssh"
    insert "computers", agent_id: 4, name: "c4", provider: "sprites"

    run_migrations { it == VERSION }

    assert_equal [ [ 1, "shared" ], [ 2, "person-2" ], [ 3, "person-2" ], [ 4, nil ] ],
      @connection.select_rows("SELECT agent_id, ssh_keyring FROM computers ORDER BY agent_id")
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

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
