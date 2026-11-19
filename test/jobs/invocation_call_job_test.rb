require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# Against a real Solid Queue database: a call whose job never began is
# queued again only when Solid Queue no longer holds a job that may run it
# (Invocation#wait_for_job, #238).
class InvocationCallJobTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  # Built before the test's transaction opens, so its tables are committed;
  # what each test writes to it is rolled back with the rest.
  def before_setup
    @path = Rails.root.join("tmp/invocation-call-job-test-#{Process.pid}.sqlite3").to_s
    queue = ActiveRecord::DatabaseConfigurations::HashConfig.new("test", "queue", adapter: "sqlite3", database: @path)
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(queue) { load Rails.root.join("db/queue_schema.rb") }
    end
    SolidQueue::Record.establish_connection(queue)
    super
  end

  def after_teardown
    super
    SolidQueue::Record.remove_connection
    FileUtils.rm_f(Dir["#{@path}*"])
  end

  setup do
    @adapter, InvocationCallJob.queue_adapter = InvocationCallJob.queue_adapter, :solid_queue
    @alice = create_user(name: "Alice")
    @conversation = create_conversation(@alice.agents.sole)
    create_mcp_server(@alice.agents.sole, tools: [ mcp_tool("search", annotations: { readOnlyHint: true }) ])
  end

  teardown { InvocationCallJob.queue_adapter = @adapter }

  test "its job is queued on the calls queue, and is held until it finishes or fails" do
    receive("toolu_1")
    invocation = @conversation.invocations.sole
    job = SolidQueue::Job.sole
    assert_equal "calls", job.queue_name
    assert InvocationCallJob.queued?(invocation)

    job.update!(finished_at: Time.current)
    assert_not InvocationCallJob.queued?(invocation), "finished"
    job.update!(finished_at: nil)
    SolidQueue::FailedExecution.create!(job: job, error: { exception_class: "SolidQueue::Processes::ProcessPrunedError", message: "x", backtrace: [] })
    assert_not InvocationCallJob.queued?(invocation), "failed, as when its worker died"
  end

  test "another call's job is not this one's" do
    receive("toolu_1")
    first = @conversation.invocations.sole
    SolidQueue::Job.delete_all
    receive("toolu_2")
    assert_not InvocationCallJob.queued?(first)
  end

  test "a call whose job is gone before it began is queued again, once while that one waits" do
    receive("toolu_1")
    invocation = @conversation.invocations.sole
    SolidQueue::Job.delete_all # lost on the way, before it began

    travel(Invocation::RUN_LIMIT - 1.minute) { receive("toolu_1") }
    assert_equal 0, SolidQueue::Job.count, "too soon to look"
    travel Invocation::RUN_LIMIT + 1.minute do
      assert_equal "waiting", receive("toolu_1")[:status]
      assert_equal 1, SolidQueue::Job.count
      receive("toolu_1")
      assert_equal 1, SolidQueue::Job.count, "not again while that one waits"
    end
    assert invocation.reload.running?
    assert_nil invocation.started_at
  end

  private
    def receive(call_id)
      payload = invocation_payload(@conversation, tool: "mcp__wiki__search", arguments: {}, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "mcp__wiki__search",
        arguments: {}, digest: payload[:digest]).deep_symbolize_keys
    end
end
