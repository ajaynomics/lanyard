require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

class PendingSendApprovalsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    install_email_settings
    ActionMailer::Base.deliveries.clear
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the signed-in person's agent
    @conversation = create_conversation(@agent)
    @agent.update!(asks_every_email: true)
    @grant = @agent.permissions.create!(tool_name: "send_email", granted_by: @agent.user)
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "turning off leaves unanswered admitted mail to allow or deny, while new mail follows the restored policy" do
    with_setting(:access, :emails, [ @agent.user.email ]) do
      allowed, denied = %w[ allow deny ].map { receive_mail(it) }
      assert allowed.awaiting_person?
      assert denied.awaiting_person?

      assert_no_enqueued_jobs(only: InvocationCallJob) { turn_off }
      assert_empty ActionMailer::Base.deliveries
      [ allowed, denied ].each do |call|
        assert_equal "waiting", call.advance[:status], "a replay must not release a pending decision"
        assert call.reload.answerable?
        assert_equal :approval, call.asks
        html = card_for(call)
        assert_equal "Allow send email?", html.at_css(".ui-card__title").text.strip
        assert_includes html.css(".ui-card__actions button").map { it.text.strip }, "Allow once"
        assert_includes html.css(".ui-card__actions button").map { it.text.strip }, "Deny"
        assert_not_includes html.text, "Waited too long"
      end

      post conversation_invocation_approval_path(@conversation, allowed), params: { decision: "approve" }
      assert_redirected_to conversation_path(@conversation)
      assert allowed.reload.approved?
      post conversation_invocation_approval_path(@conversation, denied), params: { decision: "deny" }
      assert_redirected_to conversation_path(@conversation)
      assert denied.reload.denied?
      assert_empty ActionMailer::Base.deliveries

      allowed.advance
      perform_enqueued_jobs(only: InvocationCallJob)
      assert allowed.reload.succeeded?
      assert_equal [ @agent.user.email ], ActionMailer::Base.deliveries.sole.to
      assert denied.reload.denied?
      assert_equal [ @grant.id ], @agent.permissions.pluck(:id)

      fresh = receive_mail("new-off-policy")
      assert_nil fresh.asks
      assert fresh.running?, "new admitted mail follows the restored automatic policy"
      assert_equal 1, ActionMailer::Base.deliveries.size, "only the explicitly allowed call ran"
    end
  end

  test "an unanswered missing-file card remains blocked from approval but can be denied after switching off" do
    with_setting(:access, :emails, [ @agent.user.email ]) do
      call = receive_mail("missing", attachments: [ "/home/agent/missing.txt" ])
      perform_enqueued_jobs(only: InvocationPreviewJob)
      assert call.reload.awaiting_person?
      assert_no_enqueued_jobs(only: InvocationCallJob) { turn_off }
      assert_equal :approval, call.reload.asks
      assert_not call.approvable?
      html = card_for(call)
      assert_equal [ "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
      assert_includes html.text, "/home/agent/missing.txt didn't arrive"
      post conversation_invocation_approval_path(@conversation, call), params: { decision: "approve" }
      assert_redirected_to conversation_path(@conversation)
      assert call.reload.awaiting_person?
      assert_nil call.approval
      post conversation_invocation_approval_path(@conversation, call), params: { decision: "deny" }
      assert_redirected_to conversation_path(@conversation)
      assert call.reload.denied?
      assert_empty ActionMailer::Base.deliveries
      assert_equal [ @grant.id ], @agent.permissions.pluck(:id)
    end
  end

  %w[ changed missing ].each do |change|
    test "a #{change} attachment still asks again after the pending email switch is turned off" do
      with_setting(:access, :emails, [ @agent.user.email ]) do
        id = "attachment-#{change}"
        Upload.store(@conversation, task_id: "7", call_id: id, path: "/home/agent/plan.txt", bytes: "Bring passports.", each: 1.megabyte, total: 2.megabytes)
        call = receive_mail(id, attachments: [ "/home/agent/plan.txt" ])
        perform_enqueued_jobs(only: InvocationPreviewJob)
        turn_off
        post conversation_invocation_approval_path(@conversation, call), params: { decision: "approve" }
        assert_redirected_to conversation_path(@conversation)
        assert call.reload.approved?
        if change == "changed"
          Upload.store(@conversation, task_id: "7", call_id: id, path: "/home/agent/plan.txt", bytes: "Changed after approval.", each: 1.megabyte, total: 2.megabytes)
        else
          call.uploads.each { it.file.purge; it.destroy! }
        end
        call.advance
        perform_enqueued_jobs(only: InvocationCallJob)
        assert call.reload.awaiting_person?
        assert_equal :approval, call.asks
        assert call.preview["changed"]
        assert_empty ActionMailer::Base.deliveries
        html = card_for(call)
        if change == "changed"
          assert_includes html.text, "The draft changed after you allowed it"
          assert_includes html.text, "plan.txt (23 Bytes)"
          post conversation_invocation_approval_path(@conversation, call), params: { decision: "approve" }
          assert_redirected_to conversation_path(@conversation)
          assert call.reload.approved?
          call.advance
          perform_enqueued_jobs(only: InvocationCallJob)
          assert call.reload.succeeded?
          assert_equal [ "Changed after approval." ], ActionMailer::Base.deliveries.sole.attachments.map { it.decoded.b }
        else
          assert_not call.approvable?
          assert_equal [ "Deny" ], html.css(".ui-card__actions button").map { it.text.strip }
          post conversation_invocation_approval_path(@conversation, call), params: { decision: "approve" }
          assert_redirected_to conversation_path(@conversation)
          assert call.reload.awaiting_person?
          assert_nil call.approval
          post conversation_invocation_approval_path(@conversation, call), params: { decision: "deny" }
          assert_redirected_to conversation_path(@conversation)
          assert call.reload.denied?
        end
        assert_equal [ @grant.id ], @agent.permissions.pluck(:id)
      end
    end
  end

  private
    def receive_mail(id, attachments: [])
      @conversation.reload
      arguments = { "to" => [ @agent.user.email ], "subject" => "Friday", "body" => "Two nights.\nKeep this last line.", "attachments" => attachments }
      payload = invocation_payload(@conversation, tool: "send_email", arguments: arguments, call_id: id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: id, tool: "send_email", arguments: arguments, digest: payload[:digest])
      @conversation.invocations.find_by!(call_id: id)
    end

    def turn_off
      patch agent_path(@agent), params: { agent: { asks_every_email: "0" } }
      assert_response :see_other
      assert_not @agent.reload.asks_every_email?
    end

    def card_for(call)
      Nokogiri::HTML.fragment(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: call }))
    end
end
