require "test_helper"
require "timeout"
require_relative "../../test_helpers/agent_test_helper"

class Tool::ChangeYourselfConcurrencyTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  test "competing approved changes and a concurrent replay commit just one change and one revision" do
    owner = User.create!(oidc_sub: "instruction-edit-race", email: "race@example.com", name: "Sage")
    workspace = owner.personal_workspace
    agent = owner.start_agent("Editor", workspace: workspace)
    agent.update!(instructions: "Write short replies.")
    conversation = create_conversation(agent)
    before = agent.revisions.count
    payloads = [ "brief", "direct" ].each_with_index.map do |word, index|
      invocation_payload(conversation, tool: "change_yourself", arguments: { "instructions" => "Write #{word} replies." }, call_id: "script/c#{index + 1}")
    end
    payloads.each do |payload|
      assert_equal "waiting", receive(conversation, payload)[:status]
      conversation.invocations.find_by!(call_id: payload[:callId]).approve!(by: owner)
    end

    first, second, replay = race([ payloads.first, payloads.last, payloads.first ].map do |payload|
      -> { receive(owner.conversations.find(conversation.id), payload) }
    end)

    assert_equal first, replay
    assert_equal [ false, true ], [ first, second ].map { |result| result[:isError] }.sort_by(&:to_s)
    assert_equal [ "failed", "succeeded" ], conversation.invocations.order(:state).pluck(:state)
    assert_equal before + 1, agent.revisions.count
    assert_equal first[:isError] ? "Write direct replies." : "Write brief replies.", agent.reload.instructions
  ensure
    workspace&.agents&.destroy_all
    workspace&.destroy!
    owner&.destroy!
  end

  test "a workspace change racing a real move may commit only in the approved workspace" do
    owner = User.create!(oidc_sub: "instruction-move-race", email: "move@example.com", name: "Sage")
    source = Workspace.make(name: "Source", owner: owner)
    destination = owner.personal_workspace
    base = "Write short replies."
    [ source, destination ].each { it.change_instructions(base, by: owner) }
    agent = owner.start_agent("Editor", workspace: source)
    conversation = create_conversation(agent)
    args = { "scope" => "workspace", "instructions" => "Write direct replies." }
    payload = invocation_payload(conversation, tool: "change_yourself", arguments: args, call_id: "script/c1")
    assert_equal "waiting", receive(conversation, payload)[:status]
    conversation.invocations.sole.approve!(by: owner)

    moved, result = race([
      -> { owner.agents.find(agent.id).move_to(destination, by: owner) },
      -> { receive(owner.conversations.find(conversation.id), payload) }
    ])

    assert moved
    assert_equal destination.id, agent.reload.workspace_id
    assert_equal [ base ], destination.revisions.pluck(:instructions)
    assert_equal base, destination.reload.instructions
    expected_history = result[:isError] ? [ base ] : [ "Write direct replies.", base ]
    assert_equal expected_history, source.revisions.pluck(:instructions)
    assert_equal expected_history.first, source.reload.instructions
    assert_equal result, receive(conversation.reload, payload)
  ensure
    agent&.destroy!
    destination&.destroy!
    source&.destroy!
    owner&.destroy!
  end

  private
    def race(operations)
      ready, start = Queue.new, Queue.new
      threads = operations.map do |operation|
        Thread.new do
          ApplicationRecord.with_connection do
            ready << true
            start.pop
            operation.call
          end
        end
      end
      Timeout.timeout(10) { threads.size.times { ready.pop } }
      threads.size.times { start << true }
      Timeout.timeout(10) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.join(2) || thread.kill }
    end

    def receive(conversation, payload)
      Invocation.receive(conversation, task_id: payload[:taskId], call_id: payload[:callId], tool: payload[:tool],
        arguments: payload[:arguments], digest: payload[:digest]).deep_symbolize_keys
    end
end
