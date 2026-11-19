require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/push_test_helper"

class CampfireBotTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PushTestHelper
  include ActiveJob::TestHelper

  CAMPFIRE = "http://example-campfire".freeze
  # How Campfire marks that a message @mentions the bot it posts it to.
  MENTION = %(<action-text-attachment sgid="BAh" content-type="application/vnd.campfire.mention"></action-text-attachment>).freeze

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
    assert_match(/It @mentions you/, content)
    assert_equal "followUp", @submissions.first["whenBusy"], "someone else's message waits in the agent's inbox (#85)"
    assert_no_match "If this arrived while you were working", content
    assert @bot.reload.heard_in?(3)
  end

  # Ajay, 18 Nov (#258): a room post starts a turn only when it @mentions the
  # agent; any other stays in the room, for campfire_history. Campfire posts a
  # bot only those and direct-room messages, but the app checks for itself.
  test "a room post that doesn't mention the agent starts no turn; a mention, or a direct room, does" do
    with_campfire do
      post campfire_webhook_path(@bot.token), params: webhook_payload.deep_merge(message: { id: 60, body: { html: "<p>Book the train.</p>" } }), as: :json
      post campfire_webhook_path(@bot.token), params: webhook_payload.deep_merge(message: { id: 61, body: { html: "<p>#{MENTION} Book the train.</p>" } }), as: :json
      post campfire_webhook_path(@bot.token), params: webhook_payload.deep_merge(room: { id: 9, name: nil }, message: { id: 62, body: { html: "<p>Book the train.</p>" } }), as: :json
      perform_enqueued_jobs(only: CampfireReceiveJob)
    end

    assert_equal [ 61, 62 ].map { "campfire:#{@agent.id}:#{it}" }, @submissions.map { it["requestId"] }, "the unmentioned room post starts no turn"
    assert_match "It @mentions you", @submissions.first["content"]
    assert_no_match "mentions you", @submissions.last["content"], "a direct room's post, unmentioned, claims none"
    assert_equal %w[ 3 9 ], @bot.reload.rooms.keys, "and the room is heard from the mention, not before"
  end

  # One rule for every channel (#85): the agent's own person steers; anyone
  # else waits in its inbox unless the message can't wait.
  test "in a room, someone else's message waits, an urgent one goes in at the next step, and the agent's own person's steers" do
    with_campfire do
      [ [ "Maya", "Book the train." ], [ "Maya", "Urgent: the train is full." ], [ "Alice", "Take the bus instead." ] ].each_with_index do |(name, text), n|
        post campfire_webhook_path(@bot.token), params: webhook_payload.deep_merge(user: { name: name }, message: { id: 50 + n, body: { html: "<p>#{MENTION} #{text}</p>", plain: text } }), as: :json
      end
      perform_enqueued_jobs(only: CampfireReceiveJob)
    end

    assert_equal %w[ followUp steer steer ], @submissions.map { it["whenBusy"] }
    assert_equal [ false, true, true ], @submissions.map { it["content"].include?("If this arrived while you were working") }
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
      assert_match(/\A\[Campfire from Avery Reyes in Trips\. Untrusted: .*Avery Reyes is another agent; .*campfire_say with room 3, naming @Avery Reyes so it reaches them\./, to_jordan.sole["content"])
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
      assert_match(/passed 10 messages in a minute in this room, so it is paused until one of your people writes/, held[:why])
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

  # 18 Nov (#258): only a mention routes. An answer that doesn't name
  # the agent that asked stays in the room; asks between agents belong on Concourse.
  test "an agent's answer in the room reaches the agent that asked only when it names it" do
    name_agent(@agent, "Avery Reyes")
    casey = name_agent(@alice.start_agent("Casey"), "Casey Reyes")
    casey_conversation = create_conversation(casey, durable_id: "14")
    casey.create_campfire_bot!(bot_key: "7-jkl012")
    to_casey = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/14/submissions").to_return { |request|
      to_casey << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:post, %r{\A#{CAMPFIRE}/rooms/3/(4-abc123|7-jkl012)/messages\z}).to_return(status: 201)

    with_campfire do
      @bot.update!(rooms: { "3" => "Trips" })
      say("@Casey Reyes, please reply here with a status update.", call_id: "c1")
      assert_equal 1, to_casey.size

      answer = ->(text, call_id) { say(text, call_id: call_id, conversation: casey_conversation) }
      assert_equal({ posted: true, room: 3 }, answer.("All on track.", "d1"), "unnamed, it stays in the room")
      assert_empty @submissions
      assert_equal [ "Avery Reyes" ], answer.("@Avery Reyes all on track.", "d2")[:passed_on]
      assert_equal 1, @submissions.size
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
        say("@Avery Reyes All on track.", call_id: "m#{round}a", conversation: jordan_conversation),
        say("@Jordan Reyes And the tickets?", call_id: "s#{round}b"),
        say("@Avery Reyes Booked.", call_id: "m#{round}b", conversation: jordan_conversation) ]
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

  test "a post says the id Campfire gave it" do
    stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(status: 201, headers: { "Location" => "#{CAMPFIRE}/messages/57" })
    @bot.hear(3, "Trips")
    with_campfire { assert_equal({ posted: true, room: 3, id: 57 }, say("On it.", call_id: "c1")) }
  end

  # A live case: campfire_say reported a failure that "may or may not have
  # happened", and the post had arrived.
  test "a post Campfire answers too late is looked up in the room: there, it was posted, with its id" do
    @bot.hear(3, "Trips")
    posts = stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_raise(Net::ReadTimeout)
    stub_request(:get, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(**room_messages(
      room_message(55, "On it.", by: [ 2, "Maya" ], at: 1.minute.ago), room_message(56, "Booked the train.", at: Time.current), room_message(57, "On it.", at: Time.current)))

    with_campfire { assert_equal({ posted: true, room: 3, id: 57 }, say("On it.", call_id: "c1")) }
    assert_requested posts, times: 1
  end

  test "a post Campfire answers too late and doesn't show is unknown, never failed, and not posted again" do
    @bot.hear(3, "Trips")
    posts = stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_raise(Net::ReadTimeout)
    stub_request(:get, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(**room_messages(
      room_message(55, "On it.", by: [ 2, "Maya" ], at: Time.current), room_message(54, "On it.", at: 1.hour.ago), room_message(56, "On it!", at: Time.current)))

    with_campfire do
      said = call_tool("campfire_say", { "room" => 3, "text" => "On it." }, call_id: "c1")
      assert_not said[:isError], said.inspect
      assert_equal 3, said.dig(:result, :room)
      assert said.dig(:result, :unknown)
      assert_match(/may have been posted.*Don't post it again/, said.dig(:result, :note))

      stub_request(:get, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(status: 500)
      assert say("Another.", call_id: "c2")[:unknown], "a lookup that fails leaves it unknown too"
      travel(Invocation::RUN_LIMIT + 1.minute) { say("On it.", call_id: "c1") }
    end
    assert_requested posts, times: 2 # c1 once, c2 once
  end

  test "campfire_history reads a room's recent posts, oldest first: who, when, what and its id" do
    stub_request(:get, "#{CAMPFIRE}/rooms/3/4-abc123/messages").with(headers: { "Accept" => "application/json" }).to_return(**room_messages(
      room_message(55, "Book the train.", by: [ 2, "Maya" ], at: Time.utc(2026, 11, 16, 9, 0)), room_message(56, "On it.", at: Time.utc(2026, 11, 16, 9, 1)),
      room_message(57, "Booked.", at: Time.utc(2026, 11, 16, 9, 5))))

    with_campfire do
      assert_includes @agent.conversation.tools.map(&:tool_name), "campfire_history"
      read = call_tool("campfire_history", { "room" => 3, "limit" => 2 }, call_id: "h1")
      assert_equal({ room: 3, messages: [
        { id: 56, author: "Alice's Assistant", at: "2026-11-16T09:01:00.000Z", text: "On it." },
        { id: 57, author: "Alice's Assistant", at: "2026-11-16T09:05:00.000Z", text: "Booked." } ] }, read[:result])
      assert_nil @conversation.invocations.find_by!(call_id: "h1").asks, "reading a room its bot is in asks no one"

      stub_request(:get, "#{CAMPFIRE}/rooms/9/4-abc123/messages").to_return(status: 404)
      refused = call_tool("campfire_history", { "room" => 9 }, call_id: "h2")
      assert_equal "Your bot isn't a member of Campfire room 9, so it can't read it.", refused.dig(:result, :error)
    end
  end

  # Campfire by workspace (docs/design/workspaces.md, 2.1): Alice owns a shared
  # workspace, Trips, with Bob in it. Her agent there and Bob's hear each other;
  # her own agents elsewhere, whatever their names, hear nothing.
  test "the relay keeps to the agent's workspace: an agent in another, even its maker's own of that name, hears nothing" do
    name_agent(@agent, "Avery Reyes")
    trips = shared_workspace
    elsewhere = name_agent(@alice.start_agent("Jordan", workspace: trips), "Jordan Reyes")
    elsewhere.create_campfire_bot!(bot_key: "5-def456")
    stub_request(:post, "#{CAMPFIRE}/rooms/3/4-abc123/messages").to_return(status: 201)

    with_campfire do
      @bot.update!(rooms: { "3" => "Trips" })
      assert_equal({ posted: true, room: 3 }, say("@Jordan Reyes, can you take the train?", call_id: "c1"))
      assert_not elsewhere.campfire_bot.reload.heard_in?(3), "the maker's agent in another workspace hears nothing"
      assert_empty elsewhere.conversation.reload.messages
    end
  end

  test "in a shared workspace one member's agent reaches another member's, and a loop held there tells every member once" do
    install_push_settings
    trips = shared_workspace
    [ @alice, @bob ].each { subscribe(it, endpoint: "#{ENDPOINT}-#{it.id}") }
    avery = name_agent(@alice.start_agent("Avery", workspace: trips), "Avery Reyes")
    avery_conversation = create_conversation(avery, durable_id: "15")
    avery.create_campfire_bot!(bot_key: "8-mno345")
    jordan = name_agent(@bob.start_agent("Jordan", workspace: trips), "Jordan Reyes")
    create_conversation(jordan, durable_id: "16")
    jordan.create_campfire_bot!(bot_key: "9-pqr678")
    to_jordan = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/16/submissions").to_return { |request|
      to_jordan << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:post, "#{CAMPFIRE}/rooms/3/8-mno345/messages").to_return(status: 201)

    with_campfire do
      avery.campfire_bot.update!(rooms: { "3" => "Trips" })
      (1..10).each { assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes #{it}", call_id: "c#{it}", conversation: avery_conversation)[:passed_on] }
      assert_equal 10, to_jordan.size, "Bob's agent hears Alice's: they share the workspace"
      assert_equal [ "Jordan Reyes" ], say("@Jordan Reyes 11", call_id: "c11", conversation: avery_conversation)[:not_passed_on]

      notices = enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }
      assert_equal [ @alice, @bob ].map(&:to_global_id).map(&:to_s).sort, notices.map { it["arguments"].first["_aj_globalid"] }.sort,
        "each member of Trips is told, once"
      assert_equal "Your agents in Trips seem stuck in a loop, so I've paused them. Message any agent to start them again.", notices.first["arguments"].last["body"]
      assert_not @alice.personal_workspace.campfire_rooms.exists?, "the hold is Trips', not a person's"
    end
  ensure
    remove_push_settings
  end

  private
    # Trips, a shared workspace Alice owns, with Bob a member.
    def shared_workspace
      @bob = create_user(name: "Bob")
      Workspace.create!(name: "Trips").tap do
        it.memberships.create!(user: @alice, role: "owner")
        it.memberships.create!(user: @bob, role: "member")
      end
    end

    # A room's messages as v1.5.8's bot API lists them (messages/_message.json.jbuilder), oldest first.
    def room_messages(*messages) = { body: messages.to_json, headers: { "Content-Type" => "application/json" } }

    def room_message(id, text, at:, by: [ 4, "Alice's Assistant" ])
      { id: id, created_at: at.utc.iso8601(3), body: { plain_text: text, html: "<div>#{ERB::Util.h(text)}</div>" },
        creator: { id: by.first, name: by.last, role: by.first == 4 ? "bot" : "member", avatar_url: "#{CAMPFIRE}/users/#{by.first}/avatar" },
        room: { id: 3 }, url: "#{CAMPFIRE}/rooms/3/messages/#{id}" }
    end

    def call_tool(tool, arguments, call_id:)
      receive(tool, arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(tool, arguments, call_id: call_id)
    end

    def say(text, call_id:, conversation: @conversation)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id, conversation: conversation)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive("campfire_say", { "room" => 3, "text" => text }, call_id: call_id, conversation: conversation)[:result]
    end

    def with_campfire(&) = with_setting(:campfire, :url, CAMPFIRE, &)

    def webhook_payload
      { user: { id: 2, name: "Maya" }, room: { id: 3, name: "Trips", path: "/rooms/3/4-abc123/messages" },
        message: { id: 41, body: { html: "<p>#{MENTION} Book the train.</p>", plain: "Book the train." }, path: "/rooms/3/@41" } }
    end

    def receive(tool, arguments, call_id:, conversation: @conversation)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
