require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"

class Tool::SendEmailTest < ActiveSupport::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    ActionMailer::Base.deliveries.clear
    install_email_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.update!(name: "Travel", email_name: "travel")
    @conversation = create_conversation(@agent)
  end

  teardown { remove_email_settings }

  test "an agent has it only where the install has email" do
    assert_includes @agent.definition[:tools].pluck(:name), "send_email"
    with_setting(:mail, :domain, nil) do
      assert_not_includes @agent.definition[:tools].pluck(:name), "send_email"
      assert_nil @agent.email_address
    end
  end

  test "mail to the install's own people goes at once, from the agent's address, in the thread it answers" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      outcome = run_call("c1", "to" => [ "alice@example.com" ], "subject" => "Re: Trip", "body" => "Booked.", "in_reply_to" => "abc@example.com")

      assert_equal [ "alice@example.com" ], outcome[:result][:sent]
    end
    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "travel@agents.example" ], mail.from
    assert_equal "Travel <travel@agents.example>", mail[:from].to_s
    assert_equal "Re: Trip", mail.subject
    assert_equal "abc@example.com", mail.in_reply_to
    assert_equal "abc@example.com", mail.references
    assert_equal "Booked.", mail.body.to_s
  end

  test "mail to anyone else waits for the person, and goes only once they allow it" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      arguments = { "to" => [ "alice@example.com", "hotel@example.net" ], "subject" => "Booking", "body" => "Two nights." }
      assert_equal "waiting", receive("send_email", arguments, call_id: "c1")[:status]
      assert_empty ActionMailer::Base.deliveries

      @conversation.invocations.find_by!(call_id: "c1").approve!(by: @alice)
      run_call("c1", arguments)
      assert_equal [ "alice@example.com", "hotel@example.net" ], ActionMailer::Base.deliveries.sole.to
    end
  end

  private
    def receive(tool, arguments, call_id:)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    # An outside call runs from a job once claimed; the replay then reads its result.
    def run_call(call_id, arguments)
      receive("send_email", arguments, call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      receive("send_email", arguments, call_id: call_id)
    end
end
