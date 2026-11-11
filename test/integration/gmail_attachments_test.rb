require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Files from the agent's computer on a Gmail connector's send_message and
# create_draft, as on send_email (docs/email.md): the sidecar hands their bytes
# over first (POST /agent/uploads), the card names each file and its size, the
# approval holds to their bytes, and the message goes as multipart/mixed.
class GmailAttachmentsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 plan".b.freeze
  SEND = "mcp__gmail__send_message".freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    x = Rails.application.config.x
    @connectors, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
    connector("gmail")
  end
  teardown do
    Rails.application.config.x.connectors = @connectors
    remove_sidecar_settings
  end

  test "send_message and create_draft declare their files as send_email does, on every Gmail connector, and add no tool" do
    send_email = Tool::SendEmail.declaration[:files]
    declared = @conversation.definition[:tools].index_by { it[:name] }
    assert_equal send_email, declared[SEND][:files]
    assert_equal send_email, declared["mcp__gmail__create_draft"][:files]
    assert_equal Tool::SendEmail.schema.dig("properties", "attachments"), declared[SEND].dig(:parameters, "properties", "attachments")
    assert_nil declared["mcp__gmail__update_draft"][:files]
    assert_equal 12, McpServer::Google.listing(:gmail).size
    assert_equal McpServer::Google.listing(:gmail).map { "mcp__gmail__#{it['name']}" }.sort, declared.keys.grep(/\Amcp__gmail__/).sort

    # Two accounts are one set of tools (Tool::Mcp::Group), still twelve, and theirs take files too.
    connector("gmail", name: "gmail_work")
    declared = @conversation.reload.definition[:tools].index_by { it[:name] }
    assert_equal 12, declared.keys.grep(/\Amcp__gmail__/).size
    assert_equal send_email, declared[SEND][:files]
    upload "/home/agent/plan.pdf", PDF
    assert_response :no_content
  end

  test "a message with files asks with a card naming each and its size; allowed, one multipart reply goes into its thread" do
    stub_request(:get, "#{GMAIL}/threads/t1").with(query: hash_including(format: "metadata"))
      .to_return(json(messages: [ { id: "m1", payload: { headers: [ { name: "Subject", value: "Lunch" }, { name: "Message-ID", value: "<a@example.com>" } ] } } ]))
    sent = []
    stub_request(:post, "#{GMAIL}/messages/send").with { sent << JSON.parse(it.body) }.to_return(json(id: "m9", threadId: "t1"))
    upload "/home/agent/plan.pdf", PDF
    upload "/home/agent/notes.txt", "Bring passports."
    arguments = mail_to("sam@example.net", thread_id: "t1", attachments: [ "/home/agent/plan.pdf", "/home/agent/notes.txt" ])

    assert_equal "waiting", invoke(SEND, arguments)["status"]
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload
    assert call.approvable?
    html = ApplicationController.render(partial: "invocations/invocation", locals: { invocation: call })
    assert_includes html, "plan.pdf (#{PDF.bytesize} Bytes)"
    assert_includes html, "notes.txt (16 Bytes)"
    assert_includes html, "Two nights."
    assert_empty sent

    call.approve!(by: @alice)
    done = run_call(SEND, arguments)
    assert_equal({ "sent" => true, "message_id" => "m9", "thread_id" => "t1" }, done["result"])
    assert_equal 1, sent.size
    assert_equal "t1", sent.sole["threadId"]
    mail = Mail.new(Base64.urlsafe_decode64(sent.sole["raw"]))
    assert_equal "multipart/mixed", mail.mime_type
    # The text first; the Mail gem orders the files by type.
    assert_equal [ "text/plain", nil ], [ mail.parts.first.mime_type, mail.parts.first.filename ]
    files = mail.attachments.to_h { [ it.filename, [ it.mime_type, it.content_transfer_encoding, it.decoded.b ] ] }
    assert_equal({ "plan.pdf" => [ "application/pdf", "base64", PDF ], "notes.txt" => [ "text/plain", "7bit", "Bring passports." ] }, files, "a binary file in base64; plain text as it is")
    assert_equal "Two nights.", mail.text_part.decoded
    assert_equal [ "Re: Lunch", "a@example.com", "a@example.com" ], [ mail.subject, mail.in_reply_to, mail.references ]
  end

  test "a draft with a file is saved as multipart; a file that changed after it was allowed asks again" do
    drafts = []
    stub_request(:post, "#{GMAIL}/drafts").with { drafts << JSON.parse(it.body) }.to_return(json(id: "d1", message: { id: "m1", threadId: "t2" }))
    upload "/home/agent/plan.pdf", PDF
    arguments = mail_to("sam@example.net", attachments: [ "/home/agent/plan.pdf" ])
    invoke("mcp__gmail__create_draft", arguments)
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload
    assert_equal [ "plan.pdf (#{PDF.bytesize} Bytes)" ], call.preview["attachments"]
    call.approve!(by: @alice)

    upload "/home/agent/plan.pdf", "Wire the deposit to the account below."
    run_call("mcp__gmail__create_draft", arguments)
    assert call.reload.awaiting_person?, "the approval is void"
    assert_equal [ "plan.pdf (38 Bytes)" ], call.preview["attachments"]
    assert_empty drafts

    call.approve!(by: @alice)
    assert_equal "d1", run_call("mcp__gmail__create_draft", arguments).dig("result", "draft_id")
    mail = Mail.new(Base64.urlsafe_decode64(drafts.sole.dig("message", "raw")))
    assert_equal [ "Wire the deposit to the account below." ], mail.attachments.map(&:decoded)
  end

  test "a file that didn't arrive, or was over the limits, stops the call by its name alone, and nothing is sent or saved" do
    sends = stub_request(:post, "#{GMAIL}/messages/send")
    drafts = stub_request(:post, "#{GMAIL}/drafts")
    upload "/home/agent/plan.pdf", PDF
    invoke(SEND, mail_to("sam@example.net", attachments: [ "/home/agent/plan.pdf", "/home/agent/gone.pdf" ]))
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload
    assert_not call.approvable?
    html = ApplicationController.render(partial: "invocations/invocation", locals: { invocation: call })
    assert_includes html, "gone.pdf didn&#39;t arrive from the computer"
    assert_not_includes html, "/home/agent/gone.pdf"

    with_setting(:app, :approvals, "allow") do
      done = run_call("mcp__gmail__create_draft", mail_to("sam@example.net", attachments: [ "/home/agent/gone.pdf" ]), call_id: "toolu_2")
      assert_equal "gone.pdf didn't arrive from your computer, so nothing was sent or saved. Send again.", done.dig("result", "error")
      assert_not_includes done.to_json, "/home/agent/gone.pdf"

      with_setting(:mail, :attachment_limit_mb, 1) do
        upload "/home/agent/big.pdf", "x" * (1.megabyte + 1), call_id: "toolu_3", tool: "mcp__gmail__create_draft"
        assert_response :content_too_large
        done = run_call("mcp__gmail__create_draft", mail_to("sam@example.net", attachments: [ "/home/agent/big.pdf" ]), call_id: "toolu_3")
        assert_match(/big.pdf didn't arrive/, done.dig("result", "error"))
      end
    end
    assert_not_requested sends
    assert_not_requested drafts
  end

  test "called through find_tools, a tool's files don't arrive, so the call is refused and nothing is saved" do
    drafts = stub_request(:post, "#{GMAIL}/drafts")
    @alice.mcp_servers.sole.update!(loaded: false)
    with_setting(:app, :approvals, "allow") do
      done = run_call("use_tool", { "name" => "mcp__gmail__create_draft", "arguments" => mail_to("sam@example.net", attachments: [ "/home/agent/plan.pdf" ]) })
      assert_equal "plan.pdf didn't arrive from your computer, so nothing was sent or saved. Send again.", done.dig("result", "error")
    end
    assert_not_requested drafts
  end

  test "a declined message sends nothing, and the agent is told" do
    sends = stub_request(:post, "#{GMAIL}/messages/send")
    upload "/home/agent/plan.pdf", PDF
    arguments = mail_to("sam@example.net", attachments: [ "/home/agent/plan.pdf" ])
    invoke(SEND, arguments)
    @conversation.invocations.sole.deny!(by: @alice)
    assert_match(/\AAlice declined #{SEND}/, run_call(SEND, arguments).dig("result", "error"))
    assert_not_requested sends
  end

  test "without files a message is the same request as before: plain text, no card of its own, no file" do
    sent = []
    stub_request(:post, "#{GMAIL}/messages/send").with { sent << JSON.parse(it.body) }.to_return(json(id: "m9", threadId: "t9"))
    arguments = mail_to("sam@example.net")
    invoke(SEND, arguments)
    call = @conversation.invocations.sole
    assert_no_enqueued_jobs(only: InvocationPreviewJob)
    assert call.approvable?
    call.approve!(by: @alice)
    run_call(SEND, arguments)

    assert_equal [ "raw" ], sent.sole.keys
    raw = Base64.urlsafe_decode64(sent.sole["raw"])
    assert_match %r{^Content-Type: text/plain;\r\n charset=UTF-8\r\n}, raw
    assert_no_match(/multipart|Content-Disposition/, raw)
    assert_equal "Two nights.", Mail.new(raw).body.decoded
  end

  test "a file's bytes and path stay out of the log" do
    stub_request(:post, "#{GMAIL}/messages/send").to_return(json(id: "m9", threadId: "t9"))
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output, level: :info)
    Rails.logger.broadcast_to(capture)
    upload "/home/agent/passport-scan.pdf", PDF
    arguments = mail_to("sam@example.net", attachments: [ "/home/agent/passport-scan.pdf" ])
    invoke(SEND, arguments)
    perform_enqueued_jobs(only: InvocationPreviewJob)
    @conversation.invocations.sole.reload.approve!(by: @alice)
    run_call(SEND, arguments)
    assert_match %r{POST "/agent/invocations"}, output.string
    assert_no_match(/passport-scan|#{Regexp.escape(Base64.strict_encode64(PDF)[0, 12])}/, output.string)
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  private
    def connector(kind, name: kind)
      @alice.mcp_servers.create!(name: name, **McpServer.gallery_attributes(kind), tools: [], refreshed_at: Time.current,
        oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 1.hour.from_now.to_i })
    end

    def mail_to(address, attachments: nil, thread_id: nil)
      { "to" => [ address ], "subject" => ("Trip" unless thread_id), "body" => "Two nights.", "thread_id" => thread_id, "attachments" => attachments }.compact
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }

    def payload(path, bytes, tool: SEND, call_id: "toolu_1")
      { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s, conversationId: @conversation.durable_id, taskId: 7, callId: call_id,
        tool: tool, path: path, bytes: Base64.strict_encode64(bytes) }
    end

    def upload(path, bytes, **options) = post("/agent/uploads", params: payload(path, bytes, **options), headers: rails_bearer, as: :json)

    def invoke(tool, arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      response.parsed_body
    end

    def run_call(tool, arguments, call_id: "toolu_1")
      invoke(tool, arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(tool, arguments, call_id: call_id)
    end
end
