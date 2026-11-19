require "test_helper"
require "timeout"
require_relative "../../test_helpers/agent_test_helper"

class Conversation::SubmissionConcurrencyTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  setup do
    install_sidecar_settings
    @user = create_user(name: "Submission Writer", email: "submission-writer@example.com")
    @conversation = create_conversation(@user.agents.sole)
    @url = "#{SIDECAR}/v1/conversations/12/submissions"
    @release, @entered = Queue.new, Queue.new
    @threads = []
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil }.to_json)
  end

  teardown do
    4.times { @release << true }
    @threads.each { it.join(4) || it.kill }
    @user&.destroy!
    remove_sidecar_settings
  end

  test "concurrent equal IDs publish one envelope and release the write lock across both network calls" do
    stub_request(:post, @url).to_return do |request|
      raise "network inside a transaction" if ActiveRecord::Base.connection_pool.with_connection(&:transaction_open?)
      @entered << request.body
      @release.pop
      { status: 202, body: { id: 61 }.to_json }
    end
    send_from_another_connection
    first = Timeout.timeout(4) { @entered.pop }

    # A third connection can write while the first response remains held.
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).update!(name: "Still available")
      end
    end
    @threads << writer
    assert writer.join(4), "an unrelated write was blocked by the sidecar response"
    writer.value

    send_from_another_connection
    second = Timeout.timeout(4) { @entered.pop }
    assert_equal first, second
    2.times { @release << true }
    responses = @threads.reject { it == writer }.map { |thread| Timeout.timeout(4) { thread.value } }
    assert_equal [ { "id" => 61 }, { "id" => 61 } ], responses
    assert_equal 1, @conversation.submissions.count
    record = @conversation.submissions.sole
    assert record.accepted_at && record.acknowledged_at
    assert_nil record.payload
  end

  private
    def send_from_another_connection
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          conversation = @user.conversations.find(@conversation.id)
          conversation.submit("Just once", request_id: "same")
        end
      end
    end
end
