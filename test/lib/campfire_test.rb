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
  SIGNED_IN = { "Set-Cookie" => "session_token=signed%3D%3D--abc; path=/; httponly; samesite=lax" }.freeze

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    name_agent(@agent, "Iris")
  end

  test "Make a bot signs in as the administrator, makes the bot named for the agent and pointed at its webhook, and keeps its key" do
    stub_campfire
    with_admin do
      get agent_channels_path(@agent)
      assert_select "button", text: "Make Iris a bot"
      post agent_campfire_bot_path(@agent)
    end

    bot = @agent.reload.campfire_bot
    assert_equal "2-SynthBotKey1", bot.bot_key
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
    assert_equal "2-SynthBotKey1", Agent.find_by!(name: "Juno").campfire_bot.bot_key # tenancy-ok: the test's own agent

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
    bot = @agent.create_campfire_bot!(bot_key: "2-SynthBotKey1")
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
    @agent.create_campfire_bot!(bot_key: "2-SynthBotKey1")
    with_admin { perform_enqueued_jobs(only: CampfireBotRemovalJob) { @agent.destroy! } }

    assert_requested(:post, "#{CAMPFIRE}/account/bots/2") { Rack::Utils.parse_query(it.body)["_method"] == "delete" }
  end

  test "a changed form sends the person to set the bot up by hand, and makes nothing" do
    stub_campfire(bots_new: "<form method='post' action='/account/bots'><input name='user[title]'></form>")
    with_admin { post agent_campfire_bot_path(@agent) }

    assert_nil @agent.reload.campfire_bot
    assert_equal "Campfire's new bot form isn't as v1.5.8 had it, so the bot can't be made here. Set it up by hand in Campfire.", flash[:alert]
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

      @agent.create_campfire_bot!(bot_key: "2-SynthBotKey1")
      perform_enqueued_jobs { delete agent_campfire_bot_path(@agent) }
    end
    assert_not_requested :any, /example-campfire/
  end

  test "campfire_rooms lists the rooms the bot is in by number and name, from the bots page, and which have written to it" do
    stub_campfire
    conversation = create_conversation(@agent)
    bot = @agent.create_campfire_bot!(bot_key: "2-SynthBotKey1")
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
    assert_requested :post, "#{CAMPFIRE}/session", body: hash_including("_method" => "delete") # signed out again

    with_setting(:campfire, :url, CAMPFIRE) do
      listed = rooms.("c2")[:result]
      assert_equal [ { room: 3, name: "Trips", wrote_to_you: true } ], listed[:rooms]
      assert_match(/Only the rooms that have written to you/, listed[:note])
    end
  end

  private
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
