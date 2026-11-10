require "test_helper"
require "tmpdir"

# 20261110002152 gives each person their own SSH key pair. The install's original pair
# stays with the one person who used SSH computers, so their machines keep
# working; when several did, nobody keeps it, since it was shared. Run on a
# database of its own built by the migrations before it.
class SshKeyringTest < ActiveSupport::TestCase
  VERSION = 20261110002152
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("ssh-keyring")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    [ [ 1, "Maya" ], [ 2, "Robin" ], [ 3, "Sam" ] ].each do |id, name|
      insert "users", id: id, oidc_sub: "sub-#{id}", name: name, email: "#{name.downcase}@example.com"
      insert "agents", id: id, user_id: id, name: name, instructions: "Help.", model: "m", email_name: name.downcase
    end
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "the one person who used SSH computers keeps the install's key pair; the others get their own" do
    insert "computers", agent_id: 1, name: "c1", provider: "ssh", ssh_host: "homeserver", ssh_user: "maya"
    insert "computers", agent_id: 3, name: "c3", provider: "sprites"
    run_migrations { it == VERSION }
    assert_equal [ [ 1, "shared" ], [ 2, nil ], [ 3, nil ] ], @connection.select_rows("SELECT id, ssh_keyring FROM users ORDER BY id")
  end

  test "when several people used SSH computers, nobody keeps the shared pair" do
    insert "computers", agent_id: 1, name: "c1", provider: "ssh", ssh_host: "homeserver", ssh_user: "maya"
    insert "computers", agent_id: 2, name: "c2", provider: "ssh", ssh_host: "homeserver", ssh_user: "robin"
    run_migrations { it == VERSION }
    assert_equal [ nil, nil, nil ], @connection.select_values("SELECT ssh_keyring FROM users ORDER BY id")
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
