require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GmailInboxFetchJobTest < ActiveJob::TestCase
  include AgentTestHelper

  MAILBOX = "owner@example.com"
  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
  TOKEN_URL = "https://oauth2.googleapis.com/token"
  CONNECTOR = "https://gmailmcp.googleapis.com/mcp/v1"
  READ_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"

  setup do
    install_sidecar_settings
    @owner = create_user(name: "Mailbox owner", email: MAILBOX)
    @agent = @owner.agents.sole
    @conversation = create_conversation(@agent)
    @connector = create_connector
    @submissions = []
    @fail_next = nil
    stub_request(:post, "#{SIDECAR}/v1/conversations/#{@conversation.durable_id}/submissions").to_return do |request|
      envelope = JSON.parse(request.body)
      if @fail_next == envelope["requestId"]
        @fail_next = nil
        { status: 503, body: { error: "unavailable" }.to_json }
      else
        @submissions << envelope
        { status: 202, body: { id: @submissions.size, status: "queued" }.to_json }
      end
    end
    stub_request(:get, "#{SIDECAR}/v1/conversations/#{@conversation.durable_id}/entries").to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown { remove_sidecar_settings }

  test "nothing is queued or polled without an enabled inbox and an agent" do
    without_gmail_requests { EmailFetchJob.perform_now }
    inbox = create_inbox(enabled: false)
    assert_no_enqueued_jobs(only: GmailInboxFetchJob) { EmailFetchJob.perform_now }
    without_gmail_requests { GmailInboxFetchJob.perform_now(inbox) }
  end

  test "the minute queues the inbox and its first read saves the profile cursor without backfilling" do
    inbox = create_inbox
    profile(history: "80000000000000000001")
    assert_enqueued_with(job: GmailInboxFetchJob, args: [ inbox ], queue: "mail") { EmailFetchJob.perform_now }
    poll(inbox)
    assert_equal "80000000000000000001", inbox.reload.history_id
    assert_empty @submissions
    assert_not_requested :get, %r{#{Regexp.escape(GMAIL)}/(?:history|messages)}
  end

  test "history pages deliver untrusted mail to the selected thread even when contact routing says otherwise" do
    inbox = create_inbox(history_id: "101")
    @agent.create_mail_account!(address: "outbound@example.com", smtp_host: "smtp.example.com", vault_entry: "Outgoing mail")
    other = @agent.workspace.agents.create!(user: @owner, name: "Other agent", instructions: "Help.", model: Agent.models.first)
    @agent.workspace.contact_routes.create!(contact: "sender@example.net", agent: other)
    profile
    history("101", ids: %w[ g1 g1 ], cursor: "109", next_page: "more")
    history("101", ids: %w[ g1 g2 ], cursor: "110", page: "more")
    one = stub_message("g1", rfc_id: "one@example.net")
    stub_message("g2", rfc_id: "two@example.net")
    poll(inbox)

    assert_equal "110", inbox.reload.history_id
    assert_equal %w[ one two ].map { "email:#{@agent.id}:#{it}@example.net" }, @submissions.pluck("requestId")
    assert_match "Untrusted: written by someone else", @submissions.first.fetch("content")
    assert_not_includes @submissions.first.fetch("content"), "Bcc:", "the Gmail mailbox is not the agent's SMTP address"
    assert_nil other.conversation.reload.durable_id
    assert_requested one, times: 1
  end

  test "a message Gmail labels sent is not copied even when it has another From address" do
    inbox = create_inbox(history_id: "101")
    profile
    history("101", ids: [ "sent" ], cursor: "110")
    stub_message("sent", rfc_id: "sent@example.net", labels: %w[ INBOX SENT ])

    poll(inbox)

    assert_equal "110", inbox.reload.history_id
    assert_empty @submissions
    assert_empty inbox.receipts
  end

  test "a message from the watched mailbox is not copied even without a sent label" do
    mailbox = "desk@example.net"
    inbox = create_inbox(mailbox: mailbox, history_id: "101")
    profile(email: mailbox)
    history("101", ids: [ "own" ], cursor: "110")
    stub_message("own", rfc_id: "own@example.net", from: "Desk <DESK@Example.NET>")

    poll(inbox)

    assert_equal "110", inbox.reload.history_id
    assert_empty @submissions
    assert_empty inbox.receipts
  end

  test "a real reply is copied from the same Gmail thread after a sent item is skipped" do
    inbox = create_inbox(history_id: "101")
    profile
    history("101", ids: [ "sent" ], cursor: "109", next_page: "more")
    history("101", ids: [ "reply" ], cursor: "110", page: "more")
    stub_message("sent", rfc_id: "sent@example.net", labels: %w[ INBOX SENT ], thread_id: "thread-1")
    stub_message("reply", rfc_id: "reply@example.net", thread_id: "thread-1", replying_to: "sent@example.net")

    poll(inbox)

    assert_equal "110", inbox.reload.history_id
    assert_equal [ "email:#{@agent.id}:reply@example.net" ], @submissions.pluck("requestId")
    assert_equal [ "reply" ], inbox.receipts.pluck(:gmail_message_id)
  end

  test "retry after a failed delivery resumes the same history and neither loses nor repeats delivered mail" do
    inbox = create_inbox(history_id: "101")
    profile
    history("101", ids: %w[ g1 g2 ], cursor: "110")
    first = stub_message("g1", rfc_id: nil)
    second = stub_message("g2", rfc_id: "second@example.net")
    @fail_next = "email:#{@agent.id}:second@example.net"
    poll(inbox)
    assert_equal "101", inbox.reload.history_id
    assert_equal 1, @submissions.size

    poll(@agent.reload.gmail_inbox)
    assert_equal "110", inbox.reload.history_id
    assert_equal 2, @submissions.size
    assert_requested first, times: 1
    assert_requested second, times: 2
  end

  test "a restart after accepting mail but before its Gmail receipt uses the existing request id" do
    inbox = create_inbox(history_id: "101")
    profile
    history("101", ids: %w[ same another ], cursor: "110")
    stub_message("same", rfc_id: "existing@example.net")
    stub_message("another", rfc_id: "existing@example.net")
    @conversation.receive("Previously delivered", from: "sender@example.net", via: "Email", request_id: "email:#{@agent.id}:existing@example.net")

    poll(inbox)
    assert_equal 1, @submissions.size
    assert_equal "110", inbox.reload.history_id
  end

  # A crash after the thread took the mail but before its receipt was saved:
  # the retry must find the same message, not make a second one. Mail without
  # a Message-ID leans on the id made from its mailbox and Gmail id alone.
  test "a retry after a crash between delivery and receipt leaves exactly one copy" do
    inbox = create_inbox(history_id: "101")
    profile
    history("101", ids: %w[ bare named ], cursor: "110")
    stub_message("bare", rfc_id: nil)
    stub_message("named", rfc_id: "named@example.net")
    poll(inbox)
    assert_equal 2, @submissions.size
    # What the crash leaves: the mail delivered, its receipt and the cursor not saved.
    inbox.receipts.delete_all
    inbox.update!(history_id: "101")

    poll(@agent.reload.gmail_inbox)
    assert_equal "110", inbox.reload.history_id
    assert_equal 2, @conversation.submissions.count, "one message each, the crashed one not made twice"
    assert_equal 2, @submissions.pluck("requestId").uniq.size
    assert_equal 2, @submissions.size, "nothing sent to the agent twice"
    assert_equal %w[ bare named ], inbox.receipts.order(:id).pluck(:gmail_message_id)
  end

  test "expired history starts at the profile without exposing the error body" do
    inbox = create_inbox(history_id: "101")
    profile(history: "119")
    history("101", status: 404, error: "private message subject")
    output = StringIO.new
    original, Rails.logger = Rails.logger, ActiveSupport::Logger.new(output)
    poll(inbox)
    assert_equal "119", inbox.reload.history_id
    assert_match(/history expired/i, output.string)
    assert_not_includes output.string, "private message subject"
    assert_empty @submissions
    assert_not_requested :get, %r{#{Regexp.escape(GMAIL)}/messages}
  ensure
    Rails.logger = original if original
  end

  test "a different sign-in pauses the chosen mailbox and no Gmail request runs while paused" do
    mailbox = "desk@example.net"
    inbox = create_inbox(mailbox: mailbox, history_id: "101")
    original = profile(email: mailbox)
    history("101", cursor: "110")
    poll(inbox)
    assert inbox.reload.enabled?
    assert_equal "110", inbox.history_id

    @connector.update!(oauth_tokens: { "access_token" => "new-token" })
    changed = profile(email: "other@example.com", token: "new-token")
    poll(inbox)
    assert_not inbox.reload.enabled?
    assert_equal "The connector is signed in to a different Gmail account. Sign in to the chosen mailbox, then turn copying back on.", inbox.paused_reason
    assert_equal [ mailbox, "110" ], inbox.values_at(:mailbox, :history_id)

    @connector.update!(oauth_tokens: { "access_token" => "old-token" })
    assert_no_enqueued_jobs(only: GmailInboxFetchJob) { EmailFetchJob.perform_now }
    poll(inbox)
    assert_requested original, times: 1
    assert_requested changed, times: 1
    assert_requested :get, %r{#{Regexp.escape(GMAIL)}/history}, times: 1
    assert_not_requested :get, %r{#{Regexp.escape(GMAIL)}/messages}
    assert_empty @submissions
  end

  test "transferring ownership switches off immediately even if the old owner later gets ownership back" do
    other = create_user(name: "New owner", email: "new-owner@example.com")
    workspace = Workspace.make(name: "Team", owner: @owner)
    member = workspace.memberships.create!(user: other, role: "member")
    @agent = workspace.agents.create!(user: @owner, name: "Shared agent", instructions: "Help.", model: Agent.models.first)
    @connector = create_connector
    inbox = create_inbox(history_id: "101")

    member.take_ownership
    assert_not inbox.reload.enabled?
    workspace.memberships.find_by!(user: @owner).take_ownership
    without_gmail_requests { poll(inbox) }
  end

  test "revoked grant is cleared and the poll does not try that grant again" do
    inbox = create_inbox
    refused = profile(status: 401)
    refresh = stub_request(:post, TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    2.times { poll(inbox.reload) }
    assert_not inbox.reload.enabled?
    assert @connector.reload.needs_sign_in?
    assert_nil inbox.history_id
    assert_requested refused, times: 1
    assert_requested refresh, times: 1
  end

  test "a second 401 after refresh stops the inbox and marks the connector as needing sign-in" do
    inbox = create_inbox
    refused = profile(status: 401)
    again = profile(status: 401, token: "new-token")
    refresh = stub_request(:post, TOKEN_URL).to_return(body: { access_token: "new-token", expires_in: 3600 }.to_json)
    2.times { poll(inbox.reload) }
    assert_not inbox.reload.enabled?
    assert @connector.reload.needs_sign_in?
    assert_requested refused, times: 1
    assert_requested again, times: 1
    assert_requested refresh, times: 1
  end

  private
    def create_connector
      @agent.workspace.mcp_servers.create!(name: "gmail", user: @owner, url: CONNECTOR, oauth_scope: READ_SCOPE,
        oauth_tokens: { "access_token" => "old-token", "refresh_token" => "synthetic-renewal" })
    end

    def create_inbox(**attributes)
      @agent.create_gmail_inbox!(**{ mcp_server: @connector, enabled_by: @owner, mailbox: MAILBOX, enabled: true }.merge(attributes))
    end

    def poll(inbox) = GmailInboxFetchJob.perform_now(inbox)

    def without_gmail_requests
      yield
      assert_not_requested :get, %r{#{Regexp.escape(GMAIL)}/}
    end

    def profile(email: MAILBOX, history: "115", token: "old-token", status: 200)
      stub_request(:get, "#{GMAIL}/profile").with(headers: { "Authorization" => "Bearer #{token}" })
        .to_return(status: status, body: { emailAddress: email, historyId: history }.to_json)
    end

    def history(start, ids: [], cursor: nil, next_page: nil, page: nil, status: 200, error: nil)
      query = { startHistoryId: start, historyTypes: "messageAdded", labelId: "INBOX", pageToken: page }.compact
      stub_request(:get, "#{GMAIL}/history").with(query: query).to_return(status: status, body: {
        history: [ { messagesAdded: ids.map { |id| { message: { id: id } } } } ],
        historyId: cursor, nextPageToken: next_page, error: ({ message: error } if error)
      }.compact.to_json)
    end

    def stub_message(id, rfc_id:, from: "Sender <sender@example.net>", labels: [ "INBOX" ], thread_id: nil, replying_to: nil)
      raw = [ "From: #{from}", "To: #{MAILBOX}", "Date: Fri, 20 Nov 2026 12:00:00 +0000",
        ("Message-ID: <#{rfc_id}>" if rfc_id), ("In-Reply-To: <#{replying_to}>" if replying_to),
        "Subject: Updates", "", "The updated plans." ].compact.join("\r\n")
      stub_request(:get, "#{GMAIL}/messages/#{id}").with(query: { format: "raw" })
        .to_return(body: { raw: Base64.urlsafe_encode64(raw, padding: false), labelIds: labels, threadId: thread_id }.compact.to_json)
    end
end
