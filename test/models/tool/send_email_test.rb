require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/email_test_helper"

class Tool::SendEmailTest < ActiveSupport::TestCase
  # A mail server that refuses every message, as a busy one does.
  class BusyServer
    cattr_accessor :attempts, default: 0
    def initialize(*) = nil
    def deliver!(*) = (self.class.attempts += 1) && raise(Net::SMTPServerBusy, "421 try later")
  end

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
    assert_includes @agent.conversation.definition[:tools].pluck(:name), "send_email"
    with_setting(:mail, :domain, nil) do
      assert_not_includes @agent.reload.conversation.definition[:tools].pluck(:name), "send_email"
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

  test "a mail server's error fails the call once, and nothing is sent again" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      arguments = { "to" => [ "alice@example.com" ], "subject" => "Trip", "body" => "Booked." }
      ActionMailer::Base.add_delivery_method :busy, BusyServer
      AgentMailer.delivery_method = :busy
      outcome = run_call("c1", arguments)

      assert_equal "failed", @conversation.invocations.find_by!(call_id: "c1").state
      assert_match(/send_email failed \(Net::SMTPServerBusy\)/, outcome[:result][:error])
      assert outcome[:isError]
      travel Invocation::RUN_LIMIT + 1.minute do
        assert_equal outcome, run_call("c1", arguments)
      end
      assert_equal 1, BusyServer.attempts
    end
  ensure
    AgentMailer.delivery_method = :test
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
