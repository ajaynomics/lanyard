require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An Always with exact recipients in a browser (#150): a Telegram card offers
# "Always for this chat" and no Always for every call, an email card under
# "Ask before every email" offers Always with its recipients, and the agent's
# Permissions page names what each covers until it is removed.
class RecipientAlwaysSystemTest < ApplicationSystemTestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper

  TOKEN = "123456789:AAFakeTokenForTests_only-0123456789abcd".freeze
  GROUP = -1001234567890

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: TOKEN)
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @agent.update!(asks_every_email: true)
    @agent.create_telegram_bot!(vault_entry: "Desk bot", username: "desk_example_bot")
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:post, %r{#{SIDECAR}/v1/conversations/12/wakes}).to_return(body: { rung: true }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [ { id: "1", entryId: 1, role: "assistant", content: "",
        toolCalls: [ { id: "c1", name: "telegram_send" }, { id: "c2", name: "send_email" } ] } ], cursor: 1, more: false }.to_json)
  end

  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
    remove_email_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "each card offers Always only with its recipients, and Permissions names them until removed" do
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, "c1")
    receive("send_email", { "to" => [ "robin@example.com" ], "cc" => [ "casey@example.com" ], "subject" => "Friday", "body" => "Two nights." }, "c2")

    visit conversation_path(@conversation)
    assert_text "Always for this chat covers Telegram chat #{GROUP} only"
    assert_text "covers a message only when every recipient, in To, Cc and Bcc, is one of them"
    assert_no_button "Always for this agent"
    click_on "Always for this chat"
    click_on "Always with robin@example.com and casey@example.com"
    assert_no_selector ".approval .ui-card__actions"

    visit agent_permissions_path(@agent)
    within("#permissions") do
      assert_selector "li", text: /Telegram send\s*With Telegram chat #{GROUP} · added/
      assert_selector "li", text: /Send email\s*With robin@example.com · added/
      assert_selector "li", text: /Send email\s*With casey@example.com · added/
      assert_no_text "not used"
      within("li", text: /Telegram chat #{GROUP}/) { click_on "Remove" }
    end
    within("dialog#confirm[open]") { click_on "Remove" }
    assert_no_selector "li", text: /Telegram chat #{GROUP}/
    assert_equal [ "casey@example.com", "robin@example.com" ], @agent.permissions.reload.pluck(:recipient).sort
  end

  test "the switch lists the recipients that still go unasked, and Telegram its allowed chats, each removable there" do
    person = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    [ [ "send_email", "robin@example.com" ], [ "send_email", "casey@example.com" ], [ "telegram_send", "Telegram chat #{GROUP}" ] ]
      .each { |tool, recipient| @agent.permissions.create!(tool_name: tool, recipient: recipient, granted_by: person) }

    visit agent_permissions_path(@agent)
    within("section[aria-labelledby=sending_approvals]") do
      assert_text "except recipients you've always allowed"
      assert_selector "li", text: /robin@example.com\s*Sent without asking/
      assert_selector "li", text: /casey@example.com\s*Sent without asking/
      within("li", text: /robin@example.com/) { click_on "Remove" }
    end
    within("dialog#confirm[open]") { click_on "Remove" }
    within("section[aria-labelledby=sending_approvals]") do
      assert_no_text "robin@example.com"
      assert_text "casey@example.com"
    end

    visit agent_channels_path(@agent)
    within("#telegram") do
      assert_text "except to chats you've always allowed"
      within("li", text: /Telegram chat #{GROUP}\s*Sent without asking/) { click_on "Remove" }
    end
    within("dialog#confirm[open]") { click_on "Remove" }
    assert_current_path agent_channels_path(@agent)
    within("#telegram") { assert_no_text "Telegram chat #{GROUP}" }
    assert_equal [ [ "send_email", "casey@example.com" ] ], @agent.permissions.reload.pluck(:tool_name, :recipient)
  end

  private
    def receive(tool, arguments, call_id)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation.reload, task_id: payload[:taskId], call_id: call_id, tool: tool, arguments: arguments, digest: payload[:digest])
    end
end
