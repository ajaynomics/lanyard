require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversation::TreeTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @root = create_conversation(@agent)
    @root.update!(title: "Plan a trip")
    @root.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where should I go?")
    @answer = @root.messages.create!(entry_key: "2", entry_id: 2, role: "assistant", content: "Lisbon.[tool: current_time]")
    @root.messages.create!(entry_key: "2:1", entry_id: 2, role: "toolResult", content: "noon")
  end
  teardown { remove_sidecar_settings }

  test "branch sets the family's root and counts the parent's branches" do
    first = branch(@root, "b-1", after: 2)
    second = branch(first, "b-2", after: 2)

    assert_equal [ @root.id, @root.id ], [ first.root_id, second.root_id ]
    assert_equal [ 1, 1 ], [ @root.reload.branches_count, first.reload.branches_count ]
    assert_equal [ @root, first, second ], @agent.conversations.family_of(second).order(:id).to_a
    # A fresh copy: the setup's messages rendered with @root's counts, memoised before any branch.
    assert_equal({ 2 => 1 }, @agent.conversations.find(@root.id).branch_counts)
  end

  test "nests branches under their parents, with fork points, message counts and a branch that started empty" do
    first = branch(@root, "b-1", after: 2)
    first.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where should I go?")
    nested = branch(first, "b-2", after: 1)
    empty = branch(@root, "b-3", after: nil)
    create_conversation(@agent, durable_id: "elsewhere")

    tree = first.tree

    assert_equal first, tree.current
    assert_equal [ @root ], tree.roots
    assert_equal [ first, empty ], tree.children(@root)
    assert_equal [ nested ], tree.children(first)
    assert_empty tree.children(nested)
    assert_equal @answer, tree.fork_point(first)
    assert_equal "Where should I go?", tree.fork_point(nested).content
    assert_nil tree.fork_point(empty)
    assert_nil tree.fork_point(@root)
    assert_equal [ 2, 1, 0 ], [ @root, first, empty ].map { tree.message_count(it) }
  end

  private
    def branch(parent, request_id, after:)
      path = after ? "#{parent.durable_id}/forks" : ""
      stub_request(:post, "#{SIDECAR}/v1/conversations#{"/#{path}" if after}").with(body: hash_including(requestId: request_id))
        .to_return(status: 201, body: { id: "d-#{request_id}" }.to_json)
      parent.branch(request_id: request_id, after: after)
    end
end
