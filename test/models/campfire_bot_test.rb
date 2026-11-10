require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/push_test_helper"

class CampfireBotTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PushTestHelper
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
    assert_match(/Book the train\.\z/, words(content))
    assert_no_match(/mentions you/, content, "no mention in the HTML, none claimed")
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

  test "the office's Campfire and the app reach each other inside the host, with no address set; another Campfire is told the app's" do
    with_kamal(container: "acme-web-production-6f1c2a", destination: "production", version: "6f1c2a") do
      assert_equal "http://acme-campfire", CampfireBot.url
      assert_equal "http://acme-web/campfire/#{@bot.token}", @bot.webhook_url
      with_setting(:campfire, :url, "https://chat.example.com") do
        assert_equal "https://chat.example.com", CampfireBot.url
        assert_equal "#{DurableAssistants.config(:app, :url)}/campfire/#{@bot.token}", @bot.webhook_url
      end
    end
    assert_not CampfireBot.configured?, "outside Kamal, no Campfire unless named"
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

  test "a message naming another agent of the person's that is a bot reaches its thread, as long as they talk, until 10 in a minute stop the room and tell its person once" do
    install_push_settings
    subscribe(@alice)
    name_agent(@agent, "Avery Reyes")
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
      assert_match(/\A\[Campfire from Avery Reyes in Trips\. Untrusted: .*Avery Reyes is another agent; .*campfire_say with room 3;/, to_jordan.sole["content"])
      assert jordan.campfire_bot.reload.heard_in?(3), "Jordan answers there without asking"
      assert_empty stranger.conversation.reload.messages, "another person's agent of that name hears nothing"

      assert_equal({ posted: true, room: 3 }, say("Nobody named: @Jordan, @Jordan Reyess.", call_id: "c2"))
      travel 61.seconds
      (2..10).each { assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes #{it}", call_id: "c#{it + 1}")[:passed_on] }
      travel 61.seconds
      (11..20).each { assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes #{it}", call_id: "c#{it + 1}")[:passed_on] }
      assert_equal 20, to_jordan.size, "a slow exchange goes on as long as they like"
      assert_no_enqueued_jobs only: Push::DeliveryJob

      held = say("@Jordan Reyes 21", call_id: "c22")
      assert_equal [ "Jordan Reyes" ], held[:not_passed_on]
      assert_match(/passed 10 messages in a minute in this room, so it is paused until your person writes/, held[:why])
      notice = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }.sole["arguments"].last
      assert_equal "Your agents in Trips seem stuck in a loop, so I've paused them. Message any agent to start them again.", notice["body"]
      assert_equal "held", notice["kind"]
      travel 2.minutes
      assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes 22", call_id: "c23")[:not_passed_on], "held until the person writes, not for a minute"
      assert_equal 1, enqueued_jobs.count { it["job_class"] == "Push::DeliveryJob" }, "one notice a hold"
      assert_equal 20, to_jordan.size

      post campfire_webhook_path(@bot.token), params: webhook_payload, as: :json
      perform_enqueued_jobs(only: CampfireReceiveJob)
      assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes 23", call_id: "c24")[:passed_on]
      assert_equal 21, to_jordan.size
    end
  ensure
    remove_push_settings
  end

  test "an agent's answer in the room goes back to the agent that asked it there, named or not, until a person writes to it there" do
    name_agent(@agent, "Avery Reyes")
    casey = name_agent(@alice.start_agent("Casey"), "Casey Reyes")
    casey_conversation = create_conversation(casey, durable_id: "14")
    casey_bot = casey.create_campfire_bot!(bot_key: "7-jkl012")
    to_casey = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/14/submissions").to_return { |request|
      to_casey << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:post, %r{\A#{CAMPFIRE}/rooms/3/(4-abc123|7-jkl012)/messages\z}).to_return(status: 201)

    with_campfire do
      @bot.update!(rooms: { "3" => "Trips" })
      say("@Casey Reyes, please reply here with a status update.", call_id: "c1")
      assert_match(/what you post there reaches Avery Reyes/, to_casey.sole["content"])

      answer = ->(text, call_id) { say(text, call_id: call_id, conversation: casey_conversation) }
      assert_equal [ "Avery Reyes" ], answer.("All on track.", "d1")[:passed_on]
      assert_equal [ "Avery Reyes" ], answer.("One more thing: the tickets are booked.", "d2")[:passed_on]
      assert_equal 2, @submissions.size
      assert_match(/\A\[Campfire from Casey Reyes in Trips\..*\n\nAll on track\.\z/m, words(@submissions.first["content"]))

      post campfire_webhook_path(casey_bot.token), params: webhook_payload, as: :json
      perform_enqueued_jobs(only: CampfireReceiveJob)
      assert_equal({ posted: true, room: 3 }, answer.("Booked, Maya.", "d3"), "an answer to a person goes to no agent")
      assert_equal 2, @submissions.size
    end
  end

  test "a stopped room starts again when the person asks any agent, in the app, by email or by a routine; Concourse mail does not start it" do
    name_agent(@agent, "Avery Reyes")
    jordan = name_agent(@alice.start_agent("Jordan"), "Jordan Reyes")
    jordan_conversation = create_conversation(jordan, durable_id: "13")
    jordan.create_campfire_bot!(bot_key: "5-def456")
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:post, %r{\A#{CAMPFIRE}/rooms/3/(4-abc123|5-def456)/messages\z}).to_return(status: 201)
    hand_off = ->(round) {
      [ say("@Jordan Reyes, an update please.", call_id: "s#{round}a"),
        say("All on track.", call_id: "m#{round}a", conversation: jordan_conversation),
        say("And the tickets?", call_id: "s#{round}b"),
        say("Booked.", call_id: "m#{round}b", conversation: jordan_conversation) ]
    }

    spin = ->(round) { (hand_off.("#{round}a") + hand_off.("#{round}b") + hand_off.("#{round}c")).map { it[:passed_on].present? } }

    with_campfire do
      @bot.update!(rooms: { "3" => "Trips" })
      assert_equal [ true ] * 10 + [ false ] * 2, spin.(1)
      @conversation.submit("Ask the other agents for an update.", request_id: "p1")
      assert hand_off.(2).all? { it[:passed_on].present? }, "the person's word in the app starts it"
      travel 2.minutes
      spin.(3)
      @conversation.receive("Weekly check-in.", from: "your schedule (0 9 * * 1)", via: "Routine", answer: "Do it.", request_id: "p2", trusted: true)
      assert hand_off.(4).all? { it[:passed_on].present? }, "a routine they set starts it"
      travel 2.minutes
      spin.(5)
      @conversation.receive("How are the others?", from: "maya@example.com", via: "Email", answer: "Reply by email.", request_id: "p3")
      assert hand_off.(6).all? { it[:passed_on].present? }, "their email starts it"
      travel 2.minutes
      spin.(7)

      @conversation.receive("Ping.", from: "robin/agent", via: "Concourse mail", answer: "Reply on Concourse.", request_id: "p4")
      assert hand_off.(8).none? { it[:passed_on].present? }, "another agent's mail starts nothing"
    end
  end

  test "a person's mention of two agents reaches each once, through Campfire, and each is told it was mentioned" do
    jordan = name_agent(@alice.start_agent("Jordan"), "Jordan Reyes")
    jordan.conversation.update!(durable_id: "13", request_id: "r-13")
    jordan_bot = jordan.create_campfire_bot!(bot_key: "5-def456")
    to_jordan = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/13/submissions").to_return { |request|
      to_jordan << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    mention = %(<action-text-attachment sgid="BAh" content-type="application/vnd.campfire.mention"></action-text-attachment>)
    # As Campfire posts it to each bot: its own @name taken out of the plain text, the other's kept.
    payload = ->(plain) { { user: { id: 2, name: "Maya" }, room: { id: 3, name: "Trips" },
      message: { id: 50, body: { html: "<p>#{mention} and #{mention} welcome aboard</p>", plain: plain }, path: "/rooms/3/@50" } } }

    with_campfire do
      2.times do
        post campfire_webhook_path(@bot.token), params: payload.("and @Jordan Reyes welcome aboard"), as: :json
        post campfire_webhook_path(jordan_bot.token), params: payload.("@Assistant and  welcome aboard"), as: :json
      end
      perform_enqueued_jobs(only: CampfireReceiveJob)
    end

    assert_equal 1, @submissions.map { it["requestId"] }.uniq.size, "once per Campfire message, however often it is posted"
    assert_equal 1, to_jordan.map { it["requestId"] }.uniq.size
    assert_match(/It @mentions you; Campfire leaves your own name out of the text\./, to_jordan.first["content"])
    assert_match(/and @Jordan Reyes welcome aboard\z/, words(@submissions.first["content"]))
  end

  private

    def say(text, call_id:, conversation: @conversation)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id, conversation: conversation)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id, conversation: conversation)[:result]
    end

    def with_campfire(&) = with_setting(:campfire, :url, CAMPFIRE, &)

    def webhook_payload
      { user: { id: 2, name: "Maya" }, room: { id: 3, name: "Trips", path: "/rooms/3/4-abc123/messages" },
        message: { id: 41, body: { html: "<p>Book the train.</p>", plain: "Book the train." }, path: "/rooms/3/@41" } }
    end

    def receive(tool, arguments, call_id:, conversation: @conversation)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
