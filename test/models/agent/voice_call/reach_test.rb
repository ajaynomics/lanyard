require "test_helper"
require_relative "../../../test_helpers/agent_test_helper"

# Only a number on file in the agent's workspace reaches its thread.
# Numbers here are made up.
class Agent::VoiceCall::ReachTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
    @agent.workspace.owner_membership.update!(phone_number: "(416) 555-0100")
  end

  test "the owner's number on file, however the carrier writes it, is the owner's reach" do
    [ "+14165550100", "14165550100", "4165550100", "+1 (416) 555-0100" ].each do |number|
      assert_equal "owner", Agent::VoiceCall::Reach.of(@agent, number), number
    end
  end

  test "another number, another country's, none, or no number on file is a stranger's" do
    [ "+14165550199", "+4165550100", "+44 4165550100", "anonymous", "", nil ].each do |number|
      assert_equal "stranger", Agent::VoiceCall::Reach.of(@agent, number), number.inspect
    end
    @agent.workspace.owner_membership.update!(phone_number: nil)
    assert_equal "stranger", Agent::VoiceCall::Reach.of(@agent, "+14165550100")
  end

  test "a member reaches the thread even when the owner has no number on file" do
    @agent.workspace.owner_membership.update!(phone_number: nil)
    member = @agent.workspace.memberships.create!(user: create_user(name: "Robin"), role: "member", phone_number: "(647) 555-0123")
    assert_equal "owner", Agent::VoiceCall::Reach.of(@agent, "+16475550123")
    member.destroy!
    assert_equal "stranger", Agent::VoiceCall::Reach.of(@agent, "+16475550123")
  end

  test "a member of another workspace does not reach this thread" do
    other = create_user(name: "Robin")
    other.personal_workspace.owner_membership.update!(phone_number: "6475550123")
    assert_equal "stranger", Agent::VoiceCall::Reach.of(@agent, "+16475550123")
  end
end
