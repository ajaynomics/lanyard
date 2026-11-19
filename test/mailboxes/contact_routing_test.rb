require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/voipms_test_helper"

# A workspace's contact routing: mail or a text from a routed contact to any
# of its agents reaches the agent that answers them, alone, saying it was
# routed there. Another workspace's agents are not routed.
class ContactRoutingTest < ActionMailbox::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include VoipmsTestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    install_voipms_settings
    @owner = create_user(name: "Olive")
    @harbour = Workspace.create!(name: "Harbour").tap { it.memberships.create!(user: @owner, role: "owner") }
    @ada = @owner.start_agent("Ada", workspace: @harbour, email_name: "ada")
    @bo = @owner.start_agent("Bo", workspace: @harbour, email_name: "bo")
    @bo.update!(phone_number: "4165550123")
    @cy = @owner.personal_workspace.agents.sole
    [ @ada, @bo, @cy ].each { create_conversation(it, durable_id: "c-#{it.id}") }
    @harbour.contact_routes.create!(contact: "Client@Example.net", agent: @ada)
    @harbour.contact_routes.create!(contact: "(905) 555-0188", agent: @ada)

    @received = Hash.new { |hash, key| hash[key] = [] }
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-(\d+)/submissions\z}).to_return { |request|
      @received[request.uri.path[%r{c-(\d+)}, 1].to_i] << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_voipms_settings
    remove_email_settings
    remove_sidecar_settings
  end

  test "a routed contact's mail to another agent reaches the routed agent alone, saying so" do
    receive_inbound_email_from_mail(from: "Client <client@example.net>", to: "bo@agents.example", subject: "Invoice",
      body: "Where is it?", message_id: "m1@example.net")

    assert_empty @received[@bo.id], "Bo, to whom it was sent, is not woken"
    content = @received[@ada.id].sole["content"]
    assert_match "Sent to bo@agents.example, the address of Bo; routed here by the workspace's contact routing.", content
    assert_match "send_email to client@example.net", content
    assert_match "Where is it?", content
  end

  test "sent to several of the workspace's agents, it reaches the routed one once" do
    receive_inbound_email_from_mail(from: "client@example.net", to: "bo@agents.example", cc: "ada@agents.example",
      subject: "Invoice", body: "Where is it?", message_id: "m2@example.net")

    assert_empty @received[@bo.id]
    assert_equal 1, @received[@ada.id].size
  end

  test "a routed number's text reaches the routed agent" do
    receive_inbound_email_from_mail(from: "9055550188 <sms@voip.ms>", to: "bo@agents.example",
      subject: "Message received from number 9055550188 to number 4165550123 [#a1b2c3]", body: "Running late.", message_id: "t1@voip.ms")

    assert_empty @received[@bo.id]
    content = @received[@ada.id].sole["content"]
    assert_match(/\A\[Text from 9055550188\./, content)
    assert_match "routed here by the workspace's contact routing", content
  end

  test "anyone else's mail reaches the agent it was sent to" do
    receive_inbound_email_from_mail(from: "someone@example.org", to: "bo@agents.example", subject: "Hi", body: "Hello", message_id: "m3@example.org")

    assert_empty @received[@ada.id]
    assert_no_match "contact routing", @received[@bo.id].sole["content"]
  end

  test "another workspace's agent is not routed" do
    receive_inbound_email_from_mail(from: "client@example.net", to: "#{@cy.email_name}@agents.example", subject: "Hi", body: "Hello", message_id: "m4@example.net")

    assert_empty @received[@ada.id]
    assert_equal 1, @received[@cy.id].size
  end

  test "a contact is routed once in a workspace, to one of its own agents" do
    assert_not @harbour.contact_routes.new(contact: "client@EXAMPLE.net", agent: @bo).valid?
    route = @harbour.contact_routes.new(contact: "lee@example.net", agent: @cy)
    assert_not route.valid?
    assert_includes route.errors[:agent], "must be one of Harbour's agents"
    assert_not @harbour.contact_routes.new(contact: "not a contact", agent: @bo).valid?
    assert_equal "4165550199", @harbour.contact_routes.create!(contact: "+1 416 555 0199", agent: @bo).contact
  end
end
