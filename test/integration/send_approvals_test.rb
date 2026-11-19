require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/voipms_test_helper"
require_relative "../test_helpers/bluebubbles_test_helper"
require_relative "../test_helpers/concourse_test_helper"

class SendApprovalsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include VoipmsTestHelper
  include BluebubblesTestHelper
  include ConcourseTestHelper

  SENDS = {
    "send_email" => [ :asks_every_email, { "to" => [ "robin@example.com", "hotel@example.net" ], "subject" => "Friday", "body" => "Two nights.\nKeep this last line." } ],
    "send_text" => [ :asks_every_text, { "to" => "4165550199", "body" => "Your parcel is here.\nKeep this last line." } ],
    "imessage_send" => [ :asks_every_imessage, { "chat" => FAMILY, "bubbles" => [ "Dinner at 7, at ours", "Bring the dog" ] } ],
    "concourse_send" => [ :asks_every_concourse_send, { "to" => "acme/travel", "text" => "Find a train.\nDo not book it.", "network" => "acme" } ]
  }.freeze

  setup do
    install_sidecar_settings
    install_email_settings
    install_voipms_settings
    install_bluebubbles_settings
    stub_bluebubbles
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the signed-in person's agent
    @agent.update!(phone_number: "6475550123", tool_names: @agent.tool_names | %w[ imessage_send ])
    @conversation = create_conversation(@agent)
    create_concourse_agent(@agent)
    @next_call = 0
  end

  teardown do
    remove_bluebubbles_settings
    remove_voipms_settings
    remove_email_settings
    remove_sidecar_settings
  end

  test "four independent switches start off, save, survive reload, and keep old Always answers" do
    grant = @agent.permissions.create!(tool_name: "send_email", granted_by: @agent.user)
    other = @agent.user.personal_workspace.agents.create!(user: @agent.user, name: "Helper", instructions: "Help.", model: @agent.model)
    get agent_permissions_path(@agent)
    SENDS.each_value do |flag, _|
      get agent_permissions_path(@agent)
      assert_select "input#agent_#{flag}[role=switch]:not([checked])", 1
      patch agent_path(@agent), params: { agent: { flag => "1" } }, headers: { "HTTP_REFERER" => agent_permissions_url(@agent) }
      assert_redirected_to agent_permissions_path(@agent)
      assert @agent.reload.public_send(flag)
      assert_not other.reload.public_send(flag)
      assert_equal 1, SENDS.values.count { |setting, _| @agent.public_send(setting) }
      get agent_permissions_path(@agent)
      assert_select "input#agent_#{flag}[checked]", 1
      patch agent_path(@agent), params: { agent: { flag => "0" } }, headers: { "HTTP_REFERER" => agent_permissions_url(@agent) }
      assert_not @agent.reload.public_send(flag)
    end
    assert_equal [ grant.id ], @agent.permissions.pluck(:id)
  end

  test "one send switch forces only its tool to ask under both permissive install policies" do
    SENDS.each do |name, (flag, arguments)|
      @agent.update!(flag => true)
      with_setting(:app, :approve_everything, true) do
        invocation = receive_send(name, arguments)
        assert invocation.awaiting_person?, name
        assert_equal scoped_always(name), invocation.always_choices
        assert policy_for(name, arguments).every_time?
        assert policy_for(name, arguments).even_approving_everything?
        SENDS.except(name).each do |other, (_, values)|
          assert @agent.allows?(policy_for(other, values)), "#{flag} must not hold #{other}"
        end
      end
      with_setting(:app, :approvals, "allow") do
        assert receive_send(name, arguments).awaiting_person?, name
      end
      @agent.update!(flag => false)
      with_setting(:app, :approve_everything, true) do
        assert receive_send(name, arguments).running?, "off restores #{name}'s install policy"
      end
    end
  end

  # Email's Always with recipients still holds while on (#150), but this grants
  # one of its two recipients, so the call asks all the same.
  test "both kinds of old Always are ignored while on, and restored while off" do
    SENDS.each do |name, (flag, arguments)|
      [ "", policy_for(name, arguments).recipients.first || arguments["chat"] ].each do |recipient|
        @agent.permissions.create!(tool_name: name, recipient: recipient, granted_by: @agent.user)
        @agent.update!(flag => true)
        invocation = receive_send(name, arguments)
        assert invocation.awaiting_person?, name
        assert_equal scoped_always(name), invocation.always_choices
        @agent.update!(flag => false)
        expected = Tool.const_get(name.camelize).every_time? ? :awaiting_person? : :running?
        # Email names two recipients, so a recipient grant covers both only
        # once each has been granted, unlike an agent-wide answer.
        if name == "send_email" && recipient.present?
          @agent.permissions.create!(tool_name: name, recipient: arguments["to"].last, granted_by: @agent.user)
        end
        assert receive_send(name, arguments).public_send(expected), name
        @agent.permissions.destroy_all
      end
    end
  end

  test "email to an admitted person also waits when its switch is on" do
    @agent.update!(asks_every_email: true)
    with_setting(:access, :emails, [ "robin@example.com" ]) do
      invocation = receive_send("send_email", "to" => [ "robin@example.com" ], "subject" => "Friday", "body" => "Two nights.")
      assert invocation.awaiting_person?
      assert_equal [ "recipient" ], invocation.always_choices
      @agent.update!(asks_every_email: false)
      assert receive_send("send_email", invocation.arguments).running?
    end
  end

  test "cards show exact recipients and words, offer only once, deny or email's Always with its recipients, and reject a forged Always" do
    SENDS.each do |name, (flag, arguments)|
      @agent.update!(flag => true)
      invocation = receive_send(name, arguments)
      html = Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      offered = scoped_always(name).any? ? [ "Always with #{arguments["to"].to_sentence}" ] : []
      assert_equal [ "Allow once", *offered, "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
      arguments.each_value do |value|
        Array(value).each { assert_includes html.text, it }
      end
      assert_includes html.text, "asks every time"
      assert_includes html.at_css(".ui-card__title").text, "as #{@agent}" unless name == "imessage_send"
      (%w[ agent recipient ] - scoped_always(name)).each do |always|
        post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve", always: always }
        assert_response :bad_request
        assert invocation.reload.awaiting_person?
        assert_empty @agent.permissions
      end
      post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve" }
      assert_redirected_to conversation_path(@conversation)
      assert invocation.reload.approved?
      @agent.update!(flag => false)
    end
  end

  test "a paused Always is marked, and the page names enabled sends under approve everything" do
    @agent.update!(asks_every_email: true)
    grant = @agent.permissions.create!(tool_name: "send_email", granted_by: @agent.user)
    with_setting(:app, :approve_everything, true) { get agent_permissions_path(@agent) }
    assert_select "#permission_#{grant.id}", /not used: Assistant is set to ask before every email/
    assert_select "#permissions .ui-group__help", /To change yourself, add routine, send email, and ask outside for sign in it still asks every time/
    @agent.update!(asks_every_email: false)
    get agent_permissions_path(@agent)
    assert_select "#permission_#{grant.id}", text: /not used/, count: 0
  end

  test "switches belong to the signed-in person's agent and cannot be changed by the model" do
    theirs = create_user(name: "Mallory").agents.sole
    patch agent_path(theirs), params: { agent: { asks_every_email: "1" } }
    assert_response :not_found
    assert_not theirs.reload.asks_every_email?
    args = { "asks_every_email" => true }
    payload = invocation_payload(@conversation, tool: "change_yourself", arguments: args)
    outcome = Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId],
      tool: "change_yourself", arguments: args, digest: payload[:digest])
    assert outcome[:isError]
    assert_not @agent.reload.asks_every_email?
    assert_not Tool::CampfireSay.ancestors.include?(Tool::AsksEverySend)
    assert_nil Tool::ConcourseReply.asks
  end

  private
    # Under its switch, email alone still takes an Always with its recipients (#150).
    def scoped_always(name) = name == "send_email" ? [ "recipient" ] : []

    def policy_for(name, arguments)
      Tool.const_get(name.camelize).new(@conversation.invocations.build(tool_name: name, arguments: arguments))
    end

    def receive_send(name, arguments)
      @next_call += 1
      @conversation.reload
      payload = invocation_payload(@conversation, tool: name, arguments: arguments, call_id: "send_#{@next_call}")
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: name, arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: payload[:callId])
    end
end
