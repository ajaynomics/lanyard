require "test_helper"
require "tmpdir"

# 20261116080000 marks every task that already exists as sent before
# progress notes were passed on, so each gets its one catch-up
# (ConcourseAgent#catch_up). A task an older release writes during a rolling
# deploy takes the default and is followed as a new one.
class PeerTaskNotesFollowedTest < ActiveSupport::TestCase
  VERSION = 20261116080000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("notes-followed")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing tasks wait for their catch-up; one written by code from before during the deploy does not" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Home', 1, '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, email_name, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'Iris', 'Help.', 'm', 'iris', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, created_at, updated_at) " \
      "VALUES (1, 1, 1, 'r', 'Trip', 'idle', '#{now}', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO peer_tasks (id, conversation_id, task_id, peer, direction, state, created_at, updated_at) " \
      "VALUES (1, 1, 't-1', 'acme/travel', 'outbound', 'TASK_STATE_WORKING', '#{now}', '#{now}')")

    run_migrations { it == VERSION }

    assert_equal 0, @connection.select_value("SELECT notes_followed FROM peer_tasks WHERE id = 1")
    @connection.execute("INSERT INTO peer_tasks (id, conversation_id, task_id, peer, direction, state, created_at, updated_at) " \
      "VALUES (2, 1, 't-2', 'acme/travel', 'outbound', 'TASK_STATE_SUBMITTED', '#{now}', '#{now}')")
    assert_equal 1, @connection.select_value("SELECT notes_followed FROM peer_tasks WHERE id = 2")
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
