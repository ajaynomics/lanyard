require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# #86, mail through a connector: Gmail takes a send_message and never answers.
# The message's Message-ID is chosen and recorded (Dispatch) before Gmail is
# asked, and the connector's own Sent is searched for that Message-ID alone.
# Google is stubbed at HTTP; the ledger and jobs run for real.
class GmailSendUnansweredTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  SEND = "mcp__gmail__send_message".freeze
  MAIL = { "to" => [ "sam@example.net" ], "subject" => "Your booking", "body" => "Two nights from Friday." }.freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    x = Rails.application.config.x
    @connectors, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
    @alice.mcp_servers.create!(name: "gmail", **McpServer.gallery_attributes("gmail"), tools: [], refreshed_at: Time.current,
      oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 1.hour.from_now.to_i })
      .tap { make_core(@agent, it) }
    @taken = []
    stub_request(:post, "#{GMAIL}/messages/send").to_return do |request|
      @taken << Mail.new(Base64.urlsafe_decode64(JSON.parse(request.body)["raw"]))
      raise Net::ReadTimeout
    end
  end

  teardown do
    Rails.application.config.x.connectors = @connectors
    remove_sidecar_settings
  end

  test "Gmail takes it and hangs past the wait; its Sent holds the Message-ID: the call says sent, and a retry sends nothing" do
    searched = stub_sent { |id| [ { id: "m9", threadId: "t9" } ] if id == @taken.last&.message_id }

    outcome = run_call(MAIL, "c1")
    id = @taken.sole.message_id
    assert_not outcome["isError"], outcome.inspect
    assert_equal({ "sent" => [ "sam@example.net" ], "messageId" => id }, outcome["result"], "sent, not failed")
    assert_equal [ "sent", id ], dispatch("c1").values_at("state", "provider_id")
    assert_equal [ "rfc822msgid:#{id} in:sent" ], searched, "only that message, only in Sent"

    retry_outcome = run_call(MAIL, "c2")
    assert retry_outcome["isError"]
    assert_match(/This same email went to sam@example\.net at .* \(Message-ID <#{Regexp.escape(id)}>\), so it wasn't sent again/,
      retry_outcome.dig("result", "error"))
    assert_equal 1, @taken.size, "sent once"
  end

  test "not in its Sent: unknown, don't retry, and checked again later" do
    stub_sent { nil }

    outcome = run_call(MAIL, "c1")
    assert_not outcome["isError"], outcome.inspect
    assert_equal [ "sam@example.net" ], outcome.dig("result", "unknown")
    assert_equal @taken.sole.message_id, outcome.dig("result", "messageId")
    assert_match(/can't be found in your Sent folder yet.*Don't send it again/, outcome.dig("result", "note"))
    assert_equal "checking", dispatch("c1")["state"]
    assert_match(/may have gone and is still being checked/, run_call(MAIL, "c2").dig("result", "error"))
    assert_equal 1, @taken.size
  end

  test "its Sent can't be searched: unknown, don't retry" do
    stub_request(:get, "#{GMAIL}/messages").with(query: hash_including({})).to_raise(Net::OpenTimeout)

    outcome = run_call(MAIL, "c1")
    assert_equal [ "sam@example.net" ], outcome.dig("result", "unknown")
    assert_match(/Don't send it again/, outcome.dig("result", "note"))
  end

  test "a send through the connector is Gmail's, not SMTP: nothing is filed over IMAP, even with its own mail account" do
    @agent.create_mail_account!(address: "desk@mail.example.com", smtp_host: "smtp.mail.example.com", imap_host: "imap.mail.example.com",
      vault_entry: "Agent mailbox")
    stub_request(:post, "#{GMAIL}/messages/send").to_return(status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "m1", threadId: "t1" }.to_json)
    opened, original = [], Net::IMAP.method(:new)
    Net::IMAP.define_singleton_method(:new) { |host, **| opened << host and raise "no IMAP" }

    outcome = run_call(MAIL, "c1")
    assert_not outcome["isError"], outcome.inspect
    assert_empty opened
  ensure
    Net::IMAP.define_singleton_method(:new, original) if original
  end

  private
    def stub_sent
      searched = []
      stub_request(:get, "#{GMAIL}/messages").with(query: hash_including({})).to_return do |request|
        query = Rack::Utils.parse_query(request.uri.query)
        searched << query["q"]
        found = yield(query["q"][/\Arfc822msgid:(\S+) in:sent\z/, 1])
        { status: 200, headers: { "Content-Type" => "application/json" }, body: { messages: found, resultSizeEstimate: found.to_a.size }.compact.to_json }
      end
      searched
    end

    def dispatch(call_id) = @conversation.invocations.find_by!(call_id: call_id).dispatch&.attributes

    def invoke(arguments, call_id)
      post "/agent/invocations", params: invocation_payload(@conversation, tool: SEND, arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      response.parsed_body
    end

    # Gmail's send asks the person every time; Alice allows each.
    def run_call(arguments, call_id)
      invoke(arguments, call_id)
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @alice)
      invoke(arguments, call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(arguments, call_id)
    end
end
