require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class McpClientSecretSetupRaceTest < ActiveSupport::TestCase
  include AgentTestHelper
  self.use_transactional_tests = false

  setup do
    label = "SetupRace#{SecureRandom.hex(6)}"
    @owner = create_user(name: label)
    @connector = @owner.personal_workspace.mcp_servers.create!(user: @owner, name: "setup_example", url: "https://connector.example.org/mcp",
      conversation: @owner.agents.sole.conversation, oauth_client: { "client_id" => "public-client-example" })
  end

  teardown { @owner&.destroy! }

  test "simultaneous redemption of one link saves once" do
    _, token = McpClientSecretSetup.issue!(@connector, by: @owner)
    contend([ token, token ])
    assert_equal 1, @connector.client_secret_setups.where.not(used_at: nil).count
  end

  test "competing links cannot replace the winning client secret" do
    tokens = 2.times.map { McpClientSecretSetup.issue!(@connector, by: @owner).last }
    contend(tokens)
  end

  private
    def contend(tokens)
      ready, begin_write = Queue.new, Queue.new
      attempts = tokens.each_with_index.map do |token, index|
        Thread.new do
          McpClientSecretSetup.with_connection do
            setup = McpClientSecretSetup.find_by_token(token)
            secret = "synthetic submission #{index}"
            ready.push(true)
            begin_write.pop
            [ secret, setup.fill!(secret:) ]
          end
        end
      end
      Timeout.timeout(10) do
        attempts.size.times { ready.pop }
        attempts.size.times { begin_write.push(true) }
        winners = attempts.map(&:value).select(&:last)
        assert_equal 1, winners.size
        assert_equal winners.sole.first, @connector.reload.oauth_client.fetch("client_secret")
      end
    ensure
      attempts&.each { |thread| thread.kill if thread.alive? }
      attempts&.each(&:join)
    end
end
