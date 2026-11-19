require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require "async"

# #121: nine routines fired at once, and while their runs streamed a frame
# waited the primary's whole 5 s for SQLite's one write lock and failed. A
# frame of a run already going changes nothing stored, so it needs no write
# lock: here nine stream at once, as Falcon serves them (a fiber each), on
# the production primary's settings, while another write holds the lock for
# longer than that wait.
class FramesUnderLoadTest < ActiveSupport::TestCase
  include AgentTestHelper

  # Fixture transactions would hold the very lock this test is about.
  self.use_transactional_tests = false

  STREAMS = 9
  HELD = 6

  setup do
    @saved = ActiveRecord::Base.connection_db_config
    @path = Rails.root.join("tmp/frames-under-load-#{Process.pid}.sqlite3").to_s
    primary = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "primary")
    @primary = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "primary", primary.configuration_hash.merge(database: @path))
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(@primary) { load Rails.root.join("db/schema.rb") }
    end
    ActiveRecord::Base.establish_connection(@primary)
    install_sidecar_settings

    agent = create_user.agents.sole
    @conversations = STREAMS.times.map { create_conversation(agent, durable_id: (100 + it).to_s, request_id: "r-#{it}") }
    @conversations.each { it.update!(status: "running", execution_status: "running") }
  end

  teardown do
    remove_sidecar_settings
    ActiveRecord::Base.establish_connection(@saved)
    FileUtils.rm_f(Dir["#{@path}*"])
  end

  test "nine runs' frames stream on while another write holds the lock past the primary's wait" do
    held = Thread::Queue.new
    holder = Thread.new do
      SQLite3::Database.new(@path) do |db|
        db.execute("BEGIN IMMEDIATE")
        held << true
        sleep HELD
        db.execute("COMMIT")
      end
    end
    held.pop

    answers = Sync do |task|
      @conversations.map { |conversation| task.async { post_frame(conversation) } }.map(&:wait)
    end

    # Answered while the other write still holds the lock: none waited for it.
    assert holder.alive?, "a frame waited for the write lock"
    assert_equal [ 204 ] * STREAMS, answers.map(&:first), answers.map(&:last).uniq.join("\n")
    assert_equal [ "running" ] * STREAMS, @conversations.map { it.reload.status }
  ensure
    holder&.join
  end

  private
    def post_frame(conversation)
      body = { actorId: conversation.user_id.to_s, workspaceId: conversation.agent_id.to_s, conversationId: conversation.durable_id,
               seq: 7, busy: true, tail: "Working on it", thinking: "", failure: nil, tools: [] }.to_json
      env = Rack::MockRequest.env_for("http://www.example.com/agent/frames", method: "POST", input: body,
        "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => "Bearer #{RAILS_TOKEN}")
      status, _, response = Rails.application.call(env)
      text = +""
      response.each { text << it }
      response.close if response.respond_to?(:close)
      [ status, text.first(300) ]
    end
end
