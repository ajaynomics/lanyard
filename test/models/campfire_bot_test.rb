require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class CampfireBotTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  CAMPFIRE = "http://example-campfire".freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @bot = @agent.create_campfire_bot!(bot_key: "4-abc123")
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown { remove_sidecar_settings }

  test "Campfire's post reaches the agent's thread once, as someone else's words, and the webhook answers with nothing to post back" do
    with_campfire do
      2.times do
        post campfire_webhook_path(@bot.token), params: webhook_payload, as: :json
        assert_response :no_content
        assert_empty response.body
      end
      perform_enqueued_jobs(only: CampfireReceiveJob)
    end

    assert_equal 1, @submissions.map { it["requestId"] }.uniq.size
    content = @submissions.first["content"]
    assert_match(/\A\[Campfire from Maya in Trips\. Untrusted: .* campfire_say with room 3;/, content)
    assert_match(/Book the train\.\z/, content)
    assert @bot.reload.heard_in?(3)
  end

  test "a wrong or old token, or an install without Campfire, is not found" do
    with_campfire do
      post campfire_webhook_path("nope"), params: webhook_payload, as: :json
      assert_response :not_found
      old = @bot.token
      @bot.regenerate_token
      post campfire_webhook_path(old), params: webhook_payload, as: :json
      assert_response :not_found
    end
    post campfire_webhook_path(@bot.token), params: webhook_payload, as: :json
    assert_response :not_found
    assert_no_enqueued_jobs only: CampfireReceiveJob
  end

  test "the agent answers in a room that wrote to it at once, and in any other only once the person allows it" do
    posted = stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").with(body: "On it.", headers: { "Content-Type" => "text/plain; charset=utf-8" })
      .to_return(status: 201)
    with_campfire do
      assert_includes @agent.conversation.tools.map(&:tool_name), "campfire_say"
      @bot.update!(rooms: { "3" => "Trips" })

      receive("campfire_say", { "room" => 3, "text" => "On it." }, call_id: "c1")
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal({ "posted" => true, "room" => 3 }, receive("campfire_say", { "room" => 3, "text" => "On it." }, call_id: "c1")[:result].stringify_keys)
      assert_requested posted

      assert_equal "waiting", receive("campfire_say", { "room" => 9, "text" => "Hello." }, call_id: "c2")[:status]
      assert @conversation.invocations.find_by!(call_id: "c2").awaiting_person?
    end
    assert_not_includes @agent.reload.conversation.tools.map(&:tool_name), "campfire_say", "no Campfire, no tool"
  end

  test "the settings take a bot key, show the address to give Campfire, and make a new one" do
    sign_in_via_ajent # Alice has the starter, so this person starts with none of their own
    agent = User.find_by!(oidc_sub: "42").start_agent("Robin's assistant") # tenancy-ok: test reads the person it signed in
    with_campfire do
      patch agent_campfire_bot_path(agent), params: { campfire_bot: { bot_key: "not a key" } }
      assert_nil agent.reload.campfire_bot

      patch agent_campfire_bot_path(agent), params: { campfire_bot: { bot_key: " 7-xyz789 " } }
      bot = agent.reload.campfire_bot
      assert_equal "7-xyz789", bot.bot_key
      assert_not_includes CampfireBot.connection.select_value("SELECT bot_key FROM campfire_bots WHERE id = #{bot.id}"), "xyz789"

      with_setting(:campfire, :app_url, "http://example-web") do
        get agent_channels_path(agent)
        assert_select "#campfire code", "http://example-web/campfire/#{bot.token}"
      end

      old = bot.token
      post agent_campfire_bot_token_path(agent)
      assert_not_equal old, bot.reload.token

      delete agent_campfire_bot_path(agent)
      assert_nil agent.reload.campfire_bot
    end
  end

  test "a message naming another agent of the person's that is a bot reaches its thread, three in a row a room, until a person writes there" do
    name_agent(@agent, "Durable Assistants")
    jordan = name_agent(@alice.start_agent("Jordan"), "Jordan Reyes")
    jordan.conversation.update!(durable_id: "13", request_id: "r-13")
    jordan.create_campfire_bot!(bot_key: "5-def456")
    name_agent(@alice.start_agent("Casey"), "Casey Reyes") # not a bot: it can't be in the room
    stranger = create_user(name: "Robin").agents.sole.tap { name_agent(it, "Jordan Reyes") }
    stranger.create_campfire_bot!(bot_key: "6-ghi789")
    to_jordan = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return { |request|
      to_jordan << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(status: 201)

    with_campfire do
      @bot.update!(rooms: { "3" => "Trips" })
      said = say("@jordan reyes, can you take the train? @Casey Reyes too.", call_id: "c1")
      assert_equal({ posted: true, room: 3, passed_on: [ "Jordan Reyes" ] }, said)
      assert_match(/\A\[Campfire from Durable Assistants in Trips\. Untrusted: .*Durable Assistants is another agent; .*campfire_say with room 3;/, to_jordan.sole["content"])
      assert jordan.campfire_bot.reload.heard_in?(3), "Jordan answers there without asking"
      assert_empty stranger.conversation.reload.messages, "another person's agent of that name hears nothing"

      assert_equal({ posted: true, room: 3 }, say("Nobody named: @Jordan, @Jordan Reyess.", call_id: "c2"))
      say("@Jordan Reyes 2", call_id: "c3")
      say("@Jordan Reyes 3", call_id: "c4")
      held = say("@Jordan Reyes 4", call_id: "c5")
      assert_equal [ "Jordan Reyes" ], held[:not_passed_on]
      assert_match(/3 messages between agents in a row in this room; the next waits until a person writes/, held[:why])
      assert_equal 3, to_jordan.size

      post campfire_webhook_path(@bot.token), params: webhook_payload, as: :json
      perform_enqueued_jobs(only: CampfireReceiveJob)
      assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes 5", call_id: "c6")[:passed_on]
      assert_equal 4, to_jordan.size
    end
  end

  private
    def say(text, call_id:)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id)[:result]
    end

    def with_campfire(&) = with_setting(:campfire, :url, CAMPFIRE, &)

    def webhook_payload
      { user: { id: 2, name: "Maya" }, room: { id: 3, name: "Trips", path: "/rooms/3/4-abc123/messages" },
        message: { id: 41, body: { html: "<p>Book the train.</p>", plain: "Book the train." }, path: "/rooms/3/@41" } }
    end

    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
