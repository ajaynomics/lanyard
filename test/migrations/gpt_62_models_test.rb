require "test_helper"
require "tmpdir"

# 20261119040000 moves agents off the two models ChatGPT now calls "previous
# generation": GPT-6.1 Sol to GPT-6.2 Sol and GPT-6 Astra to GPT-6.2 Astra, on
# the two subscription routes only, keeping each agent's thinking. An agent on
# the API key's openai/gpt-6.1-sol stays: no other route is the same payer, and
# 6.2 is not offered there yet. It is named in the migration's output. Terra,
# Luna, Claude and the records of what ran (revisions) are left as they were.
class Gpt62ModelsMigrationTest < ActiveSupport::TestCase
  VERSION = 20261119040000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("gpt-62")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "subscription agents on GPT-6.1 Sol or GPT-6 Astra move to 6.2 on the same route; the API key's, the rest and the history stay" do
    made = "2026-11-18T10:00:00Z"
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 'a', 'Maya', 'maya@example.com', '#{made}', '#{made}')")
    @connection.execute("INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{made}', '#{made}')")
    models = %w[ openai-codex/gpt-6.1-sol openai-chatgpt/gpt-6-astra openai/gpt-6.1-sol openai-codex/gpt-6.1-terra openai-chatgpt/gpt-6-luna anthropic/claude-opus-5-5 openai-codex/gpt-6-sol ]
    models.each.with_index(1) do |model, id|
      @connection.execute("INSERT INTO agents (id, user_id, workspace_id, name, instructions, model, thinking_level, email_name, created_at, updated_at) " \
        "VALUES (#{id}, 1, 1, 'Agent #{id}', 'Help.', '#{model}', 'high', 'agent#{id}', '#{made}', '#{made}')")
      @connection.execute("INSERT INTO agent_revisions (agent_id, instructions, model, created_at) VALUES (#{id}, 'Help.', '#{model}', '#{made}')")
    end

    output = capture_io { ActiveRecord::Migration.verbose = true; run_migrations { it == VERSION } }.first

    assert_equal %w[ openai-codex/gpt-6.2-sol openai-chatgpt/gpt-6.2-astra openai/gpt-6.1-sol openai-codex/gpt-6.1-terra openai-chatgpt/gpt-6-luna anthropic/claude-opus-5-5 openai-codex/gpt-6-sol ],
      @connection.select_values("SELECT model FROM agents ORDER BY id")
    assert_equal [ "high" ], @connection.select_values("SELECT DISTINCT thinking_level FROM agents")
    assert_equal models, @connection.select_values("SELECT model FROM agent_revisions ORDER BY agent_id"), "what an agent was is history"
    assert_equal [ made ], @connection.select_values("SELECT DISTINCT updated_at FROM agents")
    assert_match "agent 3 stays on openai/gpt-6.1-sol", output
    assert_match "moved 2 agents", output
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
