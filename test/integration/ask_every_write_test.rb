require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A connector set to "Ask before every write" (McpServer#asks_every_write):
# each of its tools that may write asks every time, even where the install
# approves everything, never offers "Always", and an earlier "Always" no
# longer counts. Its read-only tools, and the switch's absence, change nothing.
class AskEveryWriteTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @user.agents.sole
    @conversation = create_conversation(@agent)
    @chat = create_mcp_server(@agent, name: "chat", tools: [ mcp_tool("read_channel", annotations: { readOnlyHint: true }),
      mcp_tool("post_message", properties: { text: { type: "string" } }), mcp_tool("delete_message", annotations: { readOnlyHint: false }) ])
    make_core(@agent, @chat)
    stub_mcp_server(calls: { "read_channel" => ->(_) { { content: [ { type: "text", text: "hello" } ] } },
      "post_message" => ->(_) { { content: [ { type: "text", text: "posted" } ] } } })
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/wakes}).to_return(body: { rung: true }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "off, a write asks with Always offered, and approving everything runs it unasked" do
    asking = receive("mcp__chat__post_message", { "text" => "Friday." }, "c1")
    assert asking.awaiting_person?
    assert_equal %w[ agent ], asking.always_choices
    assert_nil asking.tool_class.approval_title(asking.arguments), "the card keeps its usual title"
    assert_nil asking.tool_class.approval_note(asking.arguments)

    with_setting(:app, :approve_everything, true) do
      assert receive("mcp__chat__post_message", { "text" => "Saturday." }, "c2").succeeded?
    end
  end

  test "on, every write asks with no Always, even approving or allowing everything; a read still runs at once" do
    @chat.update!(asks_every_write: true)

    [ nil, [ :approve_everything, true ], [ :approvals, "allow" ] ].each_with_index do |setting, index|
      run = -> {
        post = receive("mcp__chat__post_message", { "text" => "Friday." }, "p#{index}")
        delete = receive("mcp__chat__delete_message", {}, "d#{index}")
        read = receive("mcp__chat__read_channel", {}, "r#{index}")
        assert post.awaiting_person?, "a post asks (#{setting.inspect})"
        assert delete.awaiting_person?, "a delete asks (#{setting.inspect})"
        assert_empty post.always_choices, "and offers no Always (#{setting.inspect})"
        assert read.succeeded?, "a read-only tool runs at once (#{setting.inspect})"
        assert_not read.tool_class.asks_every_write?
      }
      setting ? with_setting(:app, *setting, &run) : run.()
    end
  end

  test "an Always given before stops counting while the switch is on, and counts again when it is off" do
    @agent.permissions.create!(tool_name: "mcp__chat__post_message", granted_by: @user)
    assert receive("mcp__chat__post_message", { "text" => "One." }, "c1").succeeded?

    @chat.update!(asks_every_write: true)
    assert receive("mcp__chat__post_message", { "text" => "Two." }, "c2").awaiting_person?

    @chat.update!(asks_every_write: false)
    assert receive("mcp__chat__post_message", { "text" => "Three." }, "c3").succeeded?
  end

  test "an Always the card doesn't offer is refused" do
    @chat.update!(asks_every_write: true)
    invocation = receive("mcp__chat__post_message", { "text" => "Friday." }, "c1")

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", always: "agent" }

    assert_response :bad_request
    assert invocation.reload.awaiting_person?
    assert_empty @agent.permissions
  end

  test "a tool switched off stays off, on the connector or for the agent" do
    @chat.update!(asks_every_write: true, disabled_tools: %w[ delete_message ])
    @agent.switch_tool("mcp__chat__read_channel", false)

    names = @conversation.reload.definition[:tools].map { it[:name] }
    assert_includes names, "mcp__chat__post_message"
    assert_not_includes names, "mcp__chat__delete_message"
    assert_not_includes names, "mcp__chat__read_channel"
  end

  test "looked up when needed, a write called by its own name asks every time too" do
    @chat.update!(asks_every_write: true)
    @agent.core_connectors.delete_all

    with_setting(:app, :approve_everything, true) do
      assert_not_includes @conversation.reload.tools.map(&:tool_name), "mcp__chat__post_message"
      asking = receive("mcp__chat__post_message", { "text" => "Friday." }, "c1")
      assert asking.awaiting_person?
      assert_empty asking.always_choices
      assert_equal "Allow post message as chat?", asking.approval_title
      assert_equal "chat is set to ask before every write, so this asks every time.", asking.tool_class.approval_note(asking.arguments)
      assert receive("mcp__chat__read_channel", {}, "c2").succeeded?
    end
  end

  test "the connector's page has the switch, which saves, and names what asks every time" do
    get connector_path(@chat)
    assert_select "#connector_asks_every_write[role=switch]:not([checked])"
    assert_select "label[for=connector_asks_every_write]", /Ask before every write\s*For an account that writes as you/
    assert_select "h2", "Asks you first"

    patch connector_path(@chat), params: { connector: { asks_every_write: "1" } }
    assert @chat.reload.asks_every_write?

    get connector_path(@chat)
    assert_select "#connector_asks_every_write[role=switch][checked]"
    assert_select "h2", "Asks you every time"
    assert_select "h2", "Runs at once"

    patch connector_path(@chat), params: { connector: { asks_every_write: "0" } }
    assert_not @chat.reload.asks_every_write?
  end

  test "Permissions lists its writes as asking every time, and marks an earlier Always as not used" do
    @agent.permissions.create!(tool_name: "mcp__chat__post_message", granted_by: @user)
    get agent_permissions_path(@agent)
    assert_select "#permissions li", /Post message \(chat\)\s*Every time · added [^·]*\z/

    @chat.update!(asks_every_write: true)
    get agent_permissions_path(@agent)
    assert_select "#permissions li", /Every time · added .* · not used: chat asks before every write/
    assert_select ".ui-group__help", /To .*post message \(chat\).*delete message \(chat\).* it asks every time; these are never "Always"/
    with_setting(:app, :approve_everything, true) { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", /To .*post message \(chat\).*delete message \(chat\).* it still asks every time\./
    assert_select ".ui-group__help", { text: /read channel/, count: 0 }

    @agent.core_connectors.delete_all
    with_setting(:app, :approve_everything, true) { get agent_permissions_path(@agent) }
    assert_select ".ui-group__help", /post message \(chat\).* it still asks every time\./, "looked up when needed, it is listed too"
    assert_select "#permissions li", /not used: chat asks before every write/
  end

  test "an earlier Always for one Gmail account is marked not used when that account asks before every write" do
    with_google_app do
      %w[ personal work ].each do |name|
        @user.mcp_servers.create!(name: name, **McpServer.gallery_attributes("gmail"), refreshed_at: Time.current,
          oauth_tokens: { "access_token" => "access-#{name}", "refresh_token" => "refresh-#{name}", "expires_at" => 1.hour.from_now.to_i })
      end
      @agent.permissions.create!(tool_name: "mcp__work__create_draft", granted_by: @user)
      @user.mcp_servers.find_by!(name: "work").update!(asks_every_write: true)

      get agent_permissions_path(@agent)
    end
    assert_select "#permissions li", /not used: work asks before every write/
  end

  test "the card names the connector it acts as and why, with no Always" do
    @chat.update!(asks_every_write: true)
    invocation = receive("mcp__chat__post_message", { "text" => "Friday." }, "c1")
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/#{@conversation.durable_id}}).to_return(body: { status: "idle", entries: [], more: false }.to_json)
    @conversation.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "",
      tool_calls: [ { "id" => invocation.call_id, "name" => invocation.tool_name } ])

    get conversation_path(@conversation)

    assert_select ".approval .ui-card__title", "Allow post message as chat?"
    assert_select ".approval p.muted", "chat is set to ask before every write, so this asks every time."
    assert_equal [ "Allow once", "Deny" ], css_select(".approval .ui-card__actions button").map { it.text.strip }
  end

  private
    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    def receive(tool, arguments, call_id)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      perform_enqueued_jobs do
        Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
      end
      @conversation.invocations.find_by!(call_id: call_id)
    end
end
