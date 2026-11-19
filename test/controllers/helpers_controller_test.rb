require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The Helpers panels: every agent's for the person (HelpersController) and each
# agent's own (Agents::HelpersController). Working ones first, then those that
# ended lately, and the workflows' runs the same way; Message and Cancel come
# back to the panel; another person's never show; a report morphs both panels.
class HelpersControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActionCable::TestHelper

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = name_agent(@alice.agents.sole, "Pam")
    @conversation = create_conversation(@agent)
    @other = create_conversation(@agent, durable_id: "13")
    @other_agent = name_agent(@other.agent, "Rex")
    sign_in_via_ajent(subject: @alice.oidc_sub, email: "operator@example.com", name: "Alice")
    # A helper that ends hands its answer to its thread (Conversation#receive).
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/\d+/submissions}).to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "every agent's helpers, working ones first and newest first, then those that ended, newest ending first" do
    finished = report(@conversation, "toolu_a", "Find three hotels near the venue.", "done", answer: "**Park Hotel** has a pool & a gym. " * 20, count: 3)
    travel 1.minute
    report(@other, "toolu_b", "Book a table for four.", "failed", reason: "request_limit")
    report(@conversation, "toolu_c", "Summarize the contract.", "running",
      calls: [ { "callId" => "t1", "name" => "read_file", "status" => "done" }, { "callId" => "t2", "name" => "web_search", "status" => "running" } ], count: 2)
    travel 1.minute
    report(@other, "toolu_d", "Draft the invitation.", "running")
    cancelled = report(@conversation, "toolu_e", "Check the weather.", "running")
    cancelled.update!(state: "cancelled", finished_at: Time.current, calls: [ { "callId" => "t1", "name" => "web_search", "status" => "done" } ])

    get helpers_path

    assert_response :success
    assert_no_match(/\*\*|&amp;amp;/, response.body)
    assert_select "a[aria-current=page]", text: "Helpers"
    assert_equal [ "Draft the invitation.", "Summarize the contract." ], css_select("#helpers_working + ul > li").map { it.at(".ui-row__label").children.first.text.strip }
    assert_equal [ "Check the weather.", "Book a table for four.", "Find three hotels near the venue." ],
      css_select("#helpers_recent + ul > li").map { it.at(".ui-row__label").children.first.text.strip }

    assert_select "#helper_#{@conversation.helpers.find_by!(call_id: "toolu_c").id}" do
      assert_select ".ui-row__detail", text: /\APam · Started\s+1 minute ago · 2 calls\z/
      assert_select ".helper__step", "Now: running web search"
      assert_select ".ui-status", "Working"
      assert_select "a[href=?]", conversation_path(@conversation), text: "Open thread"
      assert_select "form.helper__message[action=?][data-controller=keeps-typing]", conversation_helper_messages_path(@conversation, @conversation.helpers.find_by!(call_id: "toolu_c"))
      assert_select "form[action=?] button", conversation_helper_path(@conversation, @conversation.helpers.find_by!(call_id: "toolu_c")), text: "Cancel helper"
    end
    assert_select "#helper_#{finished.id}" do
      assert_select ".ui-row__detail", text: /\APam · Ended\s+2 minutes ago · 3 calls\z/
      assert_select ".ui-row__detail", text: /\APark Hotel has a pool & a gym\. Park Hotel.*\.\.\.\z/ # its Markdown read as text
      assert_select ".ui-status", "Finished"
      assert_select "form", count: 0
    end
    assert_select ".ui-row", text: /Rex · Ended.*It stopped without an answer: it reached its limit of model requests\..*Stopped/m do
      assert_select "a[href=?]", conversation_path(@other), text: "Open thread"
    end
    assert_select "#helper_#{cancelled.id}", text: /Before you cancelled it, it had run web search\..*Cancelled/m
  end

  test "an agent's own panel lists its helpers alone, and its settings link to it" do
    report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")
    report(@other, "toolu_b", "Book a table for four.", "running")

    get agent_helpers_path(@agent)

    assert_response :success
    assert_select "a[aria-current=page]", text: "Helpers"
    assert_select "#helpers_working + ul > li", count: 1, text: /Find three hotels near the venue\./
    assert_select ".ui-row", text: /Book a table/, count: 0
    assert_select ".ui-row__detail", text: /Pam ·/, count: 0
  end

  test "with none yet, each panel says what will show there" do
    get helpers_path
    assert_select ".settings__empty", text: /No helpers yet\. When one of your agents hands a task to a helper/

    get agent_helpers_path(@agent)
    assert_select ".settings__empty", text: /No helpers yet\. When Pam hands a task to a helper/
  end

  test "another person's helpers never show, and their agent's panel is not found" do
    bob = create_user(name: "Bob")
    bobs = create_conversation(bob.agents.sole, durable_id: "20")
    report(bobs, "toolu_b", "Bob's secret errand.", "running")
    report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")

    get helpers_path
    assert_select ".ui-row", count: 1, text: /Find three hotels/
    assert_no_match(/secret errand/, response.body)

    get agent_helpers_path(bob.agents.sole)
    assert_response :not_found
  end

  test "Message and Cancel from the panel go back to it" do
    helper = report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_messages").to_return(body: { delivered: true }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return(body: { cancelled: true, count: 0, tools: [] }.to_json)

    post conversation_helper_messages_path(@conversation, helper), params: { text: "Only ones with a pool." }, headers: { "Referer" => helpers_url }
    assert_redirected_to helpers_url
    follow_redirect!
    assert_select "#helper_#{helper.id} .ui-row__detail", "You told it: “Only ones with a pool.”"

    delete conversation_helper_path(@conversation, helper), headers: { "Referer" => agent_helpers_url(@agent) }
    assert_redirected_to agent_helpers_url(@agent)
    follow_redirect!
    assert_select "#helpers_recent + ul #helper_#{helper.id}", text: /You cancelled it before it did anything\..*Cancelled/m

    post conversation_helper_messages_path(@conversation, helper), params: { text: "Too late." }, headers: { "Referer" => helpers_url }
    assert_redirected_to helpers_url
    assert_equal "That helper had already finished, so it didn't get your message.", flash[:alert]
  end

  test "Message and Cancel from a page that follows broadcasts get no page back: the broadcast of the fresh panel shows the change" do
    helper = report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_messages").to_return(body: { delivered: true }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return(body: { cancelled: true, count: 0, tools: [] }.to_json)
    turbo = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => helpers_url }

    told = capture_turbo_stream_broadcasts([ @alice.personal_workspace, :helpers ]) do
      post conversation_helper_messages_path(@conversation, helper), params: { text: "Only ones with a pool." }, headers: turbo
    end
    assert_response :ok
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_empty response.body
    assert_includes told.last.to_html, "You told it: “Only ones with a pool.”"

    cancelled = capture_turbo_stream_broadcasts([ @agent, :helpers ]) { delete conversation_helper_path(@conversation, helper), headers: turbo }
    assert_response :ok
    assert_empty response.body
    assert_equal [ "replace", "helpers_panel", "morph" ], [ cancelled.last["action"], cancelled.last["target"], cancelled.last["method"] ]
    assert_select Nokogiri::HTML5.fragment(cancelled.last.to_html), "#helpers_recent + ul #helper_#{helper.id} .ui-status", "Cancelled"

    # Too late: the box keeps its words (a failed submission) and an alert says why.
    post conversation_helper_messages_path(@conversation, helper), params: { text: "Too late." }, headers: turbo
    assert_response :conflict
    assert_select "turbo-stream[action=update][target=flash] template .flash[role=alert]", "That helper had already finished, so it didn't get your message."
    delete conversation_helper_path(@conversation, helper), headers: turbo
    assert_response :conflict
    assert_select "turbo-stream[target=flash]", "That helper had already finished."
  end

  test "a workflow's step at work has a Message in the panel, which reaches its helper and redraws the panel" do
    run = start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon Porto Faro ])
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helpers").to_return(body: { started: true }.to_json)
    sent = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_messages").to_return { |request| sent << JSON.parse(request.body); { body: { delivered: true }.to_json } }
    run.steps.first.start
    run.steps.second.start
    report(@conversation, run.steps.second.call_id, run.steps.second.task, "done", answer: "Porto: the Lodge.")
    lisbon = run.steps.first.helper

    get helpers_path
    assert_select "#workflow_run_#{run.id}" do
      assert_select ".workflow-row__step", count: 1
      assert_select "#workflow_step_#{run.steps.first.id}_row" do
        assert_select ".ui-row__detail", "Step 1: Find hotels in Lisbon."
        assert_select "form.helper__message[action=?][data-controller=keeps-typing]", conversation_helper_messages_path(@conversation, lisbon)
        assert_select "label.visually-hidden", "Message for the helper working on: Find hotels in Lisbon."
      end
      assert_select "form[action=?] button", conversation_workflow_run_path(@conversation, run), text: "Cancel workflow"
      assert_select "form[action=?]", conversation_helper_path(@conversation, lisbon), count: 0
    end

    told = capture_turbo_stream_broadcasts([ @alice.personal_workspace, :helpers ]) do
      post conversation_helper_messages_path(@conversation, lisbon), params: { text: "Only near the sea." },
        headers: { "Accept" => "text/vnd.turbo-stream.html, text/html", "Referer" => helpers_url }
    end
    assert_response :ok
    assert_equal [ lisbon.call_id ], sent.pluck("callId")
    assert_match(/\] Only near the sea\.\n/, sent.sole["text"])
    assert_select Nokogiri::HTML5.fragment(told.last.to_html), "#workflow_step_#{run.steps.first.id}_row .ui-row__detail", text: "You told it: “Only near the sea.”"

    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return(body: { cancelled: true, count: 0, tools: [] }.to_json)
    run.cancel
    get helpers_path
    assert_select ".workflow-row__step", count: 0
  end

  test "a report redraws the agent's panel and the person's, and nobody else's" do
    bob = create_user(name: "Bob")
    agent_refreshes = capture_turbo_stream_broadcasts([ @agent, :helpers ]) do
      @person_refreshes = capture_turbo_stream_broadcasts([ @alice.personal_workspace, :helpers ]) do
        report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")
      end
    end
    assert_redraws agent_refreshes, named: false
    assert_redraws @person_refreshes, named: true
    assert_empty capture_turbo_stream_broadcasts([ bob.personal_workspace, :helpers ])
    assert_empty capture_turbo_stream_broadcasts([ @other_agent, :helpers ])
  end

  test "workflows' runs are a section of their own: running first, newest first, then those that ended; their steps' helpers are not among the agent's own" do
    hotels = start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon Porto Faro ])
    hotels.steps.first.update!(state: "done", answer: "Corner Inn.", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    hotels.steps.second.update!(state: "running", started_at: 1.minute.ago)
    hotels.steps.third.update!(state: "running", started_at: 1.minute.ago)
    report(@conversation, hotels.steps.second.call_id, hotels.steps.second.task, "running")
    travel 1.minute
    trip = start_workflow(@other, "Trip plan", "pipeline", %w[ Rome Florence Venice ])
    trip.steps.first.update!(state: "done", answer: "Rome first.", finished_at: Time.current)
    trip.steps.second.update!(state: "running", started_at: Time.current)
    summary = start_workflow(@conversation, "Summary", "pipeline", %w[ Notes Draft ])
    summary.steps.each { it.update!(state: "done", answer: "**Final:** the draft, in two pages.", finished_at: Time.current) }
    summary.update!(state: "done", finished_at: 3.minutes.ago)
    failed = start_workflow(@conversation, "Prices", "fan_out", %w[ Oslo Bergen ])
    failed.steps.first.update!(state: "done", answer: "Cheap.", finished_at: Time.current)
    failed.steps.second.update!(state: "failed", reason: "it reached its limit of model requests", finished_at: Time.current)
    failed.update!(state: "failed", finished_at: 1.minute.ago)
    cancelled = start_workflow(@conversation, "Flights", "fan_out", %w[ Paris ])
    cancelled.update!(state: "cancelled", finished_at: 2.minutes.ago)
    cancelled.steps.sole.update!(state: "cancelled", finished_at: Time.current)
    report(@conversation, "toolu_a", "Find three hotels near the venue.", "running")

    get helpers_path

    assert_select "#helpers_working + ul > li", count: 1, text: /Find three hotels near the venue\./
    assert_equal [ "Trip plan", "Hotels" ], css_select("#workflows_running + ul > li").map { it.at(".ui-row__label").children.first.text.strip }
    assert_equal [ "Prices", "Flights", "Summary" ], css_select("#workflows_recent + ul > li").map { it.at(".ui-row__label").children.first.text.strip }
    assert_select "#workflow_run_#{hotels.id}" do
      assert_select ".ui-row__detail", text: /\APam · 3 helpers at once ·\s+started\s+1 minute ago\z/
      assert_select ".ui-row__detail", text: "1 of 3 steps done · 2 working"
      assert_select ".ui-status", "Working"
      assert_select "a[href=?]", conversation_path(@conversation), text: "Open thread"
      assert_select "form[action=?] button", conversation_workflow_run_path(@conversation, hotels), text: "Cancel workflow"
    end
    assert_select "#workflow_run_#{trip.id} .ui-row__detail", text: "1 of 3 steps done · Now: step 2, Find hotels in Florence."
    assert_select "#workflow_run_#{summary.id}" do
      assert_select ".ui-row__detail", text: "Final: the draft, in two pages."
      assert_select ".ui-status", "Finished"
      assert_select "form", count: 0
    end
    assert_select "#workflow_run_#{failed.id}", text: /Step 2 stopped: it reached its limit of model requests\..*Stopped/m
    assert_select "#workflow_run_#{cancelled.id}", text: /You cancelled it before any step finished\..*Cancelled/m
  end

  test "an agent's own panel lists its workflows alone, and another person's never show" do
    start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon ])
    start_workflow(@other, "Trip plan", "pipeline", %w[ Rome ])
    bob = create_user(name: "Bob")
    start_workflow(create_conversation(bob.agents.sole, durable_id: "20"), "Bob's secret errand", "fan_out", %w[ Bank ])

    get agent_helpers_path(@agent)
    assert_select "#workflows_running + ul > li", count: 1, text: /Hotels/
    assert_no_match(/Trip plan|secret errand/, response.body)

    get helpers_path
    assert_select "#workflows_running + ul > li", count: 2
    assert_no_match(/secret errand/, response.body)
  end

  test "Cancel for a workflow from the panel goes back to it, and the run moves to Recent" do
    run = start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon Porto ])
    run.steps.each { it.update!(state: "running", started_at: Time.current) }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/helper_cancellations").to_return(body: { cancelled: true, count: 0, tools: [] }.to_json)

    delete conversation_workflow_run_path(@conversation, run), headers: { "Referer" => helpers_url }
    assert_redirected_to helpers_url
    follow_redirect!
    assert_select "#workflows_recent + ul #workflow_run_#{run.id}", text: /You cancelled it before any step finished\..*Cancelled/m
  end

  test "a run that moves redraws the agent's panel and the person's" do
    run = start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon ])
    agent_refreshes = capture_turbo_stream_broadcasts([ @agent, :helpers ]) do
      @person_refreshes = capture_turbo_stream_broadcasts([ @alice.personal_workspace, :helpers ]) { run.steps.sole.update!(state: "running") }
    end
    assert_redraws agent_refreshes, named: false
    assert_redraws @person_refreshes, named: true
  end

  test "Cancel for a workflow from a page that follows broadcasts gets no page back, and the broadcast shows it ended" do
    run = start_workflow(@conversation, "Hotels", "fan_out", %w[ Lisbon ])
    turbo = { "Accept" => "text/vnd.turbo-stream.html, text/html", "Referer" => helpers_url }
    shown = capture_turbo_stream_broadcasts([ @alice.personal_workspace, :helpers ]) { delete conversation_workflow_run_path(@conversation, run), headers: turbo }
    assert_response :ok
    assert_empty response.body
    assert_select Nokogiri::HTML5.fragment(shown.last.to_html), "#workflows_recent + ul #workflow_run_#{run.id} .ui-status", "Cancelled"

    delete conversation_workflow_run_path(@conversation, run), headers: turbo
    assert_response :conflict
    assert_select "turbo-stream[target=flash]", "That workflow had already finished."
  end

  test "the thread's count of working helpers opens its agent's panel" do
    shown = capture_turbo_stream_broadcasts(@conversation) { report(@conversation, "toolu_a", "Find three hotels near the venue.", "running") }
    line = shown.find { it["target"] == "status_summary_conversation_#{@conversation.id}" }
    assert_equal agent_helpers_path(@agent), line.at("a.status-line__helpers")["href"]
    assert_equal "1 helper working", line.at("a.status-line__helpers").text
  end

  private
    def report(conversation, call_id, task, state, **data)
      Helper.report(conversation, call_id: call_id, task: task, state: state, **data)
    end

    # Each a morph of the whole panel, the person's naming each row's agent.
    def assert_redraws(streams, named:)
      assert_not_empty streams
      streams.each do |stream|
        assert_equal [ "replace", "helpers_panel", "morph" ], [ stream["action"], stream["target"], stream["method"] ]
        assert_equal named, stream.at(".ui-row__detail").text.start_with?("Pam ·")
      end
    end

    def start_workflow(conversation, name, kind, cities)
      conversation.workflows.create!(name: name, kind: kind, steps: cities.map { { "task" => "Find hotels in #{it}." } })
        .start(call_id: "toolu_#{name.parameterize}")
    end
end
