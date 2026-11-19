require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A helper working in the background, from the thread at a phone's width and a
# computer's: its newest step shows live, the person tells it something and
# sees it kept, its answer arrives, and one that finished takes no message.
# A helper is counted as working from its start, before it first reports.
# The sidecar is stubbed at Rails' HTTP client; its reports are Helper.report,
# as Sidecar::HelpersController calls it.
class HelperMessagesTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  [ [ 1280, 800 ], [ 390, 844 ] ].each_with_index do |(width, height), index|
    test "at #{width} pixels a person follows a working helper, tells it something, sees its answer, and a finished one takes nothing" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
      conversation = thread_with_helper("#{30 + index}")
      sent = []
      stub_request(:post, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/helper_messages").to_return { |request|
        sent << JSON.parse(request.body)
        { body: { delivered: true }.to_json } }
      Helper.report(conversation, call_id: "toolu_h", task: "Find three hotels near the venue.", state: "running",
        calls: [ { "callId" => "t1", "name" => "web_search", "status" => "running", "output" => "" } ], count: 1)

      visit conversation_path(conversation)
      card = find("##{Invocation.dom_target('toolu_h')}_helper")
      assert card.has_text?("Helper working on: Find three hotels near the venue. · 1 call")
      assert card.has_css?(".helper__step", text: "Now: running web search")

      # A report moves the step without a reload.
      Helper.report(conversation, call_id: "toolu_h", task: "Find three hotels near the venue.", state: "running",
        calls: [ { "callId" => "t1", "name" => "web_search", "status" => "done", "output" => "found" },
                 { "callId" => "t2", "name" => "visit_website", "status" => "running", "output" => "" } ], count: 2)
      assert_selector ".helper__step", text: "Now: running visit website"

      fill_in "Message for the helper working on: Find three hotels near the venue.", with: "Only ones with a pool."
      wait_for_live_updates
      within(card) { click_on "Message" }
      assert_selector ".helper__messages p", text: "You told it: “Only ones with a pool.”"
      assert_match(/\] Only ones with a pool\.\n/, sent.sole["text"])
      assert_no_horizontal_scroll width

      visit conversation_path(conversation)
      assert_selector ".helper__messages p", text: "You told it: “Only ones with a pool.”"

      # It finishes: its answer shows on its line, and the form goes.
      Helper.report(conversation, call_id: "toolu_h", task: "Find three hotels near the venue.", state: "done",
        answer: "Park Hotel is the one with a pool.", calls: [ { "callId" => "t1", "name" => "web_search", "status" => "done" } ], count: 3)
      assert_selector "##{Invocation.dom_target('toolu_h')}_helper[data-state=done]", text: "Helper finished: Find three hotels near the venue. · 3 calls"
      assert_no_selector "##{Invocation.dom_target('toolu_h')}_helper .helper__message"
      assert_selector ".helper__messages p", text: "You told it: “Only ones with a pool.”"

      # One the sidecar says has ended, before Rails heard, says so.
      Helper.report(conversation, call_id: "toolu_g", task: "Book a table.", state: "running")
      stub_request(:post, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/helper_messages").to_return(body: { delivered: false }.to_json)
      visit conversation_path(conversation)
      fill_in "Message for the helper working on: Book a table.", with: "For four."
      within("##{Invocation.dom_target('toolu_g')}_helper") { click_on "Message" }
      assert_text "That helper had already finished, so it didn't get your message."
      assert_no_selector "##{Invocation.dom_target('toolu_g')}_helper .helper__messages"
    end
  end

  [ [ 1280, 800 ], [ 390, 844 ] ].each_with_index do |(width, height), index|
    test "at #{width} pixels helpers just started are counted at once, before either reports, and the count opens the panel" do
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: width < 500)
      conversation = thread_with_helper("#{40 + index}")

      visit conversation_path(conversation)
      assert_selector "##{Invocation.dom_target('toolu_h')}_helper[data-state=running] button", text: "Cancel helper"
      assert_selector ".status-line__helpers", text: "2 helpers working"
      assert_empty conversation.helpers.where.not(call_count: 0)
      assert_no_horizontal_scroll width

      click_on "2 helpers working"
      assert_current_path agent_helpers_path(@agent)
      assert_selector "#helpers_working + ul > li", count: 2
      assert_selector "#helpers_working + ul > li", text: "Getting started.", count: 2
    end
  end

  private
    def thread_with_helper(durable_id)
      conversation = create_conversation(@agent, durable_id: durable_id)
      started = ->(id, task) { { id: id, name: "subagent", arguments: { task: task, background: true } } }
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "done", failure: nil, pendingInputs: [] }.to_json)
      stub_request(:post, "#{SIDECAR}/v1/conversations/#{durable_id}/submissions").to_return(status: 202, body: { id: 1, status: "queued" }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [
          { id: "1", entryId: 1, role: "user", content: "Find a hotel, and book dinner." },
          { id: "2", entryId: 2, role: "assistant", content: "", toolCalls: [ started.("toolu_h", "Find three hotels near the venue."), started.("toolu_g", "Book a table.") ] },
          { id: "3", entryId: 3, role: "toolResult", toolCallId: "toolu_h", toolName: "subagent", content: "A helper is working on it in the background." },
          { id: "4", entryId: 4, role: "toolResult", toolCallId: "toolu_g", toolName: "subagent", content: "A helper is working on it in the background." },
          { id: "5", entryId: 5, role: "assistant", content: "Two helpers are on it." }
        ], cursor: 5, more: false }.to_json)
      conversation
    end

    def assert_no_horizontal_scroll(width)
      assert_operator page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth"), :<=, 0, "sideways scroll at #{width}"
    end
end
