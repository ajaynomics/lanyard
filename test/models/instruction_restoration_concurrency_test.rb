require "test_helper"
require "timeout"
require_relative "../test_helpers/agent_test_helper"

class InstructionRestorationConcurrencyTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  setup do
    @owner = User.create!(oidc_sub: "instruction-restore-race", email: "restore-race@example.com", name: "Sage")
    @workspace = Workspace.make(name: "Studio", owner: @owner)
    @agent = @owner.start_agent("Editor", workspace: @workspace)
    @conversation = create_conversation(@agent)
  end

  teardown do
    @agent&.destroy!
    @workspace&.destroy!
    @owner&.destroy!
  end

  test "two competing reviews and a concurrent replay append one revision in either scope" do
    [ @agent, @workspace ].each do |target|
      write(target, "Write short replies.")
      first = approve_edit(target, find: "short", replace: "plain")
      second = approve_edit(target, find: "plain", replace: "brief")
      write(target, "Write direct replies.")
      a, b = [ first, second ].map { |revision| restoration(target).preview(revision.id).token }
      previous = target.revisions.reorder(:id).pluck(:id, :instructions)

      results = race([ [ first.id, a ], [ second.id, b ], [ first.id, a ] ].map do |id, token|
        -> { restore(target, id, token) }
      end)

      assert_equal [ :restored, :stale, :stale ], results.sort
      history = target.revisions.reorder(:id).to_a
      assert_equal previous, history[0...-1].map { [ it.id, it.instructions ] }
      assert_equal @owner, history.last.restored_by
      assert_includes [ first.id, second.id ], history.last.restored_from_id
      assert_equal history.last.instructions, target.reload.instructions
    end
  end

  test "a failure to write the revision also leaves both scopes' current instructions intact" do
    [ @agent, @workspace ].each do |target|
      write(target, "Write short replies.")
      source = approve_edit(target, find: "short", replace: "plain")
      write(target, "Write direct replies.")
      review = restoration(target).preview(source.id).token
      table = target.revisions.klass.table_name
      target.class.with_connection do |db|
        db.execute("CREATE TEMP TRIGGER fail_restored_revision BEFORE INSERT ON #{table} WHEN NEW.restored_from_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'revision write failed'); END")
        assert_no_difference -> { target.revisions.count } do
          assert_raises(ActiveRecord::StatementInvalid) { restore(target, source.id, review) }
        end
      ensure
        db.execute("DROP TRIGGER IF EXISTS fail_restored_revision")
      end
      assert_equal "Write direct replies.", target.reload.instructions
      assert_equal :restored, restore(target, source.id, review)
    end
  end

  private
    def restoration(target)
      InstructionRestoration.new(target: target, workspace: @workspace, by: @owner)
    end

    def restore(target, revision_id, token)
      fresh_target = target == @workspace ? @owner.owned_workspaces.find(target.id) : @workspace.agents.find(target.id)
      restoration(fresh_target).restore!(revision_id, token: token)
      :restored
    rescue InstructionRestoration::Stale
      :stale
    end

    def write(target, text)
      target == @workspace ? target.change_instructions(text, by: @owner) : target.update!(instructions: text)
    end

    def approve_edit(target, find:, replace:)
      args = { "edits" => [ { "find" => find, "replace" => replace } ] }
      args["scope"] = "workspace" if target == @workspace
      call_id = "race-#{target.class.name}-#{find}"
      payload = invocation_payload(@conversation, tool: "change_yourself", arguments: args, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "change_yourself", arguments: args, digest: payload[:digest]) }
      assert_equal "waiting", receive.call[:status]
      @conversation.invocations.find_by!(call_id: call_id).approve!(by: @owner)
      assert_equal({ "instructions" => "saved" }, receive.call[:result])
      target.reload.revisions.reorder(id: :desc).first!
    end

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
end
