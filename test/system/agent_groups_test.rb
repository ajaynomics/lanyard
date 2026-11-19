require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The agents list on screen, a group per workspace (conversations/_group),
# links that open another of the person's workspaces, and two people in one
# shared workspace. Bob is the person the browser signs in as; Alice owns the
# shared workspace.
class AgentGroupsTest < ApplicationSystemTestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    @entries = []
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/\d+/entries}).to_return { { body: { entries: @entries, cursor: @entries.size.nonzero?, more: false }.to_json } }
    @alice = create_user(name: "Alice", email: "member@example.com")
    sign_in_via_ajent
    @bob = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @bob.start_agent("Bob's own") if @bob.agents.none?
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "in only his personal workspace Bob sees its group alone, its name a link to its page" do
    visit root_path
    assert_selector "h1", text: "Agents"
    assert_selector ".agent-group", count: 1
    assert_selector ".agent-group__title a", text: "Test Operator"
    assert_selector ".conversation-row", text: bobs_agent.name
    assert_no_selector ".workspace-switcher"
  end

  test "in two, both groups, his own first, each live on its own workspace with nothing to switch" do
    share_with_bob
    visit root_path
    assert_equal [ "Test Operator Yours", "Household 2 people" ], all(".agent-group__title").map { it.text.squish }
    within("#group_workspace_#{@bob.personal_workspace.id}") { assert_selector ".conversation-row", text: bobs_agent.name }
    within("#group_workspace_#{@shared.id}") { assert_selector ".conversation-row", text: "Shared" }

    wait_for_live_updates
    @bob.start_agent("Bob's second")
    @alice.start_agent("Planner", workspace: @shared)
    within("#group_workspace_#{@bob.personal_workspace.id}") { assert_selector ".conversation-row", text: "Bob's second" }
    within("#group_workspace_#{@shared.id}") { assert_selector ".conversation-row", text: "Planner" }
    assert_no_selector "#group_workspace_#{@bob.personal_workspace.id} .conversation-row", text: "Planner"

    within("#group_workspace_#{@shared.id}") { click_on "Household" }
    assert_selector "h1", text: "Household"
    within("#memberships") { assert_text "Alice"; assert_text "operator@example.com" }
  end

  test "beside a thread the sidebar is grouped too, and a row in another workspace opens there" do
    share_with_bob
    visit conversation_path(@bob.personal_workspace.agents.sole.conversation)
    within(".chat-sidebar #group_workspace_#{@shared.id}") { click_on "Shared" }
    assert_current_path conversation_path(@shared_agent.conversation)
    assert_selector ".chat-sidebar #group_workspace_#{@shared.id} [aria-current=page]", text: "Shared"
    assert_selector ".chat-sidebar #group_workspace_#{@bob.personal_workspace.id} .conversation-row", text: bobs_agent.name
  end

  test "a link into another of his workspaces opens it there; one into a workspace he is not in is not found" do
    share_with_bob
    visit conversation_path(@shared_agent.conversation)
    assert_selector ".chat-sidebar .conversation-row [aria-current=page]", text: "Shared"
    assert_no_selector ".workspace-switcher"

    assert_not_found conversation_path(@alice.personal_workspace.agents.sole.conversation)
  end

  test "two people in one workspace: Alice makes it and invites Bob, Bob writes in its agent's thread, Alice sees it live, removes him, and Bob is back in his own" do
    using_session(:alice) do
      sign_in_via_ajent(subject: "sub-alice", email: "member@example.com", name: "Alice")
      visit root_path
      assert_selector ".agent-group", count: 1
      visit workspaces_path
      click_on "New workspace"
      fill_in "Name", with: "Household"
      click_on "Create workspace"
      assert_selector "h1", text: "Household"
      fill_in "Invite by email", with: "operator@example.com"
      click_on "Invite"
      assert_text "Added Test Operator."
      within("#memberships") { assert_text "operator@example.com" }
    end
    household = @alice.workspaces.shared.sole
    @shared_agent = household.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
    thread = @shared_agent.conversation.tap { it.update!(durable_id: "31", request_id: "r-31") }
    submit = stub_request(:post, "#{SIDECAR}/v1/conversations/31/submissions").to_return(status: 202, body: { id: 1 }.to_json)

    using_session(:alice) do
      visit root_path
      click_on "Shared"
      assert_selector ".chat-sidebar #group_workspace_#{household.id} [aria-current=page]", text: "Shared"
      wait_for_live_updates
    end

    visit root_path
    within("#group_workspace_#{household.id}") { click_on "Shared" }
    find("#composer textarea").fill_in(with: "Milk and eggs, please")
    find("#composer textarea").send_keys(:enter)
    assert_selector "#messages", text: "Milk and eggs, please"
    wait_until { WebMock::RequestRegistry.instance.times_executed(submit.request_pattern).positive? }
    assert_requested submit

    # The sidecar commits it, and the thread's stream carries it to everyone in the workspace.
    @entries = [ { id: "1", entryId: 1, role: "user", content: "Milk and eggs, please", author: { userId: @bob.id.to_s } } ]
    thread.sync!
    using_session(:alice) do
      assert_selector "#messages .ui-bubble", text: "Milk and eggs, please"
      # In a shared thread each person's words carry their name: they are not Alice's.
      assert_selector "#messages .message__author", text: @bob.name
      within(".chat-sidebar #group_workspace_#{household.id} .agent-group__title") { click_on "Household" }
      within("#memberships li", text: "operator@example.com") { click_on "Remove" }
      within("dialog#confirm[open]") { click_on "Remove" }
      within("#memberships") { assert_no_text "operator@example.com" }
    end

    assert_not_found conversation_path(thread)
    visit root_path
    assert_selector ".conversation-row", text: bobs_agent.name
    assert_no_selector ".conversation-row", text: "Shared"
    assert_selector ".agent-group", count: 1
    assert_no_selector "#group_workspace_#{household.id}"
  end

  test "a shared workspace's long name ends in an ellipsis on one line, its people and waiting counts on one line beside it, at 1280, 768 and 390" do
    share_with_bob
    @shared.update!(name: "The Riverside Community Garden Collective")
    asking = @alice.start_agent("Planner", workspace: @shared).conversation.tap { it.update!(durable_id: "41", request_id: "r-41") }
    asking.invocations.create!(task_id: "7", call_id: "toolu_long_name", tool_name: "ask_person",
      arguments: { "question" => "Which bed?" }, digest: "long-name", state: "awaiting_person", expires_at: 1.day.from_now)
    title = "#group_workspace_#{@shared.id} .agent-group__title"

    thread = conversation_path(bobs_agent.conversation)
    # Beside a thread on a desktop, in the side panel Agents opens on a tablet, and the phone's list.
    [ [ 1280, 900, thread, ".chat-sidebar " ], [ 768, 1024, thread, "dialog#agents_panel[open] " ], [ 390, 844, conversations_path, "" ] ].each do |width, height, path, within|
      page.current_window.resize_to(width, height)
      visit path
      click_on "Agents" if within.start_with?("dialog")
      name = "document.querySelector('#{within}#{title} .agent-group__name')"
      assert evaluate_script("#{name}.scrollWidth > #{name}.clientWidth"), "the name ends in an ellipsis at #{width}"
      # A wrapped line is a second box: each piece of the row, and the row itself, is drawn as one line.
      lines = evaluate_script(<<~JS)
        [...document.querySelectorAll("#{within}#{title} .agent-group__name, #{within}#{title} .agent-group__detail, #{within}#{title} .agent-group__waiting")].map(element => {
          const range = document.createRange(); range.selectNodeContents(element)
          return [element.textContent.trim(), new Set([...range.getClientRects()].map(rect => Math.round(rect.top))).size]
        })
      JS
      assert_equal lines.map { [ it.first, 1 ] }, lines, "each on one line at #{width}"
      tops = evaluate_script("[...document.querySelector('#{within}#{title}').children].filter(it => it.offsetParent).map(it => Math.round(it.getBoundingClientRect().top + it.getBoundingClientRect().height / 2))")
      assert_operator tops.max - tops.min, :<=, 2, "the name, counts and menu sit on one line at #{width}: #{tops}"
      # The counts are one piece, so they move as one and never part across lines.
      assert_selector "#{within}#{title} .agent-group__counts", text: "2 people 1 waiting", normalize_ws: true
    end
  ensure
    page.current_window.resize_to(1400, 1400)
  end

  private
    # The page a person is shown, not the developer's exception page the test server would show.
    def assert_not_found(path)
      env = Rails.application.env_config
      detailed, env["action_dispatch.show_detailed_exceptions"] = env["action_dispatch.show_detailed_exceptions"], false
      visit path
      assert_title(/404 Not found/)
    ensure
      env["action_dispatch.show_detailed_exceptions"] = detailed
    end

    def bobs_agent = @bob.personal_workspace.agents.order(:id).first

    def share_with_bob
      @shared = Workspace.create!(name: "Household")
      @shared.memberships.create!(user: @alice, role: "owner")
      @shared_agent = @shared.agents.create!(user: @alice, name: "Shared", instructions: "Help.", model: Agent.models.first)
      @shared.memberships.create!(user: @bob, role: "member")
    end
end
