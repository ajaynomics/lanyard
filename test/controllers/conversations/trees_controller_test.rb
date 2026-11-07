require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/query_count_helper"

class Conversations::TreesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include QueryCountHelper

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
    @root = create_conversation(@agent)
    @root.update!(title: "Plan a trip")
    @root.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where should I go?")
    @answer = @root.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Lisbon, for the light.")
  end
  teardown { remove_sidecar_settings }

  test "the tree nests each branch under its parent, says where it was taken and marks the current one" do
    first = branch(@root, after: 2, title: "Lisbon (branch)")
    empty = branch(@root, after: nil, title: "Fresh start", archived_at: 1.day.ago)

    get conversation_tree_path(first)

    assert_select ".tree > .tree__node > .tree__title[href=?]", conversation_path(@root), text: "Plan a trip"
    assert_select ".tree__children .tree__title[aria-current=page][href=?]", conversation_path(first)
    assert_select ".tree__children .tree__node", text: /after: Lisbon, for the light\./ do
      assert_select "a[href=?]", conversation_path(@root, anchor: "message_#{@answer.id}")
    end
    assert_select ".tree__children .tree__node", text: /Fresh start\s+From the start/
    assert_select ".tree__children .conversation-row__badge", text: "Archived"
    assert_select ".tree > .tree__node > .tree__meta", text: /2 messages/
  end

  test "another person's tree is not found" do
    theirs = create_user(name: "Mallory").agents.sole
    other = theirs.conversations.create!(user: theirs.user, request_id: "m", durable_id: "m")

    get conversation_tree_path(other)

    assert_response :not_found
  end

  test "the tree costs the same number of queries for two conversations as for eight" do
    branch(@root, after: 2)
    get conversation_tree_path(@root)

    baseline = queries_in { get conversation_tree_path(@root) }
    3.times { branch(branch(@root, after: 2), after: nil) }

    assert_same_queries(baseline) { get conversation_tree_path(@root) }
    assert_select ".tree__node", count: 8
  end

  test "a transcript marks where branches were taken, and costs the same queries for two messages as for twelve" do
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({})).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({})).to_return(body: { status: "idle" }.to_json)
    [ 2, 2, nil ].each { branch(@root, after: it) }
    @root.messages.each { picture(it) }
    get conversation_path(@root)

    baseline = queries_in { get conversation_path(@root) }
    assert_select "#message_#{@answer.id} a.message__branches[href=?]", conversation_tree_path(@root), text: "2 branches from here"
    (3..12).each { |entry| picture(@root.messages.create!(entry_key: entry.to_s, entry_id: entry, role: entry.odd? ? "user" : "assistant", content: "Message #{entry}")) }

    assert_same_queries(baseline) { get conversation_path(@root) }
    # A person's pictures show; a reply's are a tool's, shown with its result.
    assert_select ".ui-images__image", count: 6
  end

  private
    def branch(parent, after:, **attributes)
      @count = @count.to_i + 1
      @agent.conversations.create!(user: @agent.user, request_id: "b-#{@count}", durable_id: "b-#{@count}", parent: parent,
        root: parent.root || parent, forked_at_entry_id: after, **attributes)
    end

    def picture(message)
      message.images.attach(io: StringIO.new("not really a png"), filename: "picture.png", content_type: "image/png")
    end
end
