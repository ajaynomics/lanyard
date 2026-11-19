require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"
require_relative "../../test_helpers/voipms_test_helper"
require_relative "../../test_helpers/bluebubbles_test_helper"

# A member of a workspace who names one of its agents as their only outbound
# contact hears from that agent alone: every other agent of the workspace is
# refused mail, texts and notices to their address or number, naming the agent
# to go through. Another workspace's agents are not bound by it.
class Workspace::SoleContactTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include VoipmsTestHelper
  include BluebubblesTestHelper
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    install_email_settings
    install_voipms_settings
    @owner = create_user(name: "Olive")
    @client = create_user(name: "Quinn", email: "quinn@example.com")
    @harbour = Workspace.create!(name: "Harbour")
    @harbour.memberships.create!(user: @owner, role: "owner")
    @quinns = @harbour.memberships.create!(user: @client, role: "member")
    @ada = @owner.start_agent("Ada", workspace: @harbour, email_name: "ada")
    @bo = @owner.start_agent("Bo", workspace: @harbour, email_name: "bo")
    @ada.update!(phone_number: "6475550123")
    @bo.update!(phone_number: "6475550124")
    create_conversation(@ada, durable_id: "ada-1")
    create_conversation(@bo, durable_id: "bo-1")
    @quinns.update!(sole_contact: @ada, phone_number: "(416) 555-0111")
  end

  teardown do
    remove_voipms_settings
    remove_email_settings
  end

  test "another agent's mail to the member is refused, naming the agent to go through, even where everything is approved" do
    with_setting(:app, :approve_everything, true) do
      [ { "to" => [ "Quinn@Example.com" ] }, { "to" => [ "olive@example.com" ], "cc" => [ "quinn@example.com" ] },
        { "to" => [ "olive@example.com" ], "bcc" => [ "quinn@example.com" ] } ].each_with_index do |to, index|
        outcome = run_call(@bo, "send_email", { **to, "subject" => "Invoice", "body" => "Attached." }, call_id: "bo-#{index}")
        assert outcome[:isError], outcome.to_json
        assert_match "Quinn hears only from Ada in Harbour", outcome[:result][:error]
        assert_match "Go through Ada", outcome[:result][:error]
      end
    end
    assert_empty ActionMailer::Base.deliveries
  end

  test "it is refused before anyone is asked, and a send already approved is refused when it would go" do
    outcome = receive(@bo, "send_email", { "to" => [ "quinn@example.com" ], "subject" => "Hi", "body" => "Hello." }, call_id: "bo-ask")
    assert outcome[:isError], "refused rather than put to a person"

    @quinns.update!(sole_contact: nil)
    arguments = { "to" => [ "quinn@example.com" ], "subject" => "Hi", "body" => "Hello." }
    assert_equal "waiting", receive(@bo, "send_email", arguments, call_id: "bo-wait")[:status]
    @quinns.update!(sole_contact: @ada)
    @bo.conversation.invocations.find_by!(call_id: "bo-wait").approve!(by: @owner)
    outcome = run_call(@bo, "send_email", arguments, call_id: "bo-wait")
    assert outcome[:isError], outcome.to_json
    assert_match "Go through Ada", outcome[:result][:error]
    assert_empty ActionMailer::Base.deliveries
  end

  test "the named agent's mail and texts go" do
    forms = stub_voipms
    with_setting(:app, :approve_everything, true) do
      outcome = run_call(@ada, "send_email", { "to" => [ "quinn@example.com" ], "subject" => "Invoice", "body" => "Attached." }, call_id: "ada-1")
      assert_not outcome[:isError], outcome.to_json
      outcome = run_call(@ada, "send_text", { "to" => "4165550111", "body" => "Sent you the invoice." }, call_id: "ada-2")
      assert_not outcome[:isError], outcome.to_json
    end
    assert_equal [ "quinn@example.com" ], ActionMailer::Base.deliveries.sole.to
    assert_equal "4165550111", forms.sole["dst"]
  end

  test "another agent's text to the member's number is refused; to anyone else it goes" do
    forms = stub_voipms
    with_setting(:app, :approve_everything, true) do
      outcome = run_call(@bo, "send_text", { "to" => "4165550111", "body" => "Your parcel is here." }, call_id: "bo-text")
      assert outcome[:isError], outcome.to_json
      assert_match "Go through Ada", outcome[:result][:error]
      assert_not run_call(@bo, "send_text", { "to" => "4165550199", "body" => "Your parcel is here." }, call_id: "bo-other")[:isError]
    end
    assert_equal [ "4165550199" ], forms.map { it["dst"] }
  end

  test "another agent's iMessage to the member's own chat is refused, before anyone is asked" do
    install_bluebubbles_settings
    @bo.update!(tool_names: @bo.tool_names | %w[ imessage_send ])
    outcome = receive(@bo, "imessage_send", { "chat" => "iMessage;-;+14165550111", "bubbles" => [ "Your parcel is here." ] }, call_id: "bo-imessage")
    assert outcome[:isError], outcome.to_json
    assert_match "Go through Ada", outcome[:result][:error]
  ensure
    remove_bluebubbles_settings
  end

  test "another agent's mail through a Gmail connector to the member is refused" do
    x = Rails.application.config.x
    connectors, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
    gmail = @harbour.mcp_servers.create!(user: @owner, name: "gmail", **McpServer.gallery_attributes("gmail"), tools: [], refreshed_at: Time.current,
      oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 1.hour.from_now.to_i })
    make_core(@bo, gmail)
    mail = { "to" => [ "quinn@example.com" ], "subject" => "Invoice", "body" => "Attached." }
    with_setting(:app, :approve_everything, true) do
      outcome = receive(@bo, "mcp__gmail__send_message", mail, call_id: "bo-gmail")
      assert outcome[:isError], outcome.to_json
      assert_match "Go through Ada", outcome[:result][:error]
    end
  ensure
    Rails.application.config.x.connectors = connectors
  end

  test "a card from another agent is not mailed to the member; the named agent's is, and everyone else still hears" do
    card = ->(agent, call_id) do
      agent.conversation.invocations.create!(task_id: "7", call_id: call_id, tool_name: "ask_person",
        arguments: { "question" => "Which day?" }, digest: call_id, state: "awaiting_person", expires_at: 1.hour.from_now)
    end
    perform_enqueued_jobs { card.(@bo, "bo-card") }
    assert_equal [ [ "olive@example.com" ] ], ActionMailer::Base.deliveries.map(&:to)

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs { card.(@ada, "ada-card") }
    assert_equal [ [ "olive@example.com" ], [ "quinn@example.com" ] ], ActionMailer::Base.deliveries.map(&:to).sort
  end

  test "an agent in another workspace is not bound by it" do
    elsewhere = @owner.personal_workspace.agents.sole
    create_conversation(elsewhere, durable_id: "own-1")
    with_setting(:app, :approve_everything, true) do
      outcome = run_call(elsewhere, "send_email", { "to" => [ "quinn@example.com" ], "subject" => "Hi", "body" => "Hello." }, call_id: "own-1")
      assert_not outcome[:isError], outcome.to_json
    end
    assert_equal [ "quinn@example.com" ], ActionMailer::Base.deliveries.sole.to
  end

  test "the sole contact is one of the workspace's own agents, and goes when it is deleted" do
    other = @owner.personal_workspace.agents.sole
    assert_not @quinns.update(sole_contact: other)
    assert_includes @quinns.errors[:sole_contact], "must be one of Harbour's agents"

    @ada.destroy!
    assert_nil @quinns.reload.sole_contact
  end

  private
    def receive(agent, tool, arguments, call_id:)
      payload = invocation_payload(agent.conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(agent.conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    # An outside call runs from a job once claimed; the replay then reads its result.
    def run_call(agent, tool, arguments, call_id:)
      receive(agent, tool, arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive(agent, tool, arguments, call_id: call_id)
    end
end
