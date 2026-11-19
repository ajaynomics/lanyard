require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A workflow's run in a real browser, on a phone and a computer: its steps
# change as their helpers report (Turbo broadcasts), a reload shows where it
# stands, and Cancel asks first. The sidecar is stubbed at Rails' HTTP client;
# a helper's reports are made in this process, as Sidecar::HelpersController makes them.
class WorkflowRunsTest < ApplicationSystemTestCase
  include AgentTestHelper

  SIZES = { phone: [ 390, 844 ], computer: [ 1280, 900 ] }.freeze

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @cancels = []
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/\d+/helpers\z}).to_return(body: { started: true }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/\d+/submissions\z}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/\d+/helper_cancellations\z}).to_return { |request|
      @cancels << JSON.parse(request.body)["callId"]
      { body: { cancelled: true, count: 0, tools: [] }.to_json } }
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
    page.current_window.resize_to(1400, 1400)
  end

  SIZES.each do |size, (width, height)|
    test "on a #{size}, a fan-out's steps change as their helpers report, and a reload shows where it stands" do
      page.current_window.resize_to(width, height)
      conversation, run = thread_with_workflow("fan_out", %w[ Lisbon Porto Faro ])
      visit conversation_path(conversation)
      line = find("#workflow_run_#{run.id}")
      assert line.has_text?("Workflow running: Hotels · 0 of 3 steps done")
      assert line.has_text?("1. Working: Find hotels in Lisbon.")
      assert_no_selector "turbo-cable-stream-source:not([connected])", visible: :all

      report conversation, run.steps.first, "done", answer: "**Lisbon:** the Corner Inn."
      assert line.has_text?("Workflow running: Hotels · 1 of 3 steps done")
      assert line.has_text?("1. Done: Find hotels in Lisbon.")
      line.find("summary", text: "1. Done").click
      assert line.has_css?("strong", text: "Lisbon:")
      assert_fits width

      visit conversation_path(conversation)
      assert_selector "#workflow_run_#{run.id}", text: "1 of 3 steps done"
      assert_selector "#workflow_step_#{run.steps.second.id}[data-state=running]"
    end

    test "on a #{size}, Cancel asks first, Keep working keeps it, and Cancel workflow stops it" do
      page.current_window.resize_to(width, height)
      conversation, run = thread_with_workflow("pipeline", %w[ Lisbon Porto ])
      visit conversation_path(conversation)
      within("#workflow_run_#{run.id}") { assert_text "2. Waits for step 1: Find hotels in Porto." }
      assert_fits width

      wait_for_live_updates
      click_on "Cancel workflow"
      within("dialog#confirm[open]") do
        assert_text "Cancel this workflow? Steps already finished stay done."
        click_on "Keep working"
      end
      assert_predicate run.reload, :running?

      wait_for_live_updates
      click_on "Cancel workflow"
      wait_for_live_updates
      within("dialog#confirm[open]") { click_on "Cancel workflow" }
      assert_selector "#workflow_run_#{run.id}[data-state=cancelled]", text: "Workflow cancelled: Hotels"
      assert_selector "#workflow_run_#{run.id} .helper__note", text: "You cancelled it before any step finished."
      assert_no_button "Cancel workflow"
      assert_equal [ run.steps.first.call_id ], @cancels
      assert_equal %w[ cancelled cancelled ], run.steps.reload.map(&:state)
    end
  end

  private
    def thread_with_workflow(kind, cities)
      conversation = create_conversation(@agent, durable_id: (@agent.conversation.durable_id ? "13" : "12"))
      arguments = { "name" => "Hotels", "kind" => kind, "steps" => cities.map { { "task" => "Find hotels in #{it}." } } }
      payload = invocation_payload(conversation, tool: "run_workflow", arguments: arguments, call_id: "toolu_w")
      Invocation.receive(conversation, task_id: 7, call_id: "toolu_w", tool: "run_workflow", arguments: arguments, digest: payload[:digest])
      run = conversation.workflow_runs.sole
      run.advance
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [
          { id: "1", entryId: 1, role: "user", content: "Find me hotels" },
          { id: "2", entryId: 2, role: "assistant", content: "Starting a workflow.[tool: run_workflow]",
            toolCalls: [ { id: "toolu_w", name: "run_workflow", arguments: arguments } ] }
        ], cursor: 2, more: false }.to_json)
      [ conversation, run ]
    end

    def report(conversation, step, state, **data)
      Helper.report(conversation, call_id: step.call_id, task: step.task, state: state, **data)
    end

    # Nothing runs off the side of a phone.
    def assert_fits(width)
      assert_operator evaluate_script("document.documentElement.scrollWidth"), :<=, width
    end
end
