require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Workspaces › Overview (/workspaces/overview): for each workspace the person
# is in, their own first, its agents, the cards waiting and what went wrong
# lately, each a link to the page that deals with it. Read from what is stored:
# nothing outside is asked. Bob is in his own workspace and Acorn; Cedar is
# Carol's alone.
class WorkspacesOverviewTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    travel_to Time.utc(2026, 11, 17, 12)
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @acorn.memberships.create!(user: @bob, role: "member")
    @cedar = Workspace.create!(name: "Cedar")
    @cedar.memberships.create!(user: @carol, role: "owner")
    @ada = @alice.start_agent("Ada", workspace: @acorn)
    @cy = @carol.start_agent("Cy", workspace: @cedar)
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
  end
  teardown { remove_sidecar_settings }

  test "each of his workspaces, his own first, with its agents, waiting cards and recent errors, each a link" do
    @ada.update!(paused_at: 5.minutes.ago)
    @ada.conversation.update!(execution_status: "error", failure: "The model refused the request.")
    card = waiting(@ada, "Which day suits?", at: 10.minutes.ago)
    failed = @ada.conversation.invocations.create!(task_id: "7", call_id: "toolu_f", tool_name: "send_email", arguments: {}, digest: "f",
      state: "failed", error: "The mail server said no.")
    @ada.conversation.invocations.create!(task_id: "7", call_id: "toolu_old", tool_name: "send_email", arguments: {}, digest: "o",
      state: "failed", error: "An old failure.", created_at: 2.days.ago, updated_at: 2.days.ago)

    get workspaces_overview_path
    assert_response :success

    assert_equal [ "Bob · Yours", "Acorn · 2 people" ], css_select(".workspace-health h2").map { it.text.squish }
    assert_select "#workspace_health_#{@acorn.id}" do
      assert_select "a[href=?]", workspace_path(@acorn), text: "Acorn"
      assert_select "a[href=?]", conversation_path(@ada.conversation), text: /Ada.*Paused.*In error/m
      assert_select "a[href=?]", approval_path(card), text: /Which day suits\?.*Ada.*10 minutes/m
      assert_select "a[href=?]", conversation_path(@ada.conversation), text: /The model refused the request\./
      assert_select "a[href=?]", conversation_path(failed.conversation), text: /Send email failed.*Ada.*The mail server said no\..*Error/m
      assert_no_match "An old failure.", response.body, "a call that failed more than a day ago is no longer news"
    end
    assert_select "#workspace_health_#{@bob.personal_workspace.id}" do
      assert_select "a[href=?]", conversation_path(@bob.agents.find_by!(workspace: @bob.personal_workspace).conversation), text: /Bob's assistant.*Idle/m
      assert_select "section[aria-label^='Waiting']", text: /Nothing is waiting/
      assert_select "section[aria-label^='Errors']", text: /None in the last 24 hours/
    end
    assert_select ".workspace-overview form, .workspace-overview button, .workspace-overview input", count: 0, message: "a page of links: every action stays on its own page"
  end

  test "every section shows in each block, agents first, and each agent stands as its stored run says, never asking the sidecar" do
    stub_request(:any, /.*/)
    @alice.start_agent("Bea", workspace: @acorn).conversation.update!(execution_status: "running")
    @alice.start_agent("Cal", workspace: @acorn).conversation.update!(execution_status: "unknown")

    get workspaces_overview_path

    css_select(".workspace-health").each do |block|
      assert_equal [ "Agents", "Waiting for you", "Recent errors", "Held rooms" ], block.css("h3").map { it.text.squish }
    end
    assert_select "#workspace_health_#{@acorn.id} section[aria-label^='Agents'] .ui-row" do |rows|
      assert_equal [ "Ada Idle", "Bea Working", "Cal Unknown" ], rows.map { it.text.squish }
    end
    assert_select "#workspace_health_#{@acorn.id} section[aria-label^='Agents'] .ui-avatar", count: 3
    assert_not_requested :any, /.*/
  end

  test "a card waiting more than an hour is stuck; one waiting less is not" do
    stuck = waiting(@ada, "Book the table?", at: 61.minutes.ago)
    fresh = waiting(@ada, "Send the note?", at: 59.minutes.ago)

    get workspaces_overview_path

    assert_select "a[href=?]", approval_path(stuck), text: /Stuck/
    assert_select "a[href=?]", approval_path(fresh) do |link|
      assert_no_match "Stuck", link.text
    end
    assert_select "a[href=?]", approval_path(fresh), text: /Waiting/
    assert_select "#workspace_health_#{@acorn.id} h3", text: "Waiting for you · 2"
    assert_select "#workspace_health_#{@acorn.id} p", text: "Stuck: waiting over an hour, or expiring within the hour."
  end

  test "a card expiring within the hour is stuck however new; one expiring later is not" do
    expiring = waiting(@ada, "Pay the deposit?", at: 5.minutes.ago, expires_at: 30.minutes.from_now)
    later = waiting(@ada, "Order the cake?", at: 5.minutes.ago, expires_at: 2.hours.from_now)

    get workspaces_overview_path

    assert_select "a[href=?]", approval_path(expiring), text: /Stuck/
    assert_select "a[href=?]", approval_path(later) do |link|
      assert_no_match "Stuck", link.text
    end
  end

  test "a held Campfire room shows in its own workspace, with why, since when and where to resume it; none elsewhere" do
    @ada.create_campfire_bot!(bot_key: "1-ada", rooms: { "7" => "Launch planning" })
    @acorn.campfire_rooms.create!(room_id: 7, held_at: 25.minutes.ago)
    @acorn.campfire_rooms.create!(room_id: 8)

    get workspaces_overview_path

    assert_select "#workspace_health_#{@acorn.id}" do
      assert_select "a[href=?]", workspace_path(@acorn, anchor: "campfire"), count: 1,
        text: /Launch planning.*10 messages in a minute.*25 minutes ago.*Held/m
    end
    assert_select "#workspace_health_#{@bob.personal_workspace.id} section[aria-label^='Held rooms']", text: /None/
  end

  test "a held room its bots never named shows by its number" do
    @acorn.campfire_rooms.create!(room_id: 42, held_at: 3.minutes.ago)

    get workspaces_overview_path

    assert_select "#workspace_health_#{@acorn.id} a[href=?]", workspace_path(@acorn, anchor: "campfire"), text: /Room 42/
  end

  test "nothing of a workspace he is not in: not its agents, cards or errors" do
    @cy.conversation.update!(execution_status: "error", failure: "Cedar's failure.")
    cedar_card = waiting(@cy, "Cedar's question?", at: 2.hours.ago)
    @cy.conversation.invocations.create!(task_id: "7", call_id: "toolu_c", tool_name: "send_email", arguments: {}, digest: "c",
      state: "failed", error: "Cedar's failed call.")

    get workspaces_overview_path

    assert_response :success
    [ "Cedar", "Cy", "Cedar's question?", "Cedar's failure.", "Cedar's failed call." ].each { assert_no_match it, response.body }
    assert_select "a[href=?]", approval_path(cedar_card), count: 0
    assert_select "a[href=?]", conversation_path(@cy.conversation), count: 0
  end

  test "it asks nothing outside: no sidecar, no Campfire, no connector" do
    stub_request(:any, /.*/)
    @acorn.update!(campfire_url: "https://chat.example.com")
    @ada.create_campfire_bot!(bot_key: "1-ada", rooms: { "7" => "Launch planning" })
    @acorn.campfire_rooms.create!(room_id: 7, held_at: 10.minutes.ago)
    waiting(@ada, "Which day suits?", at: 2.hours.ago)

    get workspaces_overview_path

    assert_response :success
    assert_select "#workspace_health_#{@acorn.id}", text: /Launch planning/
    assert_not_requested :any, /.*/
  end

  test "Settings' Workspaces and the agents list link to it" do
    get workspaces_path
    assert_select "a[href=?]", workspaces_overview_path, text: /Overview/

    get root_path
    assert_select ".agent-groups__more a[href=?]", workspaces_overview_path, text: "Overview"
  end

  private
    def waiting(agent, question, at:, expires_at: 1.day.from_now)
      agent.conversation.invocations.create!(task_id: "7", call_id: "toolu_#{question.hash.abs}", tool_name: "ask_person",
        arguments: { "question" => question }, digest: question, state: "awaiting_person", expires_at:, created_at: at)
    end
end
