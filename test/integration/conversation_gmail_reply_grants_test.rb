require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class ConversationGmailReplyGrantsTest < ActionDispatch::IntegrationTest
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
    @connector = @conversation.workspace.mcp_servers.create!(name: "gmail", user: @owner, conversation: @conversation,
      **McpServer.gallery_attributes("gmail"), loaded: true, asks_every_write: true,
      refreshed_at: Time.current, oauth_tokens: tokens("initial"))
    @sent = []
    stub_request(:post, "#{GMAIL}/messages/send").to_return do |request|
      payload = JSON.parse(request.body)
      @sent << [ request.headers["Authorization"], payload["threadId"], Mail.new(Base64.urlsafe_decode64(payload.fetch("raw"))) ]
      json({ id: "m2", threadId: "t1" })
    end
  end

  teardown { remove_sidecar_settings }

  test "a conversation grant waives the send card and records the reply on the conversation" do
    add_grant
    lookup = thread_with
    call = invoke(REPLY)

    assert_predicate call, :succeeded?, call.attributes.slice("state", "error").inspect
    assert_nil call.approval
    assert_equal ADDRESS, call.gmail_reply_grant_address
    authorization, thread, mail = @sent.sole
    assert_equal "Bearer initial-access", authorization
    assert_equal "t1", thread
    assert_equal [ ADDRESS ], mail.destinations
    assert_equal "first@example.net", mail.in_reply_to
    assert_equal "Friday works.", mail.text_part.decoded.strip
    assert_requested lookup, times: 1

    @conversation.messages.create!(entry_id: 1, entry_key: "reply-trace", role: "assistant", content: "",
      tool_calls: [ { "id" => call.call_id, "name" => SEND, "arguments" => call.arguments } ])
    get conversation_path(@conversation)
    assert_response :success
    assert_select ".tool-call [role=note]", "Used Gmail reply grant for #{ADDRESS}."
  end

  test "replacing the current Google sign-in during the metadata check still requires approval" do
    # Start at the existing persisted-grant seam to test the worker independently of setup UI.
    @connector.gmail_reply_grants.new(agent: @conversation.agent, address: ADDRESS).save!(validate: false)
    lookup = thread_with do
      connector = @connector.reload
      McpServer::Authorization.new(connector).save_tokens(tokens("replacement"))
    end

    assert_card invoke(REPLY)
    assert_requested lookup, times: 1
    assert_equal "replacement-access", @connector.reload.oauth_tokens["access_token"]
    assert_empty @connector.gmail_reply_grants
  end

  test "new mail and extra To, Cc and Bcc recipients ask without looking up the thread" do
    add_grant
    lookup = thread_with
    [
      REPLY.except("thread_id"),
      REPLY.merge("to" => [ "#{ADDRESS}, lee@example.net" ]),
      REPLY.merge("cc" => [ "lee@example.net" ]),
      REPLY.merge("bcc" => [ "lee@example.net" ]),
      REPLY.merge("to" => [], "bcc" => [ ADDRESS ]),
      REPLY.merge("to" => [ "Pat <#{ADDRESS}" ])
    ].each_with_index { |arguments, index| assert_card invoke(arguments, call_id: "miss-#{index}") }
    assert_not_requested lookup
  end

  test "the same mailbox in Cc and Bcc is one physical recipient when not hidden only in Bcc" do
    add_grant
    thread_with
    call = invoke(REPLY.merge("to" => [], "cc" => [ "Pat <PAT@example.net>" ], "bcc" => [ ADDRESS ]))
    assert_predicate call, :succeeded?, call.error
    assert_equal [ ADDRESS ], @sent.sole.last.destinations.map(&:downcase).uniq
    assert_equal [ "PAT@example.net" ], @sent.sole.last.cc
    assert_equal [ ADDRESS ], @sent.sole.last.bcc
  end

  test "wrong, ambiguous, malformed, and changed-subject threads still ask" do
    add_grant
    good = default_headers
    cases = [
      { thread_id: "different" },
      { headers: good.merge("From" => "lee@example.net") },
      { headers: good.except("Message-ID") },
      { headers: good.merge("Message-ID" => "not-a-message-id") },
      { headers: good.merge("message-ID" => "<second@example.net>") },
      { headers: good.merge("References" => "not-a-message-id") },
      { headers: good.merge("From" => "Pat <#{ADDRESS}") },
      { headers: good.merge("From" => "lee@example.net\r\nX-Fake: #{ADDRESS}") }
    ]
    cases.each_with_index do |options, index|
      thread_with(**options)
      assert_card invoke(REPLY, call_id: "thread-#{index}")
    end
    thread_with
    assert_card invoke(REPLY.merge("subject" => "Different topic"), call_id: "subject")
  end

  test "the grant cannot follow the original agent to another conversation or a new agent in its place" do
    add_grant
    original = @conversation.agent
    replacement = agent_with_no_conversation
    @conversation.update!(agent: replacement)
    other = original.conversations.create!(request_id: "other-thread", durable_id: "13")
    scoped_tool = @connector.tool_classes.find { it.tool_name == SEND }
    assert_nil GmailReplyGrant.for_call(scoped_tool, other, REPLY)
    workspace_gmail = @conversation.workspace.mcp_servers.create!(name: "gmail", user: @owner,
      **McpServer.gallery_attributes("gmail"), refreshed_at: Time.current, oauth_tokens: tokens("workspace"))
    make_core(original, workspace_gmail)
    lookup = thread_with

    assert_card invoke(REPLY, conversation: other)
    assert_card invoke(REPLY, conversation: @conversation)
    assert_not_requested lookup
  end

  test "changing the fixed agent while Gmail checks the thread returns to the card" do
    add_grant
    replacement = agent_with_no_conversation
    lookup = thread_with { @conversation.update!(agent: replacement) }

    assert_card invoke(REPLY)
    assert_requested lookup, times: 1
  end

  test "moving to another workspace does not carry the previous owner's grant" do
    add_grant
    destination = Workspace.make(name: "Other workspace", owner: create_user(name: "Lee"))
    destination.memberships.create!(user: @owner, role: :member)
    lookup = thread_with

    assert @conversation.agent.move_to(destination, by: @owner)
    assert_equal destination, @connector.reload.workspace
    assert_card invoke(REPLY, conversation: @conversation.reload)
    assert_not_requested lookup
    assert_empty @connector.gmail_reply_grants
  end

  test "removing the connector clears its grant and a replacement cannot use it" do
    add_grant
    grant = @connector.gmail_reply_grants.sole
    call = invoke(REPLY, run: false)
    assert_predicate call, :checking_gmail_reply?

    delete connector_path(@connector)
    assert_redirected_to conversation_connectors_path(@conversation)
    assert_not @conversation.mcp_servers.exists?(@connector.id)
    assert_not @connector.gmail_reply_grants.exists?(grant.id)
    @conversation.workspace.mcp_servers.create!(name: @connector.name, user: @owner, conversation: @conversation,
      **McpServer.gallery_attributes("gmail"), loaded: true, refreshed_at: Time.current, oauth_tokens: tokens("initial"))

    lookup = thread_with
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_card call.reload
    assert_card invoke(REPLY, call_id: "replacement")
    assert_not_requested lookup
  end

  test "transferring workspace ownership clears scoped grants but keeps workspace-wide grants" do
    workspace = Workspace.make(name: "Front desk", owner: @owner)
    successor = create_user(name: "Lee")
    membership = workspace.memberships.create!(user: successor, role: :member)
    assert @conversation.agent.move_to(workspace, by: @owner)
    @conversation.reload
    @connector.reload
    add_grant
    old_grant = @connector.gmail_reply_grants.sole
    workspace_connector = workspace.mcp_servers.create!(name: "office_mail", user: @owner,
      **McpServer.gallery_attributes("gmail"), refreshed_at: Time.current, oauth_tokens: tokens("workspace"))
    workspace_grant = workspace_connector.gmail_reply_grants.create!(agent: @conversation.agent, address: ADDRESS)
    call = invoke(REPLY, run: false)
    assert_predicate call, :checking_gmail_reply?

    post workspace_membership_ownership_path(workspace, membership)
    assert_redirected_to workspace_path(workspace)
    assert_equal successor, workspace.reload.owner
    assert_equal @owner, @connector.reload.user, "Transferring the workspace doesn't change who added the connector"
    post connector_gmail_reply_grants_path(@connector), params: { gmail_reply_grant: { address: ADDRESS } }
    assert_response :not_found

    lookup = thread_with
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_card call.reload
    assert_not_requested lookup
    assert_not @connector.gmail_reply_grants.exists?(old_grant.id)
    assert_equal workspace_grant, workspace_connector.gmail_reply_grants.sole

    sign_in_via_ajent(subject: successor.oidc_sub, email: successor.email, name: successor.name)
    post connector_gmail_reply_grants_path(@connector), params: { gmail_reply_grant: { address: ADDRESS } }
    assert_redirected_to conversation_connectors_path(@conversation)
    grant = @connector.gmail_reply_grants.sole
    assert_not_equal old_grant.id, grant.id
    assert_equal [ @conversation.agent, ADDRESS ], [ grant.agent, grant.address ]

    make_core(@conversation.agent, workspace_connector)
    workspace_lookup = thread_with(identity: "workspace")
    workspace_call = invoke(REPLY.merge("account" => workspace_connector.name), call_id: "workspace-reply")
    assert_predicate workspace_call, :succeeded?, workspace_call.error
    assert_nil workspace_call.approval
    assert_equal ADDRESS, workspace_call.gmail_reply_grant_address
    assert_equal "Bearer workspace-access", @sent.sole.first
    assert_requested workspace_lookup, times: 1
  end

  test "revoking through the owner route before the worker runs leaves an ordinary card" do
    add_grant
    lookup = thread_with
    call = invoke(REPLY, run: false)
    assert_predicate call, :checking_gmail_reply?

    delete connector_gmail_reply_grant_path(@connector, @connector.gmail_reply_grants.sole)
    assert_redirected_to conversation_connectors_path(@conversation)
    perform_enqueued_jobs(only: InvocationCallJob)

    assert_card call.reload
    assert_not_requested lookup
  end

  test "revoking while the attachment is read prevents dispatch and the grant audit" do
    add_grant
    grant = @connector.gmail_reply_grants.sole
    lookup = thread_with
    path = "/note.txt"
    post "/agent/uploads", headers: rails_bearer, as: :json, params: {
      actorId: @owner.id.to_s, workspaceId: @conversation.agent_id.to_s, conversationId: @conversation.durable_id,
      taskId: 7, callId: "send", tool: SEND, path: path, bytes: Base64.strict_encode64("A note.")
    }
    assert_response :success
    upload = @conversation.uploads.sole
    call = invoke(REPLY.merge("attachments" => [ path ]), run: false)
    assert_predicate call, :checking_gmail_reply?

    revoke = ->(event) { grant.destroy! if event.payload[:key] == upload.file.key }
    ActiveSupport::Notifications.subscribed(revoke, "service_download.active_storage") do
      perform_enqueued_jobs(only: InvocationCallJob)
    end
    assert_predicate grant, :destroyed?
    assert_requested lookup, times: 1
    assert_card call.reload
  end

  test "a contact restriction added during the check cannot be skipped by a display name" do
    add_grant
    recipient = create_user(name: "Pat", email: ADDRESS)
    other = @owner.start_agent("Contact desk")
    lookup = thread_with do
      @conversation.workspace.memberships.create!(user: recipient, role: :member, sole_contact: other)
    end

    assert_card invoke(REPLY.merge("to" => [ "Pat <#{ADDRESS}>" ]))
    assert_requested lookup, times: 1
  end

  test "the outside sign-in lifecycle replaces the mailbox and revokes its old grant" do
    add_grant
    with_setting(:app, :url, "http://localhost") do
      @connector.reload.update!(enabled: false, oauth_client: { "client_id" => "test-client", "client_secret" => "fixture-value" })
      address = "replacement@example.net"
      token = GoogleAccountStart.issue!(@connector, by: @owner, issued_email: @owner.email, expected_email: address)
      browser = "b" * 43
      url = GoogleAccountStart.start(token, browser: browser)
      state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
      attempt = GoogleAccountStart.claim_callback(state, browser: browser)
      assert attempt.matches?(address)
      assert attempt.save_grant(tokens("replacement"))
    end
    assert_empty @connector.reload.gmail_reply_grants
    @connector.update!(enabled: true)
    lookup = thread_with(identity: "replacement")

    call = invoke(REPLY)
    assert_card call
    assert_not_requested lookup
    call.approve!(by: @owner)
    assert_predicate invoke(REPLY), :succeeded?
    assert_equal "Bearer replacement-access", @sent.sole.first
    assert_requested lookup, times: 1
    assert_nil call.reload.gmail_reply_grant_address
  end

  test "routine refresh uses the same sign-in and keeps the grant" do
    add_grant
    @connector.reload.update!(oauth_tokens: tokens("initial").merge("expires_at" => 1.minute.ago.to_i))
    refresh = stub_request(:post, DurableAssistants::Google::TOKEN_URL).with(body: hash_including("refresh_token" => "initial-refresh"))
      .to_return(json({ access_token: "renewed-access", expires_in: 3600 }))
    lookup = thread_with(identity: "renewed")
    call = invoke(REPLY)

    assert_predicate call, :succeeded?, call.error
    assert_equal ADDRESS, @connector.gmail_reply_grants.sole.address
    assert_equal ADDRESS, call.gmail_reply_grant_address
    assert_equal "Bearer renewed-access", @sent.sole.first
    assert_requested refresh, times: 1
    assert_requested lookup, times: 1
  end

  private
    def add_grant
      sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
      post connector_gmail_reply_grants_path(@connector), params: { gmail_reply_grant: { address: ADDRESS } }
      assert_redirected_to conversation_connectors_path(@conversation)
      assert_equal ADDRESS, @connector.gmail_reply_grants.sole.address
    end

    def agent_with_no_conversation
      @owner.start_agent("Another desk").tap { it.conversation.destroy! }
    end

    def tokens(identity)
      { "access_token" => "#{identity}-access", "refresh_token" => "#{identity}-refresh", "signed_in_at" => Time.current.to_i, "expires_at" => 1.hour.from_now.to_i }
    end

    def json(value) = { status: 200, headers: { "Content-Type" => "application/json" }, body: value.to_json }

    def default_headers = { "Subject" => "Booking", "Message-ID" => "<first@example.net>", "From" => ADDRESS }

    def thread_with(thread_id: "t1", headers: default_headers, identity: "initial")
      thread = { id: thread_id, messages: [ { id: "m1", threadId: "t1", payload: { headers: headers.map { |name, value| { name: name, value: value } } } } ] }
      stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including("format" => "metadata"), headers: { "Authorization" => "Bearer #{identity}-access" }).to_return do
        yield if block_given?
        json(thread)
      end
    end

    def invoke(arguments, conversation: @conversation, call_id: "send", run: true)
      post "/agent/invocations", params: invocation_payload(conversation, tool: SEND, arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      assert_response :success
      perform_enqueued_jobs(only: InvocationCallJob) if run
      conversation.invocations.find_by!(call_id: call_id)
    end

    def assert_card(call)
      assert_predicate call, :awaiting_person?, call.attributes.slice("state", "error").inspect
      assert_empty call.always_choices
      assert_nil call.gmail_reply_grant_address
      assert_nil call.dispatch
      assert_empty @sent
    end
end
