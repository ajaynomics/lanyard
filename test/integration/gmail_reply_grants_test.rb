require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GmailReplyGrantsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  SEND = "mcp__gmail__send_message".freeze
  ADDRESS = "pat@example.net".freeze
  REPLY = { "to" => [ ADDRESS ], "body" => "Friday works.", "thread_id" => "t1" }.freeze

  setup do
    install_sidecar_settings
    @owner = create_user(email: "operator@example.com")
    @conversation = create_conversation(@owner.agents.sole)
    @connector = gmail("gmail")
    make_core(@conversation.agent, @connector)
    @grant = @connector.gmail_reply_grants.create!(agent: @conversation.agent, address: ADDRESS)
    @sent = []
    stub_request(:post, "#{GMAIL}/messages/send").to_return do |request|
      payload = JSON.parse(request.body)
      @sent << [ payload["threadId"], Mail.new(Base64.urlsafe_decode64(payload.fetch("raw"))) ]
      json({ id: "m2", threadId: "t1" })
    end
  end

  teardown { remove_sidecar_settings }

  test "the reply address is encrypted in the row without changing the mailbox match" do
    @grant.update!(address: "  PAT@example.net  ")
    @grant.reload
    assert @grant.encrypted_attribute?(:address)
    refute_includes @grant.read_attribute_before_type_cast(:address), ADDRESS
    assert_equal ADDRESS, @grant.address
    assert @grant.sole_recipient?(REPLY)
  end

  test "a reply grant written before encryption remains readable without a write on read" do
    GmailReplyGrant.with_connection do |connection|
      connection.execute("UPDATE gmail_reply_grants SET address = #{connection.quote(ADDRESS)} WHERE id = #{@grant.id}")
    end
    @grant.reload
    refute @grant.encrypted_attribute?(:address)
    assert_equal ADDRESS, @grant.address
    assert @grant.sole_recipient?(REPLY)
    assert_equal ADDRESS, @grant.reload.read_attribute_before_type_cast(:address)
  end

  test "the chosen address on an existing thread sends without a card, even with the connector switch on" do
    lookup = thread_with(from: '"Pat, P." <PAT@example.net>')
    call = invoke(REPLY.merge("to" => [ '"Pat, P." <PAT@example.net>' ]))
    assert_grant_used(call)
    assert call.reload.encrypted_attribute?(:gmail_reply_grant_address)
    refute_includes call.read_attribute_before_type_cast(:gmail_reply_grant_address), ADDRESS
    thread, mail = @sent.sole
    assert_equal "t1", thread
    assert_equal [ "PAT@example.net" ], mail.destinations
    assert_equal "first@example.net", mail.in_reply_to
    assert_requested lookup, times: 1
    show_traces(call)
    assert_select ".tool-call [role=note]", "Used Gmail reply grant for #{ADDRESS}."

    Invocation.with_connection do |connection|
      connection.execute("UPDATE invocations SET gmail_reply_grant_address = #{connection.quote(ADDRESS)} WHERE id = #{call.id}")
    end
    get conversation_path(@conversation)
    assert_response :success
    assert_select ".tool-call [role=note]", "Used Gmail reply grant for #{ADDRESS}."
    refute call.reload.encrypted_attribute?(:gmail_reply_grant_address)
    assert_equal ADDRESS, call.read_attribute_before_type_cast(:gmail_reply_grant_address)
  end

  test "a grouped tool checks the selected connector, not the first account" do
    alternate = gmail("another")
    make_core(@conversation.agent, alternate)
    lookup = thread_with(to: ADDRESS)
    assert_grant_used(invoke(REPLY.merge("account" => @connector.name)))
    assert_requested lookup, times: 1
  end

  test "looked-up calls follow the same grant rule" do
    @conversation.agent.core_connectors.delete_all
    thread_with(cc: ADDRESS)
    assert_grant_used(invoke(REPLY))
  end

  test "extra Cc still needs approval" do
    assert_card invoke(REPLY.merge("cc" => [ "lee@example.net" ]))
  end

  test "extra Bcc still needs approval" do
    assert_card invoke(REPLY.merge("bcc" => [ "lee@example.net" ]))
  end

  test "extra To in the same parsed list still needs approval" do
    assert_card invoke(REPLY.merge("to" => [ "#{ADDRESS}, lee@example.net" ]))
  end

  test "a new message still needs approval" do
    assert_card invoke(REPLY.except("thread_id"))
  end

  test "a different subject would start a new thread and still needs approval" do
    thread_with(from: ADDRESS)
    assert_card invoke(REPLY.merge("subject" => "New topic"))
  end

  test "an existing thread without the approved mailbox still needs approval" do
    lookup = thread_with(from: "Lee <lee@example.net>", to: "Pat <someone@example.net>")
    assert_card invoke(REPLY)
    assert_requested lookup, times: 1
  end

  test "a thread without a Message-ID to reply to still needs approval" do
    thread_with(from: ADDRESS, message_id: nil)
    assert_card invoke(REPLY)
  end

  test "a missing thread still needs approval" do
    lookup = stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including("format" => "metadata")).to_return(status: 404)
    assert_card invoke(REPLY)
    assert_requested lookup, times: 1
  end

  test "an unavailable thread still needs approval" do
    lookup = stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including("format" => "metadata")).to_raise(Net::OpenTimeout)
    assert_card invoke(REPLY)
    assert_requested lookup, times: 1
  end

  test "an unparseable recipient still needs approval" do
    assert_card invoke(REPLY.merge("to" => [ "Pat <#{ADDRESS}" ]))
  end

  test "an invalid recipient in addition to the approved one still needs approval" do
    assert_card invoke(REPLY.merge("cc" => [ "not-a-mailbox" ]))
  end

  test "even the approved address needs a card when it is only in Bcc" do
    thread_with(from: ADDRESS)
    assert_card invoke(REPLY.merge("to" => [], "bcc" => [ ADDRESS ]))
  end

  test "suffix, plus-address and quoted-local look-alikes do not use the grant" do
    thread_with(from: ADDRESS)
    [ "pat@example.net.example.com", "pat+desk@example.net", '"pat"@example.net' ].each_with_index do |to, index|
      assert_card invoke(REPLY.merge("to" => [ to ]), call_id: "lookalike-#{index}")
    end
  end

  test "a revoked grant still needs approval, including a send queued before revocation" do
    call = invoke(REPLY, run: false)
    assert_predicate call, :checking_gmail_reply?
    assert_not call.running?, "An old worker must not mistake this for an approved send"
    @grant.destroy!
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_card call.reload
    assert_card invoke(REPLY, call_id: "later")
  end

  test "revoking during the metadata lookup stops the send" do
    thread_with(from: ADDRESS) { @grant.destroy! }
    assert_card invoke(REPLY)
  end

  test "a held reply can still be allowed once" do
    thread_with(from: "Lee <lee@example.net>")
    call = invoke(REPLY)
    assert_card call
    call.approve!(by: @owner)
    assert_predicate invoke(REPLY), :succeeded?
    assert_equal 1, @sent.size
    assert_nil call.reload.gmail_reply_grant_address
  end

  test "a different agent gets a card for the same address and connector" do
    other = create_conversation(@conversation.agent, durable_id: "13")
    make_core(other.agent, @connector)
    assert_card invoke(REPLY, conversation: other)
  end

  test "a different connector gets a card for the same agent and address" do
    alternate = gmail("another")
    make_core(@conversation.agent, alternate)
    assert_card invoke(REPLY.merge("account" => alternate.name))
  end

  test "the grant never allows drafts or other writes" do
    assert_card invoke(REPLY, tool: "mcp__gmail__create_draft", call_id: "draft")
    assert_card invoke({ "draft_id" => "d1" }, tool: "mcp__gmail__send_draft", call_id: "send-draft")
    assert_card invoke({ "draft_id" => "d1" }, tool: "mcp__gmail__delete_draft", call_id: "delete-draft")
  end

  test "a tool switched off for this agent cannot use the grant" do
    @conversation.agent.update!(disabled_tools: [ SEND ])
    call = invoke(REPLY)
    assert_predicate call, :failed?
    assert_empty @sent
  end

  test "the grant cannot override a contact restriction" do
    workspace = Workspace.make(name: "Front desk", owner: @owner)
    pat = create_user(name: "Pat", email: ADDRESS)
    desk = @owner.start_agent("Guest desk", workspace: workspace)
    gatekeeper = @owner.start_agent("Contact desk", workspace: workspace)
    workspace.memberships.create!(user: pat, role: :member, sole_contact: gatekeeper)
    conversation = create_conversation(desk, durable_id: "13")
    connector = gmail("gmail", workspace: workspace)
    make_core(desk, connector)
    connector.gmail_reply_grants.create!(agent: desk, address: ADDRESS)
    lookup = thread_with(from: ADDRESS)
    call = invoke(REPLY, conversation: conversation)
    assert_predicate call, :failed?
    assert_match(/hears only from Contact desk/, call.error)
    assert_card invoke(REPLY.merge("to" => [ "Pat <#{ADDRESS}>" ]), conversation: conversation, call_id: "display-name")
    assert_not_requested lookup
  end

  test "two replies leave individual notes and replaying either call sends nothing again" do
    lookup = thread_with(from: ADDRESS)
    args2 = REPLY.merge("body" => "Thursday is open too.")
    first = invoke(REPLY)
    assert_grant_used(first)
    second = invoke(args2, call_id: "next-reply")
    assert_grant_used(second, sends: 2)
    assert_equal first, invoke(REPLY)
    assert_equal second, invoke(args2, call_id: "next-reply")
    InvocationCallJob.perform_now(second.reload)
    assert_equal 2, @sent.size
    assert_requested lookup, times: 2
    show_traces(first, second)
    assert_select ".tool-call [role=note]", text: "Used Gmail reply grant for #{ADDRESS}.", count: 2
  end

  test "the grant is not part of tool declarations, results or the agent's permissions page" do
    assert_not_includes @conversation.definition.to_json, ADDRESS
    thread_with(from: ADDRESS)
    call = invoke(REPLY)
    assert_grant_used(call)
    assert_not_includes call.result.to_json, ADDRESS
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    [ agent_tools_path(@conversation.agent), agent_permissions_path(@conversation.agent) ].each do |path|
      get path
      assert_response :success
      assert_not_includes response.body, ADDRESS
    end
  end

  private
    def gmail(name, workspace: @owner.personal_workspace)
      workspace.mcp_servers.create!(name: name, user: @owner, **McpServer.gallery_attributes("gmail"), tools: [], refreshed_at: Time.current,
        asks_every_write: true, oauth_tokens: { "access_token" => "sample-token", "expires_at" => 1.hour.from_now.to_i })
    end

    def json(value) = { status: 200, headers: { "Content-Type" => "application/json" }, body: value.to_json }

    def thread_with(message_id: "<first@example.net>", **participants)
      headers = { "Subject" => "Booking", "Message-ID" => message_id, **participants.stringify_keys }.compact
      thread = { id: "t1", messages: [ { id: "m1", threadId: "t1", payload: { headers: headers.map { |name, value| { name: name, value: value } } } } ] }
      stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including("format" => "metadata")).to_return do
        yield if block_given?
        json(thread)
      end
    end

    def show_traces(*calls)
      @conversation.messages.create!(entry_id: 1, entry_key: "reply-trace", role: "assistant", content: "",
        tool_calls: calls.map { { "id" => it.call_id, "name" => SEND, "arguments" => it.arguments } })
      sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
      get conversation_path(@conversation)
      assert_response :success
    end

    def invoke(arguments, tool: SEND, conversation: @conversation, call_id: "send", run: true)
      post "/agent/invocations", params: invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      assert_response :success
      perform_enqueued_jobs(only: InvocationCallJob) if run
      conversation.invocations.find_by!(call_id: call_id)
    end

    def assert_grant_used(call, sends: 1)
      assert_predicate call, :succeeded?, call.attributes.slice("state", "error").inspect
      assert_nil call.approval
      assert_equal ADDRESS, call.gmail_reply_grant_address
      assert_equal sends, @sent.size
    end

    def assert_card(call)
      assert_predicate call, :awaiting_person?, call.attributes.slice("state", "error").inspect
      assert_empty call.always_choices
      assert_nil call.gmail_reply_grant_address
      assert_nil call.dispatch
      assert_empty @sent
    end
end
