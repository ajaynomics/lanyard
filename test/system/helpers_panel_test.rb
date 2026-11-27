require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The Helpers panel at a phone's width and a computer's: empty, then helpers
# working with their newest step, kept current as they report without losing
# what is being typed, told something and cancelled from the panel, and those
# that ended listed under Recent; every agent's under Settings, each agent's
# own in its settings; workflows' runs the same, beside them, kept current
# whatever order their broadcasts arrive in, a step's helper told something
# from within its run. After Message and Cancel the page changes by broadcast,
# in place: no page comes back, and a drawing older than the change, arriving
# late, is dropped. The page never cross-fades. The sidecar is stubbed at
# Rails' HTTP client; its reports are Helper.report, as
# Sidecar::HelpersController calls it.
class HelpersPanelTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
  end
  teardown do
    remove_sidecar_settings
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  [ [ 1280, 800 ], [ 390, 844 ] ].each do |width, height|
    test "at #{width} pixels a person follows helpers from the panel, tells one something, cancels one, and sees those that ended" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
      conversation = create_conversation(@agent)
      other = create_conversation(@agent, durable_id: "13")
      stub_sidecar(conversation, other)

      visit helpers_path
      assert_selector "h1", text: "Helpers"
      assert_selector ".settings__empty", text: "No helpers yet."

      hotels = report(conversation, "toolu_h", "Find three hotels near the venue.", "running",
        calls: [ { "callId" => "t1", "name" => "web_search", "status" => "running" } ], count: 1)
      report(other, "toolu_g", "Book a table for four.", "running")
      assert_selector "#helpers_working + ul > li", count: 2
      row = "#helper_#{hotels.id}"
      assert_selector row, text: "Now: running web search"
      assert_selector "#{row} .ui-status", text: "Working"

      # A panel drawn now, before Message and Cancel, which arrives after them: it must not undo them.
      stale = stale_panel_stream(conversation.user)
      mark_page

      # What is typed stays as the helper reports and the panel morphs.
      fill_in "Message for the helper working on: Find three hotels near the venue.", with: "Only ones with a pool."
      report(conversation, "toolu_h", "Find three hotels near the venue.", "running",
        calls: [ { "callId" => "t1", "name" => "web_search", "status" => "done" }, { "callId" => "t2", "name" => "visit_website", "status" => "running" } ], count: 2)
      assert_selector row, text: "Now: running visit website"
      assert_field "Message for the helper working on: Find three hotels near the venue.", with: "Only ones with a pool."
      wait_for_live_updates
      within(row) { click_on "Message" }
      assert_selector row, text: "You told it: “Only ones with a pool.”"
      assert_field "Message for the helper working on: Find three hotels near the venue.", with: ""
      assert_current_path helpers_path
      wait_until { @sent.any? }
      assert_match(/\] Only ones with a pool\.\n/, @sent.sole["text"])
      assert_no_horizontal_scroll width

      wait_for_live_updates
      within(row) { click_on "Cancel helper" }
      wait_for_live_updates
      within("dialog#confirm[open]") { click_on "Cancel helper" }
      assert_selector "#helpers_recent + ul #{row}", text: "Before you cancelled it, it had run web search."
      assert_selector "#{row} .ui-status", text: "Cancelled"
      assert_current_path helpers_path
      assert_page_kept "Message and Cancel came back by broadcast, with no page"

      # The older drawing, delivered late, is dropped: the panel still shows what Message and Cancel did.
      deliver_late conversation.workspace, stale
      assert_selector "#helpers_recent + ul #{row} .ui-status", text: "Cancelled"
      assert_selector row, text: "You told it: “Only ones with a pool.”"
      assert_no_selector "#helpers_working #{row}"

      report(other, "toolu_g", "Book a table for four.", "done", answer: "Booked for four at eight.", count: 2)
      assert_no_selector "#helpers_working"
      assert_selector "#helpers_recent + ul > li:first-child", text: "Booked for four at eight."
      report(other, "toolu_f", "Read the menu.", "failed", reason: "request_limit")
      assert_selector "#helpers_recent + ul > li:first-child", text: "It stopped without an answer: it reached its limit of model requests."

      visit helpers_path
      assert_selector "#helpers_recent + ul > li", count: 3
      assert_no_horizontal_scroll width

      # The agent made from the first has its own panel: its helpers alone.
      visit agent_helpers_path(other.agent)
      assert_selector "#helpers_recent + ul > li", count: 2
      assert_no_text "Find three hotels"
      click_on "Open thread", match: :first
      assert_current_path conversation_path(other)
    end

    test "at #{width} pixels a person follows workflows from the panel, cancels one, and sees those that ended" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
      conversation = create_conversation(@agent)
      stub_sidecar(conversation)
      stub_request(:post, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/helpers").to_return(body: { started: true }.to_json)

      visit helpers_path
      assert_selector ".settings__empty", text: "No helpers yet."
      watch_view_transitions
      hotels = start_workflow(conversation, "Hotels", "fan_out", %w[ Lisbon Porto Faro ])
      trip = start_workflow(conversation, "Trip plan", "pipeline", %w[ Rome Florence ])
      assert_selector "#workflows_running + ul > li", count: 2
      hotels_row, trip_row = "#workflow_run_#{hotels.id}", "#workflow_run_#{trip.id}"
      assert_selector hotels_row, text: "0 of 3 steps done · 3 working"
      assert_selector trip_row, text: "0 of 2 steps done · Now: step 1, Find hotels in Rome."
      assert_no_selector "#helpers_working"

      step_report(conversation, trip.steps.first, "done", answer: "Rome: the Corner Inn.")
      assert_selector trip_row, text: "1 of 2 steps done · Now: step 2, Find hotels in Florence."
      step_report(conversation, hotels.steps.first, "done", answer: "Lisbon: the Corner Inn.")
      assert_selector hotels_row, text: "1 of 3 steps done · 2 working"
      assert_equal 0, page.evaluate_script("window.viewTransitions.started"), "a live update morphs the panel in place, with no page transition"
      assert_no_horizontal_scroll width

      # A step's helper at work takes a Message, as any helper does; the run keeps one Cancel.
      porto = hotels.steps.second
      porto_row = "#workflow_step_#{porto.id}_row"
      assert_selector "#{hotels_row} .workflow-row__step", count: 2
      assert_selector porto_row, text: "Step 2: Find hotels in Porto."
      stale = stale_panel_stream(conversation.user)
      mark_page
      fill_in "Message for the helper working on: Find hotels in Porto.", with: "Only near the river."
      step_report(conversation, hotels.steps.third, "running", count: 1)
      assert_field "Message for the helper working on: Find hotels in Porto.", with: "Only near the river."
      wait_for_live_updates
      within(porto_row) { click_on "Message" }
      assert_selector porto_row, text: "You told it: “Only near the river.”"
      assert_field "Message for the helper working on: Find hotels in Porto.", with: ""
      wait_until { @sent.any? }
      assert_equal porto.call_id, @sent.sole["callId"]
      assert_no_horizontal_scroll width

      # Cancel changes the panel in place, by broadcast: no page comes back to land over it, and no cross-fade.
      wait_for_live_updates
      within(hotels_row) { click_on "Cancel workflow" }
      wait_for_live_updates
      # The dialog click queues a submission; its response and the Cable redraw arrive separately.
      page.execute_script(<<~JS, conversation_workflow_run_path(conversation, hotels))
        const path = arguments[0]
        document.addEventListener("turbo:submit-end", ({ detail }) => {
          if (detail.success && new URL(detail.formSubmission.action).pathname === path) {
            document.documentElement.dataset.workflowCancellation = "acknowledged"
          }
        })
      JS
      within("dialog#confirm[open]") { click_on "Cancel workflow" }
      assert_selector "html[data-workflow-cancellation=acknowledged]"
      assert_selector "#workflows_recent + ul #{hotels_row}", text: "Before you cancelled it, 1 step had finished."
      assert_selector "#{hotels_row} .ui-status", text: "Cancelled"
      assert_current_path helpers_path
      assert_page_kept "Cancel came back by broadcast, with no page"
      assert_equal 0, page.evaluate_script("window.viewTransitions.started"), "Cancel changed the panel in place"

      # The drawing from before, delivered late, is dropped.
      deliver_late conversation.workspace, stale
      assert_selector "#workflows_recent + ul #{hotels_row} .ui-status", text: "Cancelled"
      assert_no_selector "#{hotels_row} .workflow-row__step"

      step_report(conversation, trip.steps.second, "failed", reason: "request_limit")
      assert_selector "#workflows_recent + ul > li:first-child#{trip_row}", text: "Step 2 stopped: it reached its limit of model requests."
      assert_no_selector "#workflows_running"

      visit agent_helpers_path(@agent)
      assert_selector "#workflows_recent + ul > li", count: 2
      assert_no_horizontal_scroll width
    end
  end

  private
    # Reports come whenever they come: after Message or Cancel no page comes
    # back that could land over the broadcast they make.
    def report(conversation, call_id, task, state, **data)
      Helper.report(conversation, call_id: call_id, task: task, state: state, **data)
    end

    # The person's panel as it is drawn now, as a broadcast that is then held up.
    def stale_panel_stream(user)
      panel = ApplicationController.render(partial: "helpers/panel", locals: { helpers: user.helpers.own, runs: user.workflow_runs })
      %(<turbo-stream action="replace" target="helpers_panel" method="morph" data-late><template>#{panel}</template></turbo-stream>)
    end

    # Sends it now, and sees the page drop it. Only it is counted: a redraw that Cancel sent before it
    # can still be on its way when this starts (#61).
    def deliver_late(workspace, stream)
      page.execute_script(<<~JS)
        if (!window.panelStreams) document.addEventListener("turbo:before-stream-render", event => {
          if (event.target.hasAttribute("data-late")) window.panelStreams.push(event.defaultPrevented ? "dropped" : "shown")
        })
        window.panelStreams = []
      JS
      Turbo::StreamsChannel.broadcast_stream_to workspace, :helpers, content: stream
      wait_until { page.evaluate_script("window.panelStreams.length").positive? }
      assert_equal [ "dropped" ], page.evaluate_script("window.panelStreams"), "the older drawing was dropped"
    end

    # A mark on the page that a morph of a page that came back would take off.
    def mark_page = page.execute_script("document.querySelector('.settings__header').dataset.kept = 'yes'")

    def assert_page_kept(message)
      assert_selector ".settings__header[data-kept=yes]"
      assert_equal "yes", page.evaluate_script("document.querySelector('.settings__header').dataset.kept"), message
    end

    # A step's helper reports as any helper does; the run moves on in a job, as WorkflowRunJob runs it.
    def step_report(conversation, step, state, **data)
      report(conversation, step.call_id, step.task, state, **data)
      conversation.workflow_runs.find(step.run_id).advance
    end

    def start_workflow(conversation, name, kind, cities)
      run = conversation.workflows.create!(name: name, kind: kind, steps: cities.map { { "task" => "Find hotels in #{it}." } })
        .start(call_id: "toolu_#{name.parameterize}")
      run.advance
      run
    end

    # Counts the page's view transitions and the animations each plays.
    def watch_view_transitions
      page.execute_script(<<~JS)
        window.viewTransitions = { started: 0, ready: 0, animated: 0 }
        const start = document.startViewTransition.bind(document)
        document.startViewTransition = update => {
          const transition = start(update)
          window.viewTransitions.started++
          transition.ready.then(() => {
            window.viewTransitions.animated += document.getAnimations().filter(it => it.effect?.pseudoElement?.startsWith("::view-transition")).length
            window.viewTransitions.ready++
          })
          return transition
        }
      JS
    end

    def stub_sidecar(*conversations)
      @sent = []
      conversations.each do |conversation|
        id = conversation.durable_id
        stub_request(:get, "#{SIDECAR}/v1/conversations/#{id}").with(query: hash_including({}))
          .to_return(body: { status: "done", failure: nil, pendingInputs: [] }.to_json)
        stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/#{id}/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
        stub_request(:post, "#{SIDECAR}/v1/conversations/#{id}/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
        stub_request(:post, "#{SIDECAR}/v1/conversations/#{id}/helper_messages").to_return { |request|
          @sent << JSON.parse(request.body)
          { body: { delivered: true }.to_json } }
        stub_request(:post, "#{SIDECAR}/v1/conversations/#{id}/helper_cancellations").to_return(body: { cancelled: true, count: 2,
          tools: [ { callId: "t1", name: "web_search", status: "done" }, { callId: "t2", name: "visit_website", status: "stopped" } ] }.to_json)
      end
    end

    def assert_no_horizontal_scroll(width)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0, "sideways scroll at #{width}"
    end
end
