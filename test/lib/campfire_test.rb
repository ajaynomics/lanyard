require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The install makes, points and removes an agent's Campfire bot through stock
# ONCE Campfire's own pages. campfire_v1_5_8/ holds those pages as v1.5.8
# served them, recorded from the pinned image, so this fails when they no
# longer match; a page that has changed sends the person to set the bot up by
# hand, never a guess.
class CampfireTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  CAMPFIRE = "http://example-campfire".freeze
  RECORDED = Rails.root.join("test/lib/campfire_v1_5_8")
  # The made-up bots in the recorded bots page, by Campfire number.
  BOT_2 = "2-SynthBotKey1".freeze
  BOT_3 = "3-SynthBotKey2".freeze
  SIGNED_IN = { "Set-Cookie" => "session_token=signed%3D%3D--abc; path=/; httponly; samesite=lax" }.freeze

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    name_agent(@agent, "Iris")
  end

  test "with no Campfire address set, the administrator signs in to the office's own Campfire, as the bots post to it" do
    with_setting(:campfire, :url, nil) do
      with_setting(:campfire, :admin_email, "admin@example.com") do
        with_setting(:campfire, :admin_password, "correct-horse") do
          assert_not DurableAssistants::Campfire.admin?, "outside Kamal there is no office"
          with_kamal(container: "acme-web-7b474d4", version: "7b474d4") do
            assert DurableAssistants::Campfire.admin?
            assert_equal "http://acme-campfire", DurableAssistants::Campfire.url
            assert_equal DurableAssistants::Campfire.url, CampfireBot.url
            stub_request(:get, "http://acme-campfire/session/new").to_return(status: 503)
            assert_raises(DurableAssistants::Campfire::Error) { DurableAssistants::Campfire.admin.create_bot(name: "Iris", webhook_url: "http://acme-web/x") }
            assert_requested :get, "http://acme-campfire/session/new"
          end
        end
      end
    end
  end

  test "Make a bot signs in as the administrator, makes the bot named for the agent and pointed at its webhook, and keeps its key" do
    stub_campfire
    with_admin do
      get agent_channels_path(@agent)
      assert_select "button", text: "Make Iris a bot"
      post agent_campfire_bot_path(@agent)
    end

    bot = @agent.reload.campfire_bot
    assert_equal BOT_2, bot.bot_key
    assert_match(/Only the coordinator deletes rooms/, @agent.skills.find_by!(name: "campfire-rooms").body, "how rooms are used comes with the bot")
    assert_redirected_to agent_channels_path(@agent)
    assert_equal "Iris is a Campfire bot, in every open room.", flash[:notice]

    assert_requested :post, "#{CAMPFIRE}/session", body: { "email_address" => "admin@example.com", "password" => "correct-horse" }
    assert_requested(:post, "#{CAMPFIRE}/account/bots") { |request|
      form = Rack::Utils.parse_query(request.body)
      form["user[name]"] == "Iris" && form["user[webhook_url]"] == bot.webhook_url && request.headers["Cookie"].include?("session_token=") &&
        request.headers["Sec-Fetch-Site"] == "same-origin"
    }
  end

  test "a new agent is made a bot as it is made; when Campfire has changed, the agent is still made and its Channels page offers the bot" do
    stub_campfire(named: "Juno")
    with_admin do
      perform_enqueued_jobs(only: CampfireBotJob) do
        post agents_path, params: { agent: { name: "Juno", purpose: "Plans the trips." } }
      end
    end
    assert_equal BOT_2, Agent.find_by!(name: "Juno").campfire_bot.bot_key # tenancy-ok: the test's own agent

    stub_campfire(bots_new: "<form method='post' action='/account/bots'></form>")
    with_admin do
      perform_enqueued_jobs(only: CampfireBotJob) do
        post agents_path, params: { agent: { name: "Kit", purpose: "Plans the trips." } }
      end
      kit = Agent.find_by!(name: "Kit") # tenancy-ok: the test's own agent
      assert_nil kit.campfire_bot
      get agent_channels_path(kit)
      assert_select "p", text: /Kit has no Campfire bot yet/
      assert_select "button", text: "Make Kit a bot"
    end
  end

  test "a new webhook address is given to Campfire, and removing the bot deactivates it there" do
    stub_campfire
    bot = @agent.create_campfire_bot!(bot_key: BOT_2)
    with_admin do
      post agent_campfire_bot_token_path(@agent)
      assert_equal "New webhook address, and Campfire has it.", flash[:notice]
      assert_requested(:post, "#{CAMPFIRE}/account/bots/2") { |request|
        form = Rack::Utils.parse_query(request.body)
        form["_method"] == "patch" && form["user[webhook_url]"] == bot.reload.webhook_url
      }

      perform_enqueued_jobs(only: CampfireBotRemovalJob) { delete agent_campfire_bot_path(@agent) }
    end

    assert_nil @agent.reload.campfire_bot
    assert_requested(:post, "#{CAMPFIRE}/account/bots/2") { Rack::Utils.parse_query(it.body)["_method"] == "delete" }
  end

  test "deleting the agent deactivates its bot" do
    stub_campfire
    @agent.create_campfire_bot!(bot_key: BOT_2)
    with_admin { perform_enqueued_jobs(only: CampfireBotRemovalJob) { @agent.destroy! } }

    assert_requested(:post, "#{CAMPFIRE}/account/bots/2") { Rack::Utils.parse_query(it.body)["_method"] == "delete" }
  end

  test "a pasted key Campfire doesn't list can't steer another person's bot: no new webhook, no rooms, and deleting it removes nothing there" do
    stub_campfire
    stub_rooms
    bot = @agent.create_campfire_bot!(bot_key: "7-NotTheRealKey")
    with_admin do
      post agent_campfire_bot_token_path(@agent)
      assert_match "doesn't show this bot's key", flash[:alert]
      assert_match "doesn't show this bot's key", call_tool("campfire_rooms", {}, call_id: "c1")[:result][:error]
      assert_match "doesn't show this bot's key", call_tool("campfire_make_room", { name: "Lisbon trip" }, call_id: "c2")[:result][:error]
      perform_enqueued_jobs(only: CampfireBotRemovalJob) { delete agent_campfire_bot_path(@agent) }
    end

    assert_not CampfireBot.exists?(bot.id) # tenancy-ok: proves it is gone here
    assert_not_requested :post, %r{/account/bots/7}
    assert_not_requested :post, "#{CAMPFIRE}/rooms/closeds"
  end

  test "a key Campfire lists is vouched for once, a bot made here needs no check, and a key pasted again is checked again" do
    stub_campfire
    bot = @agent.create_campfire_bot!(bot_key: BOT_2)
    with_admin do
      assert_equal 2, bot.confirmed_campfire_id
      assert bot.reload.confirmed_at
      assert_equal 2, bot.confirmed_campfire_id
      assert_requested :get, "#{CAMPFIRE}/account/bots", times: 1

      bot.update!(bot_key: "7-NotTheRealKey")
      assert_nil bot.confirmed_at
      assert_raises(DurableAssistants::Campfire::Error) { bot.confirmed_campfire_id }

      bot.destroy!
      made = CampfireBot.make_for(@agent.reload)
      assert made.confirmed_at
    end
  end

  test "a changed form sends the person to set the bot up by hand, and makes nothing" do
    stub_campfire(bots_new: "<form method='post' action='/account/bots'><input name='user[title]'></form>")
    with_admin { post agent_campfire_bot_path(@agent) }

    assert_nil @agent.reload.campfire_bot
    assert_equal "Campfire's new bot form isn't as v1.5.8 had it, so this can't be done from here. Do it by hand in Campfire.", flash[:alert]
    assert_not_requested :post, "#{CAMPFIRE}/account/bots"
  end

  test "a wrong password says so" do
    stub_campfire
    stub_request(:post, "#{CAMPFIRE}/session").to_return(status: 401, body: recorded("session-new"))
    with_admin { post agent_campfire_bot_path(@agent) }

    assert_equal "Campfire refused the administrator's email and password.", flash[:alert]
    assert_nil @agent.reload.campfire_bot
  end

  test "without an administrator the key is pasted, and nothing is asked of Campfire" do
    with_setting(:campfire, :url, CAMPFIRE) do
      get agent_channels_path(@agent)
      assert_select "button", text: "Make Iris a bot", count: 0
      assert_select "input[name='campfire_bot[bot_key]']"

      @agent.create_campfire_bot!(bot_key: BOT_2)
      perform_enqueued_jobs { delete agent_campfire_bot_path(@agent) }
    end
    assert_not_requested :any, /example-campfire/
  end

  test "campfire_rooms lists the rooms the bot is in by number and name, from the bots page, and which have written to it" do
    stub_campfire
    conversation = create_conversation(@agent)
    bot = @agent.create_campfire_bot!(bot_key: BOT_2)
    bot.hear(3, "Trips")
    rooms = ->(call_id) {
      payload = invocation_payload(conversation, tool: "campfire_rooms", arguments: {}, call_id: call_id)
      receive = -> { Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: "campfire_rooms", arguments: {}, digest: payload[:digest]) }
      receive.()
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.().deep_symbolize_keys
    }

    with_admin do
      assert_includes @agent.reload.tools([]).map(&:tool_name), "campfire_rooms"
      assert_equal [ { room: 1, name: "All Talk", wrote_to_you: false }, { room: 3, name: "Trips", wrote_to_you: true } ], rooms.("c1")[:result][:rooms]
    end
    assert_requested :post, "#{CAMPFIRE}/session", body: hash_including("_method" => "delete"), times: 2 # signed out again, after vouching for the key and after listing

    with_setting(:campfire, :url, CAMPFIRE) do
      listed = rooms.("c2")[:result]
      assert_equal [ { room: 3, name: "Trips", wrote_to_you: true } ], listed[:rooms]
      assert_match(/Only the rooms that have written to you/, listed[:note])
    end
  end

  test "campfire_make_room makes a closed room with every person, the agent and the agents it names, and both may post there unasked" do
    stub_campfire
    stub_rooms
    robin = @agent.user.agents.create!(Agent.starter(:assistant).merge(name: "Robin", email_name: "robin"))
    robin_bot = robin.create_campfire_bot!(bot_key: BOT_3)
    bot = @agent.create_campfire_bot!(bot_key: BOT_2)

    with_admin do
      assert_includes @agent.reload.tools([]).map(&:tool_name), "campfire_make_room"
      result = call_tool("campfire_make_room", { name: "Lisbon trip", agents: [ "Robin" ] })[:result]
      assert_equal({ room: 3, name: "Lisbon trip", agents: [ "Iris", "Robin" ] }, result)
    end

    assert_requested(:post, "#{CAMPFIRE}/rooms/closeds") { |request|
      form = Rack::Utils.parse_nested_query(request.body)
      form["room"] == { "name" => "Lisbon trip" } && form["user_ids"].sort == %w[ 1 2 3 4 ]
    }
    assert bot.reload.heard_in?(3)
    assert robin_bot.reload.heard_in?(3)
  end

  test "a room an agent makes alone leaves the other bots out, and naming no such agent makes nothing" do
    stub_campfire
    stub_rooms
    @agent.create_campfire_bot!(bot_key: BOT_2)

    with_admin do
      call_tool("campfire_make_room", { name: "Lisbon trip" }, call_id: "c1")
      refused = call_tool("campfire_make_room", { name: "Rome", agents: [ "Nobody" ] }, call_id: "c2")
      assert_equal "No agent here is named Nobody.", refused[:result][:error]
    end

    assert_requested(:post, "#{CAMPFIRE}/rooms/closeds", times: 1) { |request|
      Rack::Utils.parse_nested_query(request.body)["user_ids"].sort == %w[ 1 2 4 ] # the administrator, Iris, Sam; not Robin's bot
    }
  end

  test "campfire_delete_room is the coordinator's alone: off until switched on, it deletes a closed room and every bot forgets it" do
    stub_campfire
    stub_rooms
    bot = @agent.create_campfire_bot!(bot_key: BOT_2)
    bot.hear(3, "Lisbon trip")

    with_admin do
      assert_not_includes @agent.reload.tools([]).map(&:tool_name), "campfire_delete_room"
      @agent.update!(tool_names: @agent.tool_names + [ "campfire_delete_room" ])
      assert_equal({ deleted: true, room: 3 }, call_tool("campfire_delete_room", { room: 3 })[:result])
    end

    assert_requested :post, "#{CAMPFIRE}/rooms/3", body: hash_including("_method" => "delete")
    assert_not bot.reload.heard_in?(3)
  end

  test "past Campfire's sign-in limit, the agent is told to try again later" do
    stub_campfire
    stub_request(:post, "#{CAMPFIRE}/session").to_return(status: 429)
    @agent.create_campfire_bot!(bot_key: BOT_2)

    refused = with_admin { call_tool("campfire_make_room", { name: "Lisbon trip" }) }
    assert_equal "Campfire allows 10 sign-ins in 3 minutes and has had them. Try again in a few minutes.", refused[:result][:error]
  end

  test "the main room, open to everyone, is never deleted from here" do
    stub_campfire
    stub_rooms
    @agent.create_campfire_bot!(bot_key: BOT_2)
    @agent.update!(tool_names: @agent.tool_names + [ "campfire_delete_room" ])

    refused = with_admin { call_tool("campfire_delete_room", { room: 1 }) }
    assert_equal "Room 1 is open to everyone; only a person deletes it, in Campfire.", refused[:result][:error]
    assert_not_requested :post, "#{CAMPFIRE}/rooms/1"
  end

  private
    def call_tool(tool, arguments, call_id: "c1")
      conversation = @conversation ||= create_conversation(@agent)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest]) }
      receive.()
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.().deep_symbolize_keys
    end

    # Recorded with two bots, Iris (2) and Robin (3), the administrator (1)
    # and one more person, Sam (4); room 3 closed, room 1 open to everyone.
    def stub_rooms
      html = { headers: { "Content-Type" => "text/html" } }
      stub_request(:get, "#{CAMPFIRE}/account/bots").to_return(body: recorded("bots-index-two"), **html)
      stub_request(:get, "#{CAMPFIRE}/rooms/closeds/new").to_return(body: recorded("rooms-closeds-new"), **html)
      stub_request(:post, "#{CAMPFIRE}/rooms/closeds").to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/rooms/3" })
      stub_request(:get, "#{CAMPFIRE}/rooms/3").to_return(body: recorded("room-closed"), **html)
      stub_request(:get, "#{CAMPFIRE}/rooms/1").to_return(body: recorded("room-open"), **html)
      stub_request(:get, "#{CAMPFIRE}/rooms/closeds/3/edit").to_return(body: recorded("rooms-closeds-edit"), **html)
      stub_request(:post, "#{CAMPFIRE}/rooms/3").to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/" })
    end

    def with_admin(&)
      with_setting(:campfire, :url, CAMPFIRE) do
        with_setting(:campfire, :admin_email, "admin@example.com") do
          with_setting(:campfire, :admin_password, "correct-horse", &)
        end
      end
    end

    def recorded(page) = RECORDED.join("#{page}.html").read

    # The recorded bots page lists one bot, Iris; `named` lists it under another name.
    def stub_campfire(bots_new: recorded("bots-new"), named: "Iris")
      html = { headers: { "Content-Type" => "text/html" } }
      stub_request(:get, "#{CAMPFIRE}/session/new").to_return(body: recorded("session-new"), **html)
      stub_request(:post, "#{CAMPFIRE}/session").to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/", **SIGNED_IN })
      stub_request(:get, "#{CAMPFIRE}/account/bots/new").to_return(body: bots_new, **html)
      stub_request(:post, "#{CAMPFIRE}/account/bots").to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/account/bots" })
      stub_request(:get, "#{CAMPFIRE}/account/bots").to_return(body: recorded("bots-index").sub("<strong>Iris</strong>", "<strong>#{named}</strong>"), **html)
      stub_request(:get, "#{CAMPFIRE}/account/bots/2/edit").to_return(body: recorded("bots-edit"), **html)
      stub_request(:post, "#{CAMPFIRE}/account/bots/2").to_return(status: 302, headers: { "Location" => "#{CAMPFIRE}/account/bots" })
    end
end
