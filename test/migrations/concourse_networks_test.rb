require "test_helper"
require "tmpdir"

# 20261112020000 lets an agent hold an identity in several Concourse
# organizations and tags each task with the one it came or went on. Existing
# identities and tasks carry over untouched, a blank tag meaning the first;
# one organization twice is still refused; and going back refuses while an
# agent holds two. Run on a database of its own built by the migrations before it.
class ConcourseNetworksTest < ActiveSupport::TestCase
  VERSION = 20261112020000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("concourse-networks")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 'Maya', 'Help.', 'm', 'maya', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r', 'Trip', 'idle', '#{now}', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO concourse_agents (id, agent_id, organization, handle, client_id, client_secret, created_at, updated_at) VALUES (1, 1, 'acme', 'acme/maya', 'c', 's', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO peer_tasks (id, conversation_id, task_id, peer, direction, state, created_at, updated_at) VALUES (1, 1, 't-1', 'acme/friend', 'inbound', 'TASK_STATE_SUBMITTED', '#{now}', '#{now}')")
    @now = now
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing identities and tasks carry over; a second organization is allowed, the same one twice is not" do
    run_migrations { it == VERSION }

    assert_equal [ [ 1, 1, "acme" ] ], @connection.select_rows("SELECT id, agent_id, organization FROM concourse_agents")
    assert_equal [ [ 1, "t-1", nil ] ], @connection.select_rows("SELECT id, task_id, concourse_agent_id FROM peer_tasks")
    second_network
    assert_raises(ActiveRecord::RecordNotUnique) { second_network(id: 3, organization: "acme") }
  end

  test "going back refuses while an agent holds two identities, and works once it holds one" do
    run_migrations { it == VERSION }
    second_network

    error = assert_raises(StandardError) { run_migrations(:down) { it == VERSION } }
    assert_match "An agent is on more than one Concourse network. Disconnect all but one of each agent's networks first.", error.message
    assert_equal 2, @connection.select_value("SELECT COUNT(*) FROM concourse_agents"), "nothing deleted"
    assert @connection.column_exists?(:peer_tasks, :concourse_agent_id)

    @connection.execute("DELETE FROM concourse_agents WHERE id = 2")
    run_migrations(:down) { it == VERSION }
    assert_not @connection.column_exists?(:peer_tasks, :concourse_agent_id)
    assert @connection.index_exists?(:concourse_agents, :agent_id, unique: true)
    assert_equal [ [ 1, "t-1" ] ], @connection.select_rows("SELECT id, task_id FROM peer_tasks")
  end

  private
    def second_network(id: 2, organization: "example")
      @connection.execute("INSERT INTO concourse_agents (id, agent_id, organization, handle, client_id, client_secret, created_at, updated_at) " \
        "VALUES (#{id}, 1, '#{organization}', '#{organization}/maya', 'c#{id}', 's', '#{@now}', '#{@now}')")
    end

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
