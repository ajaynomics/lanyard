require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# A call hears the same agent, from its own record, told what a call can't do.
class Agent::VoicePromptTest < ActiveSupport::TestCase
  include AgentTestHelper

  test "names the agent, its title and its owner, and keeps the owner's instructions within bounds" do
    starter = create_user(name: "Robin Example").agents.sole
    agent = starter.workspace.agents.create!(starter.attributes.slice(*%w[ user_id model thinking_level time_zone ]).merge(
      name: "Juniper", title: "Chief of Staff", instructions: "Speak warmly. Ask me before you book anything. " + "Detail. " * 2_000))
    prompt = Agent::VoicePrompt.new(agent).to_s

    assert_includes prompt, "You are Juniper, Chief of Staff, and you work for Robin Example."
    assert_match(/phone call.*brief/i, prompt)
    assert_includes prompt, "No tools are available on this call: you can't send, look up, book or change anything now."
    assert_includes prompt, "Speak warmly. Ask me before you book anything."
    assert_operator prompt.size, :<, Agent::VoicePrompt::INSTRUCTIONS_LIMIT + 1_000
  end

  test "says nothing about who is calling, even with the owner's number on record" do
    agent = create_user(name: "Robin Example").agents.sole
    agent.workspace.owner_membership.update!(phone_number: "416 555 0100")
    prompt = Agent::VoicePrompt.new(agent, reach: "owner").to_s

    assert_not_includes prompt, "5550100"
    assert_no_match(/speaking with|caller/i, prompt)
  end

  test "carries the thread's newest summary and the words since, within a fixed limit" do
    agent = create_user(name: "Robin Example").agents.sole
    messages = agent.conversation.messages
    messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "Before the summary")
    messages.create!(entry_id: 2, entry_key: "2", role: "summary", content: "<summary>\nRobin is planning a trip to Lisbon.\n</summary>")
    messages.create!(entry_id: 3, entry_key: "3", role: "user", content: "Find a hotel near the river.")
    messages.create!(entry_id: 4, entry_key: "4", role: "toolResult", content: "Tool output")
    messages.create!(entry_id: 5, entry_key: "5", role: "assistant", content: "[tool: web_search] Three hotels by the river.")
    prompt = Agent::VoicePrompt.new(agent, reach: "owner").to_s

    assert_includes prompt, "Robin is planning a trip to Lisbon."
    assert_includes prompt, "Robin Example: Find a hotel near the river.\nYou: Three hotels by the river."
    assert_not_includes prompt, "Before the summary"
    assert_not_includes prompt, "Tool output"

    40.times { messages.create!(entry_id: 10 + it, entry_key: "long-#{it}", role: "assistant", content: "Reply #{it} " + "words " * 100) }
    long = Agent::VoicePrompt.new(agent, reach: "owner").to_s
    assert_includes long, "Reply 39 words"
    assert_operator long.size - prompt.size, :<, Agent::VoicePrompt::CONVERSATION_LIMIT
  end

  test "never carries another workspace's agent's thread" do
    agent = create_user(name: "Robin Example").agents.sole
    agent.conversation.messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "Our own words")
    create_user(name: "Other Owner").agents.sole.conversation.messages.create!(entry_id: 2, entry_key: "2", role: "assistant", content: "Someone else's secret")
    prompt = Agent::VoicePrompt.new(agent, reach: "owner").to_s

    assert_includes prompt, "Our own words"
    assert_not_includes prompt, "Someone else's secret"
  end

  test "a stranger's call, as any call is unless it comes from the owner's number, carries no thread" do
    agent = create_user(name: "Robin Example").agents.sole
    agent.conversation.messages.create!(entry_id: 1, entry_key: "1", role: "user", content: "Our own words")

    assert_not_includes Agent::VoicePrompt.new(agent).to_s, "Our own words"
    assert_equal Agent::VoicePrompt.new(agent).to_s, Agent::VoicePrompt.new(agent, reach: "stranger").to_s
    assert_includes Agent::VoicePrompt.new(agent, reach: "owner").to_s, "Our own words"
  end
end
