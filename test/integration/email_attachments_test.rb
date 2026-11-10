require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# Files from the agent's computer on send_email (docs/email.md): the sidecar
# hands their bytes over first (POST /agent/uploads), then the call follows.
# To the install's own people it goes at once; to anyone else the card names
# each file and its size, and the approval holds to their bytes.
class EmailAttachmentsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 plan".b.freeze

  setup do
    ActionMailer::Base.deliveries.clear
    install_sidecar_settings
    install_email_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
  end
  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "send_email declares its files and their limits, from the settings, for the sidecar" do
    declared = @conversation.definition[:tools].find { it[:name] == "send_email" }
    assert_equal({ argument: "attachments", maxBytes: 10.megabytes, maxTotalBytes: 20.megabytes }, declared[:files])
    with_setting(:mail, :attachment_limit_mb, 2) do
      assert_equal 2.megabytes, @conversation.definition[:tools].find { it[:name] == "send_email" }.dig(:files, :maxBytes)
    end
    assert_nil @conversation.definition[:tools].find { it[:name] == "remember_note" }[:files], "only a tool that reads files says so"
  end

  test "to the install's own people the files go at once, in the order named, and are cleared once sent" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      upload "/home/agent/plan.pdf", PDF
      upload "/home/agent/notes.txt", "Bring passports."
      done = run_call(mail_to("alice@example.com", attachments: [ "/home/agent/plan.pdf", "/home/agent/notes.txt" ]))

      assert_equal [ "plan.pdf", "notes.txt" ], done.dig("result", "attached")
      mail = ActionMailer::Base.deliveries.sole
      assert_equal [ [ "notes.txt", "Bring passports." ], [ "plan.pdf", PDF ] ], mail.attachments.map { [ it.filename, it.decoded.b ] }.sort
      assert_equal "Two nights.", mail.text_part.body.to_s
      assert_empty @conversation.uploads
      assert_not_includes @conversation.invocations.sole.attributes.to_json, Base64.strict_encode64(PDF)
    end
  end

  test "to anyone else the card names each file and its size; the person allows those bytes, and those go" do
    upload "/home/agent/plan.pdf", PDF
    arguments = mail_to("hotel@example.net", attachments: [ "/home/agent/plan.pdf" ])
    assert_equal "waiting", invoke(arguments)["status"]
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload

    assert call.approvable?
    html = ApplicationController.render(partial: "invocations/invocation", locals: { invocation: call })
    assert_includes html, "plan.pdf (#{PDF.bytesize} Bytes)"
    assert_includes html, "hotel@example.net"

    call.approve!(by: @alice)
    run_call(arguments)
    assert_equal [ PDF ], ActionMailer::Base.deliveries.sole.attachments.map { it.decoded.b }
  end

  # The agent's computer is the agent's: after the person allowed a file, a
  # replay after a restart reads it again, and what it reads may differ.
  test "a file changed after it was allowed voids the approval, and the card asks again showing it now" do
    upload "/home/agent/plan.pdf", PDF
    arguments = mail_to("hotel@example.net", attachments: [ "/home/agent/plan.pdf" ])
    invoke(arguments)
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole
    call.reload.approve!(by: @alice)

    upload "/home/agent/plan.pdf", "Wire the deposit to the account below."
    run_call(arguments)

    call.reload
    assert call.awaiting_person?, "the approval is void"
    assert call.preview["changed"]
    assert_equal [ "plan.pdf (38 Bytes)" ], call.preview["attachments"]
    assert_empty ActionMailer::Base.deliveries
  end

  test "a file that never arrived can't be allowed, and is never sent without" do
    upload "/home/agent/plan.pdf", PDF
    invoke(mail_to("hotel@example.net", attachments: [ "/home/agent/plan.pdf", "/home/agent/gone.pdf" ]))
    perform_enqueued_jobs(only: InvocationPreviewJob)
    call = @conversation.invocations.sole.reload
    assert_not call.approvable?
    assert_match(%r{/home/agent/gone.pdf didn&#39;t arrive}, ApplicationController.render(partial: "invocations/invocation", locals: { invocation: call }))

    with_setting(:access, :emails, [ "alice@example.com" ]) do
      done = run_call(mail_to("alice@example.com", attachments: [ "/home/agent/gone.pdf" ]), call_id: "toolu_2")
      assert_match(%r{/home/agent/gone.pdf didn't arrive from your computer, so nothing was sent}, done.dig("result", "error"))
    end
    assert_empty ActionMailer::Base.deliveries
  end

  test "uploads are held within the limits, only for a tool that reads files, only with RAILS_TOKEN, and only for the person's own conversation" do
    with_setting(:mail, :attachment_limit_mb, 1) do
      with_setting(:mail, :attachments_limit_mb, 1) do
        upload "/a", "x" * 1.megabyte
        assert_response :no_content
        upload "/b", "x"
        assert_response :content_too_large, "over the total"
        upload "/a", "x" * (1.megabyte + 1)
        assert_response :content_too_large, "over the limit for one"
      end
    end
    assert_equal [ "/a" ], @conversation.uploads.pluck(:path)

    upload "/a", "x", tool: "remember_note"
    assert_response :unprocessable_content
    post "/agent/uploads", params: payload("/a", "x").merge(bytes: "not base64!"), headers: rails_bearer, as: :json
    assert_response :unprocessable_content
    post "/agent/uploads", params: payload("/a", "x"), headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
    sam = create_user(name: "Sam")
    post "/agent/uploads", params: payload("/a", "x").merge(actorId: sam.id.to_s), headers: rails_bearer, as: :json
    assert_response :forbidden
  end

  test "an upload's bytes and path stay out of the log" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output, level: :info)
    Rails.logger.broadcast_to(capture)
    upload "/home/agent/passport-scan.pdf", PDF
    assert_response :no_content
    assert_match %r{POST "/agent/uploads"}, output.string
    assert_no_match(/passport-scan|#{Regexp.escape(Base64.strict_encode64(PDF)[0, 12])}/, output.string)
  ensure
    Rails.logger.stop_broadcasting_to(capture)
  end

  test "once a call has gone ahead, its files are what they were" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      upload "/home/agent/plan.pdf", PDF
      arguments = mail_to("alice@example.com", attachments: [ "/home/agent/plan.pdf" ])
      invoke(arguments)
      upload "/home/agent/plan.pdf", "Something else."
      assert_response :no_content
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal [ PDF ], ActionMailer::Base.deliveries.sole.attachments.map { it.decoded.b }
    end
  end

  test "the sweep clears files no call used once no call could still wait for them" do
    upload "/home/agent/plan.pdf", PDF
    travel Invocation::WAIT do
      UploadSweepJob.perform_now
      assert_equal 1, @conversation.uploads.count
    end
    travel Upload::KEEP + 1.minute do
      perform_enqueued_jobs { UploadSweepJob.perform_now }
      assert_empty @conversation.uploads
      assert_equal 0, ActiveStorage::Blob.count # tenancy-ok: the test checks the bytes are gone too
    end
  end

  private
    def mail_to(address, attachments:) = { "to" => [ address ], "subject" => "Trip", "body" => "Two nights.", "attachments" => attachments }

    def payload(path, bytes, tool: "send_email", call_id: "toolu_1")
      { actorId: @alice.id.to_s, workspaceId: @agent.id.to_s, conversationId: @conversation.durable_id, taskId: 7, callId: call_id,
        tool: tool, path: path, bytes: Base64.strict_encode64(bytes) }
    end

    def upload(path, bytes, **options) = post("/agent/uploads", params: payload(path, bytes, **options), headers: rails_bearer, as: :json)

    def invoke(arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      response.parsed_body
    end

    def run_call(arguments, call_id: "toolu_1")
      invoke(arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(arguments, call_id: call_id)
    end
end
