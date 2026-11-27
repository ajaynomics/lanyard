require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

# Join Concourse, against the stand-in for Concourse's join (FakeConcourse):
# Concourse's page, the callback, and where the agent stands after.
class Agents::ConcourseJoinsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    @cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @concourse = stub_fake_concourse
  end
  teardown { Rails.cache = @cache }

  test "Join sends the browser to Concourse's page with every parameter the contract names" do
    get agent_channels_path(@agent)
    assert_select "#concourse", /Not joined/
    assert_select "#concourse form[action='#{agent_concourse_join_path(@agent)}'][data-turbo='false'] button", "Join Concourse"
    assert_select "input[name='concourse_agent[client_secret]']", count: 0

    post agent_concourse_join_path(@agent)

    assert_response :redirect
    location = URI(response.location)
    assert_equal "#{ORIGIN}/connect", "#{location.scheme}://#{location.host}#{location.path}"
    query = URI.decode_www_form(location.query).to_h
    assert_equal({ "response_type" => "code", "redirect_uri" => "http://localhost/concourse/callback", "code_challenge_method" => "S256",
                   "handle" => "assistant", "name" => "Assistant", "app_name" => DurableAssistants.config(:app, :name) },
      query.except("state", "code_challenge"))
    assert_operator Base64.urlsafe_decode64(query["state"]).bytesize * 8, :>=, 128
    assert_match(/\A[A-Za-z0-9_-]{43}\z/, query["code_challenge"])
  end

  test "approved, the agent keeps its encrypted client and waits; a minute later it is asked again and is connected" do
    join_and_approve

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "Assistant asked to join acme as acme/assistant. An owner there must approve it.", flash[:notice]
    concourse_agent = @agent.reload.concourse_agent
    assert concourse_agent.awaiting_approval?
    assert_equal [ "acme", "acme/assistant", "joined-2", "joined-secret-2" ], concourse_agent.values_at(:organization, :handle, :client_id, :client_secret)
    assert_not_includes ConcourseAgent.connection.select_value("SELECT client_secret FROM concourse_agents WHERE id = #{concourse_agent.id}"), "joined-secret-2"
    assert_not_includes @agent.tools([]), Tool::ConcourseSend

    follow_redirect!
    assert_select "#concourse", /Waiting for approval/
    assert_select "#concourse", /Waiting for an owner of acme to approve acme\/assistant\./
    assert_select "#concourse button", "Disconnect"

    @concourse.admit!
    get agent_channels_path(@agent)
    assert_select "#concourse", /Waiting for approval/, "asked again within the minute"

    travel 1.minute + 1.second do
      get agent_channels_path(@agent)
    end
    assert_select "#concourse", /Connected/
    assert_select "#concourse .channel__address", "acme/assistant"
    assert @agent.reload.concourse_agent.connected?
    assert_includes @agent.tools([]), Tool::ConcourseSend
  end

  test "an agent Concourse admits at once is connected when the browser comes back" do
    @concourse.admit_on_join = true

    join_and_approve

    assert_equal "Assistant joined acme as acme/assistant.", flash[:notice]
    assert @agent.reload.concourse_agent.connected?
  end

  test "a cancelled join consumes the pending join without enrolling" do
    @concourse.cancel = true
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    pending = ConcourseAgent::Join.from(session[:concourse_join])

    get callback

    assert_redirected_to agent_channels_path(@agent)
    assert_equal "You cancelled joining Concourse.", flash[:notice]
    assert_nil session[:concourse_join]
    assert_not pending.consume, "the server-side pending join was also used"
    get callback
    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_not_requested :post, "#{ORIGIN}/connect/token"
  end

  test "an expired join does not exchange its code" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse

    travel 10.minutes + 1.second do
      get callback
    end
    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_not_requested :post, "#{ORIGIN}/connect/token"
  end

  test "a superseded join does not complete a different agent's join" do
    second_agent = @agent.user.start_agent("Second assistant")
    post agent_concourse_join_path(@agent)
    superseded_callback = approve_on_concourse
    post agent_concourse_join_path(second_agent)
    current_callback = approve_on_concourse

    get superseded_callback

    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_not_requested :post, "#{ORIGIN}/connect/token"
    get current_callback
    assert_redirected_to agent_channels_path(second_agent)
    assert second_agent.concourse_agents.sole.awaiting_approval?
    assert_nil @agent.reload.concourse_agent
  end

  test "a join whose pending record is gone does not exchange its code" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    Rails.cache.clear

    get callback

    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_not_requested :post, "#{ORIGIN}/connect/token"
  end

  test "a completed join is not processed again" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    pending = ConcourseAgent::Join.from(session[:concourse_join])
    get callback
    identity = @agent.reload.concourse_agents.sole
    assert_not pending.consume, "the server-side pending join was also used"

    get callback

    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_equal [ identity ], @agent.reload.concourse_agents.to_a
    assert_requested :post, "#{ORIGIN}/connect/token", times: 1
  end

  test "a pending join does not follow its agent to a new workspace" do
    owner = @agent.user
    destination = Workspace.create!(name: "Team")
    destination.memberships.create!(user: owner, role: :owner)
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse

    assert @agent.move_to(destination, by: owner)
    get workspace_path(destination)
    get callback

    assert_redirected_to settings_path
    assert_match(/doesn't match a join you started/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_not_requested :post, "#{ORIGIN}/connect/token"
  end

  test "a join started for an authorized agent uses that agent's workspace" do
    team = team_with_home("acme", owner: @agent.user, member: nil)
    assert_not_equal team.id, session[:workspace_id]

    join_and_approve

    assert_redirected_to agent_channels_path(@agent)
    assert_equal team.id, session[:workspace_id]
    assert @agent.reload.concourse_agents.sole.awaiting_approval?
  end

  test "a move while Concourse answers does not attach the new identity" do
    owner = @agent.user
    destination = Workspace.create!(name: "Team")
    destination.memberships.create!(user: owner, role: :owner)
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    exchange = lambda do |env|
      assert @agent.move_to(destination, by: owner)
      @concourse.call(env)
    end
    stub_request(:post, "#{ORIGIN}/connect/token").to_rack(exchange)

    get callback

    assert_match(/could not be saved here/, flash[:alert])
    assert_nil @agent.reload.concourse_agent
    assert_equal "retired", @concourse.agents.sole.status
  end

  test "a code Concourse refuses changes nothing" do
    post agent_concourse_join_path(@agent)
    callback = approve_on_concourse
    state = URI.decode_www_form(URI(callback).query).to_h["state"]

    get concourse_callback_path(code: "code-99", state: state)

    assert_equal "Concourse refused the join (invalid_grant). Start again.", flash[:alert]
    assert_nil @agent.reload.concourse_agent
  end

  test "a declined agent shows why; joining again retires it on Concourse and replaces it once the new one is in hand" do
    join_and_approve
    @concourse.decline!
    travel 1.minute + 1.second do
      get agent_channels_path(@agent)
    end
    assert_select "#concourse", /Declined/
    assert_select "#concourse", /acme declined acme\/assistant\./
    assert_select "#concourse button", "Join again"

    declined = @agent.reload.concourse_agent
    task = create_conversation(@agent).peer_tasks.create!(task_id: "t-1", peer: "acme/friend", direction: "inbound", state: "TASK_STATE_SUBMITTED", concourse_agent: declined)
    post agent_concourse_join_path(@agent)
    assert_match %r{\A#{ORIGIN}/connect\?}, response.location
    assert @agent.reload.concourse_agent.declined?, "kept until the new one is in hand: cancelling at Concourse loses nothing"

    get approve_on_concourse
    assert_equal [ declined ], @agent.reload.concourse_agents.to_a, "the same record, replaced in place, never a second one"
    assert_equal @concourse.agents.last.client_id, @agent.concourse_agent.client_id
    assert_equal declined, task.reload.concourse_agent, "its tasks stay with it"
    assert_equal "retired", @concourse.agents.first.status
  end

  test "cancelling a join again at Concourse keeps the agent as it was" do
    join_and_approve
    @concourse.decline!
    @agent.concourse_agent.update!(status: "declined")
    post agent_concourse_join_path(@agent)
    @concourse.cancel = true
    get approve_on_concourse
    assert_equal "You cancelled joining Concourse.", flash[:notice]
    assert @agent.reload.concourse_agent.declined?
  end

  test "a join that can't be saved here is retired on Concourse, not left with a secret nobody holds" do
    join = ConcourseAgent::Join.start(@agent)
    code = URI.decode_www_form(URI(Net::HTTP.get_response(URI(join.url(@agent)))["location"]).query).to_h.fetch("code")

    @agent.concourse_agents.define_singleton_method(:create!) { |**| raise ActiveRecord::RecordNotSaved, "no" }
    error = assert_raises(DurableAssistants::Concourse::Client::Error) { join.finish(@agent, code, joiner: @agent.user) }

    assert_equal "Assistant joined Concourse but could not be saved here, so it was taken off again. Start again.", error.message
    assert_equal "retired", @concourse.agents.last.status
    assert_nil @agent.reload.concourse_agent
  end

  test "joining an organization the agent is in already, or waiting for, changes nothing and retires the new credential" do
    join_and_approve
    first = @agent.reload.concourse_agent

    join_and_approve

    assert_equal "Assistant is in acme already, as acme/assistant, so nothing changed.", flash[:alert]
    assert_equal [ first ], @agent.reload.concourse_agents.to_a
    assert first.reload.awaiting_approval?
    assert_equal %w[ awaiting_approval retired ], @concourse.agents.map(&:status), "the second agent Concourse made is taken off again"
  end

  test "joining another organization adds an identity beside the first; the page lists both" do
    @concourse.admit_on_join = true
    join_and_approve
    @concourse.organization = "example"
    join_and_approve

    assert_equal "Assistant joined example as example/assistant.", flash[:notice]
    assert_equal [ %w[ acme acme/assistant ], %w[ example example/assistant ] ], @agent.reload.concourse_agents.map { [ it.organization, it.handle ] }
    assert @agent.concourse_agents.all?(&:admitted?)

    get agent_channels_path(@agent)
    @agent.concourse_agents.each do |concourse_agent|
      assert_select "##{ActionView::RecordIdentifier.dom_id(concourse_agent)} .channel__network-name", /#{concourse_agent.organization}\s+Connected/
      assert_select "form[action='#{agent_concourse_agent_path(@agent, concourse_agent)}'] button[aria-label='Disconnect from #{concourse_agent.organization}']"
    end
    assert_select "#concourse form[action='#{agent_concourse_join_path(@agent)}'] button", "Join another network"
    get new_agent_concourse_join_path(@agent)
    assert_select "li", /in example as example\/assistant/
    assert_select "form[action='#{agent_concourse_join_path(@agent)}'] button", "Join another network"
  end

  test "someone else's agent is not found" do
    other = create_user(name: "Robin").agents.sole

    post agent_concourse_join_path(other)

    assert_response :not_found
    assert_nil session[:concourse_join]
  end

  test "asked to join, an agent with join_concourse gives the page's link; one button there joins; once joined, both say so" do
    conversation = create_conversation(@agent)
    assert_nil conversation.tool("join_concourse")
    @agent.update!(tool_names: @agent.tool_names + [ "join_concourse" ])
    assert conversation.reload.tool("join_concourse")

    assert_equal({ link: "http://localhost#{new_agent_concourse_join_path(@agent)}",
                   say: "Give the person this link. On that page they join you to Concourse with one button." }, join_concourse(conversation, "c1"))

    get new_agent_concourse_join_path(@agent)
    assert_select "h1", "Join Concourse as Assistant"
    assert_select "form[action='#{agent_concourse_join_path(@agent)}'][data-turbo='false'] button", "Join Concourse"

    join_and_approve
    assert_equal({ joined: [ { network: "acme", address: "acme/assistant", status: "waiting for an owner of acme to approve" } ],
                   link: "http://localhost#{new_agent_concourse_join_path(@agent)}",
                   say: "Give the person this link. On that page they join you to another network on Concourse with one button." }, join_concourse(conversation, "c2"))
    get new_agent_concourse_join_path(@agent)
    assert_select "li", /in acme as acme\/assistant\s+\(waiting for an owner of acme to approve it\)/
    assert_select "form[action='#{agent_concourse_join_path(@agent)}'] button", "Join another network"
  end

  # A workspace's home network (docs/design/workspaces.md, 2.3 and 3): Team's is
  # `home`, Carol owns it and the signed-in person is a member. A join anywhere
  # else is a bridge, which speaks only once Carol approves it.
  test "a member's join outside the home network waits for the owner, who approves it on the Channels page; who and when is recorded and logged" do
    carol = create_user(name: "Carol")
    team = team_with_home("home", owner: carol)
    @concourse.admit_on_join = true

    join_and_approve

    assert_equal "Assistant joined acme as acme/assistant. acme is outside Team's home network, home, so it waits for Carol to approve it.", flash[:notice]
    bridge = @agent.reload.concourse_agents.sole
    assert bridge.admitted?, "Concourse admitted it"
    assert bridge.waiting_for_owner?
    assert_not_includes @agent.tools([]), Tool::ConcourseSend, "a bridge says nothing until the owner approves it"
    follow_redirect!
    assert_select "#concourse", /Waiting for Carol to approve this bridge to acme/
    assert_select "form[action='#{agent_concourse_agent_bridge_approval_path(@agent, bridge)}']", { count: 0 }, "only the owner approves"
    post agent_concourse_agent_bridge_approval_path(@agent, bridge)
    assert_response :not_found
    assert bridge.reload.waiting_for_owner?

    sign_in_via_ajent(subject: "sub-carol", email: "carol@example.com", name: "Carol")
    get workspace_path(team)
    get agent_channels_path(@agent)
    assert_select "form[action='#{agent_concourse_agent_bridge_approval_path(@agent, bridge)}'] button", "Approve the bridge to acme"
    logged = capture_log { post agent_concourse_agent_bridge_approval_path(@agent, bridge) }

    assert_redirected_to agent_channels_path(@agent)
    bridge.reload
    assert_equal carol, bridge.bridge_approved_by
    assert bridge.bridge_approved_at
    assert_not bridge.waiting_for_owner?
    assert_includes logged, "Concourse bridge #{bridge.id} of agent #{@agent.id} to acme approved by user #{carol.id}"
    assert_includes @agent.reload.tools([]), Tool::ConcourseSend
    follow_redirect!
    assert_select "#concourse", /A bridge to acme, outside home, approved by Carol/
  end

  test "a join to the home network, or the owner's own join outside it, needs nobody else's approval" do
    carol = create_user(name: "Carol")
    team = team_with_home("acme", owner: carol, member: nil)
    sign_in_via_ajent(subject: "sub-carol", email: "carol@example.com", name: "Carol")
    get workspace_path(team)
    @concourse.admit_on_join = true

    join_and_approve
    assert_equal "Assistant joined acme as acme/assistant.", flash[:notice]
    home = @agent.reload.concourse_agents.sole
    assert_not home.bridge?
    assert_nil home.bridge_approved_by

    @concourse.organization = "example"
    join_and_approve
    assert_equal "Assistant joined example as example/assistant, a bridge outside Team's home network, which you approved.", flash[:notice]
    bridge = @agent.concourse_agents.find_by!(organization: "example")
    assert_equal carol, bridge.bridge_approved_by
    assert_equal 2, @agent.reload.concourse_networks.size
  end

  test "another person's agent has no join page" do
    theirs = create_user(name: "Robin").agents.sole
    get new_agent_concourse_join_path(theirs)
    assert_response :not_found
  end

  private
    def join_concourse(conversation, call_id)
      payload = invocation_payload(conversation, tool: "join_concourse", arguments: {}, call_id: call_id)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: call_id, tool: "join_concourse",
        arguments: {}, digest: payload[:digest]).deep_symbolize_keys[:result]
    end

    # Join, the person approves on Concourse's page, and the browser comes back.
    def join_and_approve
      post agent_concourse_join_path(@agent)
      get approve_on_concourse
    end

    # Team, whose home network is `home`, owned by `owner`, with the
    # signed-in person a member (or, without one, its owner), working in it on
    # an agent of its own.
    def team_with_home(home, owner:, member: User.find_by!(oidc_sub: "42")) # tenancy-ok: test reads the person it signed in
      Workspace.create!(name: "Team", concourse_home: home).tap do |team|
        team.memberships.create!(user: owner, role: "owner")
        team.memberships.create!(user: member, role: "member") if member
        @agent = team.agents.create!(user: owner, name: "Assistant", instructions: "Help.", model: Agent.models.first)
        get workspace_path(team) if member
      end
    end

    def capture_log
      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      Rails.logger.broadcast_to(logger)
      yield
      output.string
    ensure
      Rails.logger.stop_broadcasting_to(logger)
    end

    def approve_on_concourse
      answer = Net::HTTP.get_response(URI(response.location))
      URI(answer["location"]).then { "#{it.path}?#{it.query}" }
    end
end
