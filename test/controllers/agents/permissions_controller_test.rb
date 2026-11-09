require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"
require_relative "../../test_helpers/bluebubbles_test_helper"

class Agents::PermissionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include BluebubblesTestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @conversation = create_conversation(@agent)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(body: { rung: true }.to_json)
  end
  teardown do
    remove_sidecar_settings
    remove_email_settings
  end

  test "the page says when the install allows everything" do
    get agent_permissions_path(@agent)
    assert_select ".ui-group__help", text: /asks you first/
    with_setting(:app, :approvals, "allow") { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", text: /This install allows everything: Assistant does all of it without asking you/
    with_setting(:app, :approve_everything, true) { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", text: /This install approves everything: Assistant does all of it without asking you\. Each call is still recorded in its thread/
  end

  test "it names what asks every time, and that approving everything covers it" do
    install_bluebubbles_settings
    @agent.update!(tool_names: @agent.tool_names | %w[ imessage_send ])
    with_setting(:app, :approvals, "allow") { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", text: /To iMessage send it still asks every time\./
    with_setting(:app, :approve_everything, true) { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", text: /without asking you, even iMessage send\./
  ensure
    remove_bluebubbles_settings
  end

  test "the card offers once, always for the agent, always with the recipient, and deny" do
    invocation = send_email("hotel@acme.example")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "waiting", entries: [], more: false }.to_json)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => invocation.call_id, "name" => "send_email" } ])

    get conversation_path(@conversation)

    assert_equal [ "Allow once", "Always for this agent", "Always with hotel@acme.example", "Deny" ],
      css_select(".approval .ui-card__actions button").map { it.text.strip }
  end

  test "what Always covers comes from the call, not the form" do
    invocation = send_email("hotel@acme.example")

    post conversation_invocation_approval_path(@conversation, invocation),
      params: { decision: "approve", always: "recipient", recipient: "anyone@elsewhere.example", tool_name: "change_yourself" }

    assert_redirected_to conversation_path(@conversation)
    assert_equal [ [ "send_email", "hotel@acme.example" ] ], @agent.permissions.pluck(:tool_name, :recipient)
  end

  test "an Always the call does not offer is refused, and nothing is decided" do
    invocation = @conversation.invocations.create!(task_id: "7", call_id: "c9", tool_name: "change_yourself",
      arguments: { "name" => "Sam" }, digest: "d", state: :awaiting_person, expires_at: 1.hour.from_now)

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", always: "agent" }

    assert_response :bad_request
    assert invocation.reload.awaiting_person?
    assert_empty @agent.permissions
  end

  test "the agent's page lists each Always, and removing one makes it ask again" do
    every = @agent.permissions.create!(tool_name: "forget_note", granted_by: @agent.user)
    @agent.permissions.create!(tool_name: "send_email", recipient: "hotel@acme.example", granted_by: @agent.user)

    get agent_permissions_path(@agent)
    assert_select "#permissions li", 2
    assert_select "#permissions li", /Forget note\s*Every time · added/
    assert_select "#permissions li", /Send email\s*With hotel@acme.example · added/
    assert_select "#permissions button[data-turbo-confirm=?]", "Ask again before send email with hotel@acme.example?", "Remove"
    assert_select "#permissions .ui-group__help", /To change yourself and sign in with saved password it asks every time/

    delete agent_permission_path(@agent, every)
    assert_redirected_to agent_permissions_path(@agent)
    assert_equal [ "send_email" ], @agent.permissions.pluck(:tool_name)
  end

  test "another person's agent's Always is not found" do
    theirs = create_user(name: "Mallory").agents.sole
    permission = theirs.permissions.create!(tool_name: "forget_note", granted_by: theirs.user)

    delete agent_permission_path(theirs, permission)

    assert_response :not_found
    assert Permission.exists?(permission.id) # tenancy-ok: the test checks the record survived
  end

  private
    def send_email(to)
      arguments = { "to" => [ to ], "subject" => "Friday", "body" => "Two nights." }
      payload = invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: "c1")
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "c1", tool: "send_email", arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: "c1")
    end
end
