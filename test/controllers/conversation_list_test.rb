require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/query_count_helper"

# The conversation list (ConversationsController#index), the sidebar beside a
# conversation, and how archiving moves conversations between them.
class ConversationListTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include QueryCountHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_sidecar_settings }

  test "the list takes its search, sort and filter from the address" do
    lisbon = conversation("Trip to Lisbon", last_message_at: 2.days.ago)
    conversation("Groceries")
    conversation("Lisbon again", archived_at: 1.day.ago)

    get bot_conversations_path(@bot, q: "lisbon")
    assert_select ".conversation-row__link", count: 1, text: "Trip to Lisbon"
    assert_select "input[name=q][value=lisbon]"

    get bot_conversations_path(@bot, q: "lisbon", filter: "all", sort: "title")
    assert_select ".conversation-row__link", count: 2
    assert_select ".conversation-row__link", text: "Lisbon again"
    assert_select "select[name=sort] option[selected][value=title]"
    assert_select "select[name=filter] option[selected][value=all]"
    assert_select ".conversation-row__badge", text: "Archived"
    assert_select "form[action=?] button", conversation_archive_path(lisbon), text: "Archive"

    get bot_conversations_path(@bot, filter: "nonsense", sort: "nonsense")
    assert_response :success
    assert_select ".conversation-row__link", count: 2
  end

  test "thirty a page, and a lazy frame for the next page that keeps the address's search and filter" do
    31.times { |index| conversation("Talk #{index}", last_message_at: index.minutes.ago) }

    get bot_conversations_path(@bot, q: "talk", filter: "active")
    assert_select "#conversations_page_1 .conversation-row", count: 30
    assert_select "turbo-frame#conversations_page_2[loading=lazy][target=_top][src=?]",
      bot_conversations_path(@bot, filter: "active", page: 2, q: "talk")

    get bot_conversations_path(@bot, q: "talk", filter: "active", page: 2)
    assert_select "turbo-frame#conversations_page_2 .conversation-row", count: 1
    assert_select ".conversation-row__link", text: "Talk 30"
    assert_select "turbo-frame#conversations_page_3", count: 0
  end

  test "an empty list says why" do
    get bot_conversations_path(@bot)
    assert_select ".ui-marker", text: "No agents yet."
    get bot_conversations_path(@bot, filter: "waiting")
    assert_select ".ui-marker", text: "Nothing is waiting for you."
    get bot_conversations_path(@bot, filter: "branched")
    assert_select ".ui-marker", text: "No branches yet. Branch from any reply."
    get bot_conversations_path(@bot, filter: "archived")
    assert_select ".ui-marker", text: "Nothing archived."
    get bot_conversations_path(@bot, q: "zebra", filter: "all")
    assert_select ".ui-marker", text: /Nothing matches "zebra"\./
    assert_select ".ui-marker a[href=?]", bot_conversations_path(@bot, filter: "all"), text: "Clear"
  end

  test "archive and unarchive go back to the page they came from" do
    talk = conversation("Talk")
    back = bot_conversations_path(@bot, filter: "all", q: "ta")

    post conversation_archive_path(talk), headers: { "Referer" => "http://www.example.com#{back}" }
    assert_redirected_to back
    assert talk.reload.archived?

    delete conversation_archive_path(talk)
    assert_redirected_to conversation_path(talk)
    assert_not talk.reload.archived?
  end

  test "another person's conversation cannot be archived or unarchived" do
    theirs = create_user(name: "Mallory").bots.sole
    other = theirs.conversations.create!(user: theirs.user, request_id: "m", durable_id: "m")

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
    assert_select ".chat-sidebar #nav_title_conversation_#{current.id}[aria-current=page]"
    assert_select ".chat-sidebar #nav_title_conversation_#{archived.id}", count: 0
    assert_select ".chat-sidebar turbo-frame#conversations_page_2[loading=lazy][src=?]",
      bot_conversations_path(@bot, page: 2, filter: "active", sort: "recent")
    assert_select ".chat-sidebar form[action=?] button", conversation_archive_path(current), text: "Archive agent"

    current.archive
    get conversation_path(current)
    assert_select ".chat-sidebar button", text: "Unarchive agent"
  end

  test "the list costs the same number of queries for two conversations as for twelve" do
    2.times { |index| conversation("Talk #{index}", status: "waiting", branches_count: 1) }
    get bot_conversations_path(@bot, filter: "all")

    baseline = queries_in { get bot_conversations_path(@bot, filter: "all") }
    10.times { |index| conversation("More #{index}", archived_at: 1.day.ago, branches_count: 2) }

    assert_same_queries(baseline) { get bot_conversations_path(@bot, filter: "all") }
    assert_select ".conversation-row", count: 12
  end

  private
    def conversation(title, **attributes)
      @count = @count.to_i + 1
      @bot.conversations.create!(user: @bot.user, request_id: "r-#{@count}", durable_id: "d-#{@count}", title: title, **attributes)
    end

    def stub_page_load(conversation)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}/entries").with(query: hash_including({}))
        .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
      stub_request(:get, "#{SIDECAR}/v1/conversations/#{conversation.durable_id}").with(query: hash_including({}))
        .to_return(body: { status: "idle" }.to_json)
    end
end
