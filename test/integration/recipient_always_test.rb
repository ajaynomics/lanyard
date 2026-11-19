require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# A recipient-scoped "Always" for telegram_send, and for send_email under
# "Ask before every email" (issue #150): it covers a call only when every
# recipient of it was granted, from a card, by a person. An every-call Always
# is never offered for either, and one already stored is never honoured.
class RecipientAlwaysTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper
  include VoipmsTestHelper

  TOKEN = "123456789:AAFakeTokenForTests_only-0123456789abcd".freeze
  GROUP = -1001234567890
  OTHER_GROUP = -1009876543210
  ROBIN = "robin@example.com".freeze
  EMAIL = { "to" => [ ROBIN ], "subject" => "Friday", "body" => "Two nights." }.freeze

  setup do
    install_sidecar_settings
    install_email_settings
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: TOKEN)
    sign_in_via_ajent
    @alice = User.find_by!(oidc_sub: "42") # tenancy-ok: the person the test signed in
    @agent = @alice.agents.sole
    @agent.update!(asks_every_email: true)
    @agent.create_telegram_bot!(vault_entry: "Desk bot", username: "desk_example_bot")
    @conversation = create_conversation(@agent)
    @next_call = 0
  end

  teardown do
    remove_fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "under Ask before every email, an Always for the one recipient lets the next email to them run" do
    first = receive_send("send_email", EMAIL)
    assert first.awaiting_person?
    assert_equal [ "recipient" ], first.always_choices
    first.approve!(by: @alice, always: "recipient")
    assert_equal [ ROBIN ], @agent.permissions.where(tool_name: "send_email").pluck(:recipient)

    assert_runs receive_send("send_email", EMAIL)
  end

  test "a Cc or a Bcc beside a granted recipient asks" do
    grant("send_email", ROBIN)
    assert_asks receive_send("send_email", EMAIL.merge("cc" => [ "casey@example.com" ]))
    assert_asks receive_send("send_email", EMAIL.merge("bcc" => [ "blake@example.com" ]))
    assert_asks receive_send("send_email", EMAIL.merge("to" => [ ROBIN, "casey@example.com" ]))
  end

  test "Ask before every email with no Always asks every time" do
    2.times { assert_asks receive_send("send_email", EMAIL) }
    with_setting(:access, :emails, [ ROBIN ]) { assert_asks receive_send("send_email", EMAIL) }
  end

  test "the granted Telegram chat runs, and another chat asks" do
    first = receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")
    assert first.awaiting_person?
    assert_equal [ "recipient" ], first.always_choices
    first.approve!(by: @alice, always: "recipient")
    assert_equal [ "Telegram chat #{GROUP}" ], @agent.permissions.where(tool_name: "telegram_send").pluck(:recipient)

    assert_runs receive_send("telegram_send", "chat" => GROUP, "text" => "Done.")
    assert_asks receive_send("telegram_send", "chat" => OTHER_GROUP, "text" => "Done.")
  end

  test "neither tool offers or takes an every-call Always" do
    [ [ "send_email", EMAIL ], [ "telegram_send", { "chat" => GROUP, "text" => "On it." } ] ].each do |name, arguments|
      invocation = receive_send(name, arguments)
      assert_not_includes invocation.always_choices, "agent", name
      assert_raises(ArgumentError, name) { invocation.approve!(by: @alice, always: "agent") }
      assert invocation.reload.awaiting_person?, name
      assert_empty @agent.permissions.where(tool_name: name), name
    end
  end

  test "an every-call Permission row already stored is not honoured, even where the install allows or approves everything" do
    grant("send_email", "")
    grant("telegram_send", "")
    [ {}, { approvals: "allow" }, { approve_everything: true } ].each do |policy|
      with_policy(policy) do
        assert_asks receive_send("send_email", EMAIL), policy
        assert_asks receive_send("telegram_send", "chat" => GROUP, "text" => "On it."), policy
      end
    end
  end

  test "a removed Always asks again" do
    email = grant("send_email", ROBIN)
    chat = grant("telegram_send", "Telegram chat #{GROUP}")
    assert_runs receive_send("send_email", EMAIL)
    assert_runs receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")

    delete agent_permission_path(@agent, email)
    delete agent_permission_path(@agent, chat)
    assert_empty @agent.permissions.reload

    assert_asks receive_send("send_email", EMAIL)
    assert_asks receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")
  end

  test "where the install approves everything, an ungranted recipient still asks and a granted one runs" do
    with_setting(:app, :approve_everything, true) do
      assert_asks receive_send("send_email", EMAIL)
      assert_asks receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")
      grant("send_email", ROBIN)
      grant("telegram_send", "Telegram chat #{GROUP}")
      assert_runs receive_send("send_email", EMAIL)
      assert_runs receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")
      assert_asks receive_send("send_email", EMAIL.merge("cc" => [ "casey@example.com" ]))
      assert_asks receive_send("telegram_send", "chat" => OTHER_GROUP, "text" => "On it.")
    end
  end

  test "other sends under their switches still take no Always at all" do
    install_voipms_settings
    @agent.update!(phone_number: "6475550123", asks_every_text: true)
    grant("send_text", "4165550199")
    assert_asks receive_send("send_text", "to" => "4165550199", "body" => "Your parcel is here.")
  ensure
    remove_voipms_settings
  end

  test "the card names what the Always covers" do
    email = receive_send("send_email", EMAIL.merge("cc" => [ "casey@example.com" ]))
    chat = receive_send("telegram_send", "chat" => GROUP, "text" => "On it.")

    html = card(email)
    assert_equal [ "Allow once", "Always with #{ROBIN} and casey@example.com", "Deny" ], buttons(html)
    assert_includes html.text, "only when every recipient"

    html = card(chat)
    assert_equal [ "Allow once", "Always for this chat", "Deny" ], buttons(html)
    assert_includes html.text, "Telegram chat #{GROUP} only"
  end

  test "the agent page says which recipients each Always covers, and marks an every-call one not used" do
    email = grant("send_email", ROBIN)
    chat = grant("telegram_send", "Telegram chat #{GROUP}")
    forged = grant("telegram_send", "")
    get agent_permissions_path(@agent)
    assert_select "#permission_#{email.id}", text: /With #{ROBIN} · added/
    assert_select "#permission_#{email.id}", text: /not used/, count: 0
    assert_select "#permission_#{chat.id}", text: /With Telegram chat #{GROUP} · added/
    assert_select "#permission_#{chat.id}", text: /not used/, count: 0
    assert_select "#permission_#{forged.id}", text: /not used: it is only ever "Always" for a recipient/
    assert_select "#permissions .ui-group__help", /only an "Always" for every recipient of it, or for its chat, lets it go without asking/
  end

  private
    def grant(name, recipient) = @agent.permissions.create!(tool_name: name, recipient: recipient, granted_by: @alice)

    def assert_asks(invocation, message = nil)
      assert invocation.awaiting_person?, message || "#{invocation.tool_name} should ask (#{invocation.state})"
    end

    def assert_runs(invocation)
      assert invocation.running?, "#{invocation.tool_name} should run (#{invocation.state})"
    end

    def with_policy(policy, &block)
      return yield if policy.empty?
      key, value = policy.first
      with_setting(:app, key, value, &block)
    end

    def card(invocation)
      Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
    end

    def buttons(html) = html.css(".ui-card__actions button").map { it.text.strip }

    def receive_send(name, arguments)
      @next_call += 1
      payload = invocation_payload(@conversation, tool: name, arguments: arguments, call_id: "send_#{@next_call}")
      Invocation.receive(@conversation.reload, task_id: payload[:taskId], call_id: payload[:callId], tool: name,
        arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: payload[:callId])
    end
end
