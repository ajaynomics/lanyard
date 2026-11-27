require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GoogleAccountStartRaceTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  setup do
    @owner = create_user(name: "GoogleRace#{SecureRandom.hex(6)}", email: "operator@example.com")
    @connector = @owner.personal_workspace.mcp_servers.create!(user: @owner, name: "gmail_race", enabled: false,
      url: "https://gmailmcp.googleapis.com/mcp/v1", conversation: @owner.agents.sole.conversation,
      oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
      oauth_client: { "client_id" => "synthetic", "client_secret" => "synthetic" })
  end

  teardown { @owner&.destroy! }

  test "only one concurrent start and one concurrent callback can claim the same link" do
    token = GoogleAccountStart.issue!(@connector, by: @owner, issued_email: @owner.email, expected_email: "mailbox@example.com")
    nonces = 2.times.map { SecureRandom.urlsafe_base64(32) }
    starts = contend do |index|
      GoogleAccountStart.start(token, browser: nonces[index])&.then { |location| [ location, nonces[index] ] }
    end
    url, nonce = starts.sole
    state = URI.decode_www_form(URI(url).query).to_h.fetch("state")
    assert_equal [ @connector.id ], contend { GoogleAccountStart.claim_callback(state, browser: nonce)&.mcp_server_id }
    assert_nil @connector.reload.oauth_tokens
  end

  private
    def contend
      ready, start = Queue.new, Queue.new
      attempts = 2.times.map do |index|
        Thread.new do
          GoogleAccountStart.with_connection do
            ready << true
            start.pop
            yield index
          end
        end
      end
      Timeout.timeout(10) do
        attempts.each { ready.pop }
        attempts.each { start << true }
        attempts.map(&:value).compact.tap { |results| assert_equal 1, results.size }
      end
    ensure
      attempts&.each { |thread| thread.kill if thread.alive? }
      attempts&.each(&:join)
    end
end
