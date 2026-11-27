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
    Agent.where(id: @agent.id).update_all(name: "Travel", email_name: "travel")
    @agent.reload
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
    assert_equal "Booked.", mail.text_part.decoded
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

  test "an outside address in Cc or Bcc alone makes it wait for the person, and the card shows every recipient" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      %w[ cc bcc ].each do |field|
        arguments = { "to" => [ "alice@example.com" ], field => [ "lee@example.net" ], "subject" => "Chase", "body" => "Any news?" }
        assert_equal "waiting", receive("send_email", arguments, call_id: "w-#{field}")[:status], field
        invocation = @conversation.invocations.find_by!(call_id: "w-#{field}")
        assert_equal [ "alice@example.com", "lee@example.net" ], invocation.recipients
        assert_equal [ "alice@example.com" ], invocation.details["to"]
        assert_equal [ "lee@example.net" ], invocation.details[field]
        assert_includes Invocation::Card.new(invocation).as_json.to_json, "lee@example.net"
      end
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "allowed, To, Cc and Bcc go as the card showed them" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      arguments = { "to" => [ "pat@example.net" ], "cc" => [ "lee@example.net" ], "bcc" => [ "alice@example.com" ],
                    "subject" => "Chase", "body" => "Any news?" }
      assert_equal "waiting", receive("send_email", arguments, call_id: "c1")[:status]
      @conversation.invocations.find_by!(call_id: "c1").approve!(by: @alice)
      outcome = run_call("c1", arguments)

      assert_equal [ "pat@example.net" ], outcome[:result][:sent]
      mail = ActionMailer::Base.deliveries.sole
      assert_equal [ "pat@example.net" ], mail.to
      assert_equal [ "lee@example.net" ], mail.cc
      assert_equal [ "alice@example.com" ], mail.bcc
    end
  end

  test "an Always for one recipient doesn't cover another added in Cc or Bcc" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      @agent.permissions.create!(tool_name: "send_email", recipient: "pat@example.net", granted_by: @alice)
      alone = { "to" => [ "pat@example.net" ], "subject" => "Chase", "body" => "Any news?" }
      assert_equal "done", run_call("c1", alone)[:status]
      %w[ cc bcc ].each do |field|
        more = alone.merge(field => [ "lee@example.net" ], "subject" => "Chase, #{field}")
        assert_equal "waiting", receive("send_email", more, call_id: "c-#{field}")[:status], field
      end
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end

  test "Cc and Bcc are checked as To is: plain addresses, ten at most" do
    with_setting(:access, :emails, [ "alice@example.com" ]) do
      [ { "cc" => [ "Lee <lee@example.net>" ] }, { "bcc" => Array.new(11) { "p#{it}@example.com" } } ].each_with_index do |extra, index|
        outcome = run_call("bad#{index}", { "to" => [ "alice@example.com" ], "subject" => "Chase", "body" => "Any news?" }.merge(extra))
        assert outcome[:isError], extra.inspect
      end
      assert_empty ActionMailer::Base.deliveries
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

  test "a reply to a client sent as a new email is refused, naming the mail to answer" do
    received_mail("li-1@example.test", subject: "2600675 - 102 Pearl St")
    with_setting(:access, :emails, [ "li@example.test" ]) do
      [ "Re: 2600675 - 102 Pearl St", "RE: Fwd:  2600675 - 102 pearl st " ].each_with_index do |subject, index|
        outcome = run_call("new-#{index}", "to" => [ "li@example.test" ], "subject" => subject, "body" => "Done.")
        assert outcome[:isError], subject
        assert_match(/in_reply_to li-1@example\.test.*new_thread: true/m, outcome[:result][:error])
      end
    end
    outcome = run_call("outside", "to" => [ "pat@example.net" ], "cc" => [ "Li@example.test" ], "subject" => "Re: 2600675 - 102 Pearl St", "body" => "Done.")
    assert outcome[:isError], "refused before the person is asked"
    assert_empty ActionMailer::Base.deliveries
    assert_equal 0, HeldEmail.count
  end

  test "a follow-up to mail it sent is refused too, naming what it sent" do
    with_setting(:access, :emails, [ "li@example.test" ]) do
      sent = run_call("first", "to" => [ "li@example.test" ], "subject" => "Quote", "body" => "Attached.")[:result][:messageId]
      outcome = run_call("again", "to" => [ "li@example.test" ], "subject" => "Re: Quote", "body" => "Any news?")
      assert_match "in_reply_to #{sent}", outcome[:result][:error]
    end
  end

  test "with in_reply_to, or new_thread, it goes" do
    received_mail("li-1@example.test", subject: "2600675 - 102 Pearl St")
    with_setting(:access, :emails, [ "li@example.test" ]) do
      reply = { "to" => [ "li@example.test" ], "subject" => "Re: 2600675 - 102 Pearl St", "body" => "Done." }
      assert_equal "done", run_call("reply", reply.merge("in_reply_to" => "li-1@example.test"))[:status]
      assert_equal "done", run_call("fresh", reply.merge("new_thread" => true))[:status]
    end
    assert_equal 2, ActionMailer::Base.deliveries.size
  end

  test "mail over 30 days old, or with no one in common, doesn't hold it up" do
    received_mail("old@example.test", subject: "2600675 - 102 Pearl St", at: 31.days.ago)
    received_mail("other@example.test", subject: "2600675 - 102 Pearl St", from: "Sam <sam@example.test>")
    with_setting(:access, :emails, [ "li@example.test" ]) do
      outcome = run_call("c1", "to" => [ "li@example.test" ], "subject" => "Re: 2600675 - 102 Pearl St", "body" => "Done.")
      assert_equal "done", outcome[:status]
    end
  end

  private
    # Mail from a client as the thread records it (ReceivedMail, Conversation.received).
    def received_mail(message_id, subject:, from: "Li Wei <li@example.test>", at: Time.current)
      text = "Subject: #{subject}\nDate: #{at.rfc2822}\nTo: Travel <travel@agents.example>\n\nPlease confirm."
      @conversation.messages.create!(entry_key: message_id, entry_id: @conversation.messages.count + 1, role: "user", created_at: at,
        request_id: "email:#{@agent.id}:#{message_id}", sender: from, content: Conversation.received(text, from: from, via: "Email",
          answer: "To reply, use send_email to #{from} with in_reply_to #{message_id}; ending your turn does not reply."))
    end

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
