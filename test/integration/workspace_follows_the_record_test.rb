require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The phone keeps a web view per tab, and its notices come from every one of
# the person's workspaces, so the workspace a session last showed is often not
# the one a request is about. A request about one card, thread or agent is
# allowed by whether the person is in that record's workspace; the session's
# workspace only chooses what the lists show. Bob is in his own workspace and
# in "Garden club", which Alice owns; Alice's own workspace is out of his reach.
class WorkspaceFollowsTheRecordTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  APP = { "User-Agent" => "NativeSignIn/1; APNs/production; Lanyard/1.0(42); Hotwire Native iOS; Turbo Native iOS; bridge-components: [alert button form haptic menu share toast approval tab-badge notification-token]" }.freeze
  NOTICE = APP.merge("Accept" => "application/json", "Sec-Fetch-Site" => "same-origin").freeze
  STALE_TAB = APP.merge("Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml").freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice", email: "alice@example.com")
    sign_in_via_ajent(name: "Bob")
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @bob.start_agent("Pip") if @bob.agents.none?
    @garden = Workspace.create!(name: "Garden club")
    @garden.memberships.create!(user: @alice, role: "owner")
    @bobs_membership = @garden.memberships.create!(user: @bob, role: "member")
    @fern = create_conversation(@alice.start_agent("Fern", workspace: @garden), durable_id: "50")
    @pip = create_conversation(@bob.personal_workspace.agents.sole, durable_id: "12")
    @alices_own = create_conversation(@alice.personal_workspace.agents.sole, durable_id: "99")
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(status: 200, body: { rung: true }.to_json)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/submissions}).to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+}).to_return(status: 200, body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end
  teardown { remove_sidecar_settings }

  test "Decline on a notice from another of Bob's workspaces decides the card, and leaves his phone where it was" do
    card = waiting(@fern, "forget_note", { "key" => "bed" })

    post conversation_invocation_approval_path(@fern, card), params: { decision: "deny", version: version(card) }, as: :json, headers: NOTICE

    assert_response :ok
    assert card.reload.denied?
    assert_equal @bob, card.approval.decided_by
    assert_equal @bob.personal_workspace.id, session[:workspace_id], "a notice's answer is not a page he opened"
  end

  test "Allow on a notice from another of his workspaces allows the small card shown" do
    card = waiting(@fern, "forget_note", { "key" => "bed" })

    post conversation_invocation_approval_path(@fern, card), params: { decision: "approve", version: version(card) }, as: :json, headers: NOTICE

    assert_response :ok
    assert card.reload.approved?
  end

  test "Reply on a notice from another of his workspaces is accepted" do
    post conversation_submissions_path(@fern), params: { content: "Water them at six", request_id: "notice-1" }, as: :json, headers: NOTICE

    assert_response :accepted
    assert_requested :post, "#{SIDECAR}/v1/conversations/50/submissions"
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end

  test "a message sent from a tab still showing another workspace's thread is sent, after another tab moved him" do
    get conversation_path(@fern), headers: APP
    assert_equal @garden.id, session[:workspace_id]
    get approval_path(waiting(@pip, "forget_note", { "key" => "own" })), headers: APP
    assert_equal @bob.personal_workspace.id, session[:workspace_id], "the Needs you tab opened one of his own cards"

    post conversation_submissions_path(@fern), params: { content: "Back to the beds", request_id: "stale-1" }, headers: STALE_TAB

    assert_response :success
    assert_requested :post, "#{SIDECAR}/v1/conversations/50/submissions"
  end

  test "Allow in a thread left open on another workspace's tab decides its card" do
    card = waiting(@fern, "forget_note", { "key" => "bed" })

    post conversation_invocation_approval_path(@fern, card), params: { decision: "deny" }, headers: APP

    assert_redirected_to conversation_path(@fern)
    assert card.reload.denied?
  end

  test "Needs you lists every card Bob may answer across his workspaces, each naming its workspace, and the badge counts the same" do
    mine = [ waiting(@pip, "forget_note", { "key" => "one" }), waiting(@pip, "forget_note", { "key" => "two" }, call_id: "toolu_2") ]
    theirs = waiting(@fern, "forget_note", { "key" => "bed" })
    waiting(@alices_own, "forget_note", { "key" => "secret" })

    get approvals_path, headers: APP

    assert_response :success
    assert_select "#approvals li.conversation-row", count: 3
    (mine + [ theirs ]).each { assert_select "a[href=?]", approval_path(it) }
    assert_select "##{ActionView::RecordIdentifier.dom_id(theirs, :waiting)} .conversation-row__title", text: "Garden club"
    assert_select "##{ActionView::RecordIdentifier.dom_id(mine.first, :waiting)} .conversation-row__title", text: @bob.personal_workspace.to_s
    assert_select "#app_badge[data-badge-count-value='3']", visible: :all
    assert_equal 3, @bob.needs_you.size

    get workspace_path(@garden)
    get approvals_path, headers: APP
    assert_select "#approvals li.conversation-row", count: 3
    assert_select "#app_badge[data-badge-count-value='3']", visible: :all
  end

  test "someone in only their own workspace sees no workspace names on Needs you" do
    @bobs_membership.destroy!
    card = waiting(@pip, "forget_note", { "key" => "one" })

    get approvals_path, headers: APP

    assert_select "##{ActionView::RecordIdentifier.dom_id(card, :waiting)} .conversation-row__title", count: 0
  end

  test "a card, thread or agent in a workspace Bob is not in is not found, from a notice or a page, and decides nothing" do
    card = waiting(@alices_own, "forget_note", { "key" => "secret" })

    post conversation_invocation_approval_path(@alices_own, card), params: { decision: "deny", version: version(card) }, as: :json, headers: NOTICE
    assert_response :not_found
    post conversation_invocation_approval_path(@alices_own, card), params: { decision: "deny" }, headers: APP
    assert_response :not_found
    post conversation_submissions_path(@alices_own), params: { content: "Hello", request_id: "x-1" }, as: :json, headers: NOTICE
    assert_response :not_found
    patch agent_path(@alices_own.agent), params: { agent: { title: "Taken" } }
    assert_response :not_found

    assert card.reload.awaiting_person?
    assert_nil @alices_own.agent.reload.title
    assert_not_requested :post, "#{SIDECAR}/v1/conversations/99/submissions"
    assert_equal @bob.personal_workspace.id, session[:workspace_id]
  end

  test "removed from Garden club, Bob's notice answers and stale tab are not found there" do
    card = waiting(@fern, "forget_note", { "key" => "bed" })
    @bobs_membership.destroy!

    post conversation_invocation_approval_path(@fern, card), params: { decision: "deny", version: version(card) }, as: :json, headers: NOTICE
    assert_response :not_found
    post conversation_submissions_path(@fern), params: { content: "Still here?", request_id: "gone-1" }, headers: STALE_TAB
    assert_response :not_found

    assert card.reload.awaiting_person?
    assert_not_includes @bob.needs_you, card
  end

  private
    def waiting(conversation, tool, arguments, call_id: "toolu_#{tool}")
      digest = Invocation.digest_for(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments)
      Invocation.receive(conversation, task_id: 7, call_id: call_id, tool: tool, arguments: arguments, digest: digest)
      conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person?, "#{tool} should wait for the person" }
    end

    def version(card) = Invocation::Card.new(card).version
end
