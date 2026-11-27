require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Tool::BriefReportTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    install_sidecar_settings
    @owner = create_user(name: "Taylor")
    @operator = create_user(name: "Morgan")
    @team = Workspace.make(name: "Team", owner: @owner)
    @team.memberships.create!(user: @operator, role: "member")
    @manager = @owner.start_agent("Lead", workspace: @team)
    @conversation = create_conversation(@manager)
    @setup = @team.agent_setups.build(approved_by: @owner, operator: @operator, manager_id: @manager.id,
      request_id: SecureRandom.uuid, name: "Research desk", instructions: "Summarize evidence.", authorization: "One approved setup.").record!
    @report = @setup.execute!(by: @operator)
    @arguments = { "report_id" => @report.id, "message" => "Relayed summary: Please check the figures." }
  end

  teardown { remove_sidecar_settings }

  test "approval for the exact brief delivers once as the current manager and creates no identity" do
    assert_nil @conversation.tool("brief_report")
    enable_tool
    assert_includes @conversation.definition.fetch(:instructions), "local report ID #{@report.id}"
    assert_equal "waiting", receive("brief-1").fetch(:status)
    assert_empty @report.conversation.submissions
    assert_nil @report.conversation.durable_id
    card = @conversation.invocations.find_by!(call_id: "brief-1")
    html = ApplicationController.render(partial: "invocations/invocation", locals: { invocation: card })
    assert_includes html, "Approve Lead’s first message to Research desk?"
    assert_includes html, @arguments.fetch("message")
    assert_equal @owner, card.approver
    assert_empty card.always_choices
    assert_raises(Invocation::NotTheApprover) { card.approve!(by: @operator) }
    card.approve!(by: @owner)

    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "17" }.to_json)
    dispatch = stub_request(:post, "#{SIDECAR}/v1/conversations/17/submissions").with do |request|
      body = JSON.parse(request.body)
      assert_equal({ "sender" => "Lead" }, body.fetch("author"))
      assert_includes body.fetch("content"), @arguments.fetch("message")
      assert_not body.key?("fromPerson")
      true
    end.to_return(status: 202, body: { id: "42", status: "queued" }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/17/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    receive("brief-1")
    perform_enqueued_jobs(only: InvocationCallJob)

    result = receive("brief-1").fetch(:result)
    assert_equal({ report_id: @report.id, request_id: @setup.first_turn.request_id, accepted: true }, result)
    assert_equal result, receive("brief-1").fetch(:result)
    assert_requested dispatch, times: 1
    assert_empty @report.concourse_agents
    assert_nil @report.campfire_bot
    assert_equal 1, @report.conversation.submissions.count
  end

  test "revoking after approval refuses the exact handoff without preparing or creating an identity" do
    enable_tool
    assert_equal "waiting", receive("brief-2").fetch(:status)
    @conversation.invocations.find_by!(call_id: "brief-2").approve!(by: @owner)
    receive("brief-2")
    @setup.revoke!(by: @owner)
    perform_enqueued_jobs(only: InvocationCallJob)
    assert receive("brief-2").fetch(:isError)
    assert_empty @report.conversation.submissions
    assert_empty @report.concourse_agents
  end

  private
    def enable_tool
      @manager.update!(tool_names: @manager.tool_names + [ "brief_report" ])
      @conversation.reload
    end

    def receive(call_id)
      payload = invocation_payload(@conversation, tool: "brief_report", arguments: @arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "brief_report",
        arguments: @arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
