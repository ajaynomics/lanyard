require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/query_count_helper"

# The list of agents, one row per agent's thread (ConversationsController#index),
# the sidebar beside a thread, and how archiving moves them between the two.
class ConversationListTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include QueryCountHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    # Each row here is an agent the test makes, not the starter.
    @user = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @user.agents.destroy_all
  end
  teardown { remove_sidecar_settings }

  test "the list takes its search, sort and filter from the address" do
    lisbon = conversation("Trip to Lisbon", last_message_at: 2.days.ago)
    conversation("Groceries")
    conversation("Lisbon again", archived_at: 1.day.ago)

    get conversations_path(q: "lisbon")
    assert_select ".conversation-row__name", count: 1, text: "Trip to Lisbon"
    assert_select "input[name=q][value=lisbon]"

    get conversations_path(q: "lisbon", filter: "all", sort: "title")
    assert_select ".conversation-row__link", count: 2
    assert_select ".conversation-row__name", text: "Lisbon again"
    assert_select "select[name=sort] option[selected][value=title]"
    assert_select "select[name=filter] option[selected][value=all]"
    assert_select ".conversation-row__badge", text: "Archived"
    assert_select "form[action=?] button", conversation_archive_path(lisbon), text: "Archive"

    get conversations_path(filter: "nonsense", sort: "nonsense")
    assert_response :success
    assert_select ".conversation-row__link", count: 2
  end

  test "thirty a page, and a lazy frame for the next page that keeps the address's search and filter" do
    31.times { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago) }

    get conversations_path(q: "talk", filter: "active")
    assert_select "#conversations_page_1 .conversation-row", count: 30
    assert_select "turbo-frame#conversations_page_2[loading=lazy][target=_top][src=?]",
      conversations_path(filter: "active", page: 2, q: "talk")
    assert_select "turbo-frame#conversations_page_2 .ui-skeleton[role=status]", 1, "a placeholder until the page loads"

    get conversations_path(q: "talk", filter: "active", page: 2)
    assert_select "turbo-frame#conversations_page_2 .conversation-row", count: 1
    assert_select ".conversation-row__name", text: "Talk 30"
    assert_select "turbo-frame#conversations_page_3", count: 0
  end

  test "each row shows its newest words, a person's or a reply's, without tool markers; a new agent says it has none" do
    trip = conversation("Trip")
    trip.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Book Lisbon")
    trip.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Booked the\n**Friday** flight.[tool: book]")
    trip.messages.create!(entry_key: "3", entry_id: 3, role: "toolResult", content: "ok", tool_call_id: "c")
    conversation("Fresh")

    get conversations_path
    assert_select ".conversation-row:has(#nav_title_conversation_#{trip.id}) .conversation-row__preview", "Booked the **Friday** flight."
    assert_select ".conversation-row__preview", "No messages yet"
  end

  test "an empty list says why" do
    get conversations_path
    assert_select ".ui-marker", text: "No agents yet. Make your first."
    assert_select ".ui-marker a[href=?]", new_agent_path
    get conversations_path(filter: "waiting")
    assert_select ".ui-marker", text: "Nothing is waiting for you."
    # Branches are no longer offered; an old link to the filter shows the active list.
    get conversations_path(filter: "branched")
    assert_select ".ui-marker", text: "No agents yet. Make your first."
    assert_select "option[value=branched]", count: 0
    get conversations_path(filter: "archived")
    assert_select ".ui-marker", text: "Nothing archived."
    get conversations_path(q: "zebra", filter: "all")
    assert_select ".ui-marker", text: /Nothing matches "zebra"\./
    assert_select ".ui-marker a[href=?]", conversations_path(filter: "all"), text: "Clear"
  end

  test "archive and unarchive go back to the page they came from" do
    talk = conversation("Talk")
    back = conversations_path(filter: "all", q: "ta")

    post conversation_archive_path(talk), headers: { "Referer" => "http://www.example.com#{back}" }
    assert_redirected_to back
    assert talk.reload.archived?

    delete conversation_archive_path(talk)
    assert_redirected_to conversation_path(talk)
    assert_not talk.reload.archived?
  end

  test "another person's agent cannot be archived or unarchived" do
    theirs = create_user(name: "Mallory").agents.sole
    other = theirs.conversation

    post conversation_archive_path(other)
    assert_response :not_found
    delete conversation_archive_path(other)
    assert_response :not_found
    assert_not other.reload.archived?
  end

  test "sending a message unarchives the conversation" do
    talk = conversation("Talk", archived_at: 1.day.ago)
    stub_request(:post, "#{SIDECAR}/v1/conversations/#{talk.durable_id}/submissions").to_return(status: 202, body: { id: 1 }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/#{talk.durable_id}/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)

    post conversation_submissions_path(talk), params: { content: "Back again", request_id: "m-1" }

    assert_not talk.reload.archived?
  end

  test "the sidebar lists active conversations, then loads the next thirty lazily" do
    archived = conversation("Put away", archived_at: 1.day.ago)
    talks = 30.times.map { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago) }
    current = talks.first
    stub_page_load(current)

    get conversation_path(current)

    assert_select ".chat-sidebar .conversation-row", count: 30
    assert_select ".chat-sidebar [aria-current=page] #nav_title_conversation_#{current.id}"
    assert_select ".chat-sidebar #nav_title_conversation_#{archived.id}", count: 0
    assert_select ".chat-sidebar turbo-frame#conversations_page_2[loading=lazy][src=?]",
      conversations_path(page: 2, filter: "active", sort: "recent")
    assert_select ".chat-sidebar turbo-frame#conversations_page_2 .ui-skeleton"
    assert_select "#chat_actions form[action=?] button", conversation_archive_path(current), text: "Archive agent"
    assert_select "#chat_actions a[href=?]", agent_path(current.agent), text: "#{current.agent} settings"
    assert_select ".chat-sidebar__account button", text: "Sign out"

    current.archive
    get conversation_path(current)
    assert_select "#chat_actions button", text: "Unarchive agent"
  end

  test "the list costs the same number of queries for two conversations as for twelve" do
    2.times { |index| conversation("Talk #{index}", status: "waiting", branches_count: 1) }
    get conversations_path(filter: "all")

    baseline = queries_in { get conversations_path(filter: "all") }
    10.times { |index| conversation("More #{index}", archived_at: 1.day.ago, branches_count: 2) }

    assert_same_queries(baseline) { get conversations_path(filter: "all") }
    assert_select ".conversation-row", count: 12
  end

  private
    # An agent named `name`, made like the starter, and its thread, admitted.
    def conversation(name, **attributes)
      @count = @count.to_i + 1
      @user.start_agent(name).conversation.tap { it.update_columns(durable_id: "d-#{@count}", **attributes) }
    end

    def stub_page_load(conversation)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "idle" }.to_json)
    end
end
