require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/caldav_test_helper"

class Tool::CalendarReadsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include CaldavTestHelper
  include ActiveJob::TestHelper

  # A fixture transaction would itself hold the lock this regression measures.
  self.use_transactional_tests = false

  setup do
    install_caldav
    @person = create_user(name: "Calendar-#{SecureRandom.hex(6)}")
    @agent = @person.agents.sole
    @agent.update!(caldav_username: "agent-1", caldav_password: "app-password")
    @conversation = create_conversation(@agent)
  end

  teardown do
    @person&.destroy!
    remove_caldav
  end

  test "calendar reads release the invocation write transaction before each HTTP request" do
    requests = []
    stub_request(:any, /\A#{Regexp.escape(CaldavTestHelper::URL)}/).to_return do |request|
      requests << request.method
      assert_not Invocation.connection.transaction_open?, "#{request.method} held the invocation's transaction"
      caldav_answer(request)
    end

    assert_equal "done", run_call("lists", "calendar_lists", {})[:status]
    assert_equal "done", run_call("find", "calendar_find", { "kind" => "events" })[:status]
    assert_includes requests, :propfind
    assert_includes requests, :report
    assert @conversation.invocations.all?(&:succeeded?)
  end

  test "an unrelated write completes while a calendar response is still held" do
    entered = Queue.new
    release = Queue.new
    held = false
    stub_request(:any, /\A#{Regexp.escape(CaldavTestHelper::URL)}/).to_return do |request|
      unless held
        held = true
        entered << true
        release.pop
      end
      caldav_answer(request)
    end

    reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { run_call("held", "calendar_lists", {}) }
    end
    Timeout.timeout(5) { entered.pop }
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { @person.reload.update!(name: "Edited while the calendar waits") }
    end

    assert writer.join(2), "a held calendar response blocked an unrelated database write"
    assert reader.alive?, "the calendar response should still be waiting"
    assert_equal "Edited while the calendar waits", @person.reload.name
  ensure
    release << true
    reader&.join(10)
    writer&.join(10)
    reader&.value
    writer&.value
  end

  private
    def run_call(call_id, tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id,
        tool: tool, arguments: arguments, digest: payload[:digest]).deep_symbolize_keys }
      receive.call
      perform_enqueued_jobs(only: InvocationCallJob)
      receive.call
    end
end
