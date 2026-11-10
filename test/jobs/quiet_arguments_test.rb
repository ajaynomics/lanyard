require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/push_test_helper"

# Jobs whose arguments are what someone wrote (a notice, a room's message, a
# mail) queue and run without writing those words to the log.
class QuietArgumentsTest < ActiveJob::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PushTestHelper

  WORDS = "Pick up the passports from the embassy".freeze

  setup do
    @robin = create_user(name: "Robin")
    @conversation = create_conversation(@robin.agents.sole)
  end

  test "a notification is queued and sent without its words in the log" do
    install_push_settings
    subscribe(@robin)
    stub_request(:post, PushTestHelper::ENDPOINT).to_return(status: 201)
    logged = log { perform_enqueued_jobs { Push.deliver(@robin, kind: "reply", title: "Iris", body: WORDS, url: "/", tag: "t") } }
    assert_match(/Push::DeliveryJob/, logged, "the job is logged, just not what it carries")
    assert_no_match(/passports/, logged)
  ensure
    remove_push_settings
  end

  test "a mail sent later is queued and sent without its words in the log" do
    install_email_settings
    logged = log { perform_enqueued_jobs { AgentMailer.needs_you(@conversation, title: "Iris needs you", body: WORDS).deliver_later } }
    assert_match(/MailDeliveryJob/, logged)
    assert_equal WORDS, ActionMailer::Base.deliveries.last.then { it.text_part&.body&.to_s || it.body.to_s }.then { it[WORDS] }
    assert_no_match(/passports/, logged)
  ensure
    remove_email_settings
  end

  test "a room's message is queued without its words in the log" do
    logged = log { CampfireReceiveJob.perform_later(@robin, { "content" => WORDS }) }
    assert_match(/CampfireReceiveJob/, logged)
    assert_no_match(/passports/, logged)
  end

  private
    # At production's level (RAILS_LOG_LEVEL, info). At debug Action Mailer
    # writes each message whole, which is what debug is for.
    def log
      output = StringIO.new
      capture = ActiveSupport::Logger.new(output, level: :info)
      Rails.logger.broadcast_to(capture)
      yield
      output.string
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
end
