require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# Mail to an agent at its workspace's own domain reaches it (#229), whichever
# catch-all box it came through. An address names one agent: its name is
# unique across the install, and its domain must be its own workspace's or
# the install's, so another workspace's domain reaches nothing of it.
class WorkspaceMailDomainMailboxTest < ActionMailbox::TestCase
  include AgentTestHelper
  include EmailTestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    alice = create_user(name: "Alice")
    @field = Workspace.make(name: "Field", owner: alice)
    @field.create_mail_domain!(domain: "field.example.net", smtp_host: "mail.field.example.net", vault_entry: "Field mail")
    @scout = alice.start_agent("Scout", workspace: @field)
    @own = alice.agents.find_by!(workspace: alice.personal_workspace)
    Agent.where(id: @own.id).update_all(email_name: "pip")
    @other = Workspace.make(name: "Other", owner: create_user(name: "Bob"))
    @other.create_mail_domain!(domain: "other.example.org", smtp_host: "mail.other.example.org", vault_entry: "Other mail")
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "c-thread" }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-thread/submissions\z}).to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "mail to its agent at its workspace's domain reaches it; the install's domain still does" do
    receive_inbound_email_from_mail(from: "sam@example.com", to: "scout@field.example.net", subject: "Site", body: "Survey done.", message_id: "w1@example.com")
    assert_equal [ "email:#{@scout.id}:w1@example.com" ], requests

    receive_inbound_email_from_mail(from: "sam@example.com", to: "scout@agents.example", subject: "Site", body: "Again.", message_id: "w2@example.com")
    assert_includes requests, "email:#{@scout.id}:w2@example.com"
  end

  test "another workspace's domain, or a workspace's domain for an agent of another, reaches nothing" do
    receive_inbound_email_from_mail(from: "sam@example.com", to: "scout@other.example.org", subject: "x", body: "x", message_id: "x1@example.com")
    receive_inbound_email_from_mail(from: "sam@example.com", to: "pip@field.example.net", subject: "x", body: "x", message_id: "x2@example.com")
    receive_inbound_email_from_mail(from: "sam@example.com", to: "scout@elsewhere.example", subject: "x", body: "x", message_id: "x3@example.com")

    assert_empty requests
  end

  test "an agent of a workspace without its own domain is reached at the install's, as before" do
    receive_inbound_email_from_mail(from: "sam@example.com", to: "pip@agents.example", subject: "Hi", body: "Hi.", message_id: "p1@example.com")
    assert_equal [ "email:#{@own.id}:p1@example.com" ], requests
  end

  test "its own address, at its domain, is not news to it" do
    receive_inbound_email_from_mail(from: "scout@field.example.net", to: "scout@field.example.net", subject: "x", body: "x", message_id: "s1@example.com")
    assert_empty requests
  end

  private
    def requests = @submissions.map { it["requestId"] }
end
