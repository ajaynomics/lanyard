require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class SkillTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @agent = create_user.agents.sole }

  test "names follow pi's rules, and each is the agent's own" do
    assert @agent.skills.create(name: "trip-planning", description: "Plans trips.", body: "Steps").persisted?

    [ "Trip", "trip--planning", "-trip", "trip-", "trip planning", "a" * 65, "trip-planning" ].each do |name|
      assert_not @agent.skills.new(name: name, description: "d", body: "b").valid?, name
    end
    assert @agent.skills.new(name: "a" * 64, description: "d", body: "b").valid?
  end

  test "a description is required and at most 1,024 characters, a body at most 32 KB, and an agent has at most 32 skills" do
    assert_not @agent.skills.new(name: "x", description: "", body: "b").valid?
    assert_not @agent.skills.new(name: "x", description: "d" * 1_025, body: "b").valid?
    assert_not @agent.skills.new(name: "x", description: "d", body: "").valid?
    assert_not @agent.skills.new(name: "x", description: "d", body: "b" * (32.kilobytes + 1)).valid?

    Skill::LIMIT.times { @agent.skills.create!(name: "s#{it}", description: "d", body: "b") }
    assert_match(/already has 32 skills/, @agent.skills.create(name: "more", description: "d", body: "b").errors.full_messages.to_sentence)
  end

  test "a SKILL.md gives its frontmatter's name and description, and the rest is the body" do
    skill = @agent.skills.from_markdown(<<~MARKDOWN)
      ---
      name: trip-planning
      description: Use when planning a trip.
      license: MIT
      ---

      # Trip planning

      1. Ask where.
    MARKDOWN

    assert_equal [ "trip-planning", "Use when planning a trip.", "# Trip planning\n\n1. Ask where." ], [ skill.name, skill.description, skill.body ]
    assert skill.save
    assert_equal @agent, skill.agent
  end

  test "a SKILL.md with no frontmatter, or broken frontmatter, is refused for what it lacks" do
    assert_equal "Just words", @agent.skills.from_markdown("Just words").body
    assert_not @agent.skills.from_markdown("Just words").valid?
    broken = @agent.skills.from_markdown("---\nname: [unclosed\n---\nBody")
    assert_not broken.valid?
    assert broken.errors[:description].any?
  end

  test "the invocation is pi's skill block, with the person's words after it" do
    skill = @agent.skills.new(name: "trip", description: "d", body: "\nStep one.\nStep two.\n")

    assert_equal %(<skill name="trip" location="skill:trip">\nStep one.\nStep two.\n</skill>\n\nto Lisbon), skill.invocation(" to Lisbon ")
    assert_equal %(<skill name="trip" location="skill:trip">\nStep one.\nStep two.\n</skill>), skill.invocation(nil)
  end

  test "a skill change keeps a revision and changes the agent's definition" do
    digest = @agent.conversation.definition[:digest]
    skill = nil
    assert_difference -> { @agent.revisions.count } do
      skill = @agent.skills.create!(name: "trip", description: "Plans trips.", body: "Steps")
    end
    assert_equal [ { "name" => "trip", "description" => "Plans trips.", "body" => "Steps" } ], @agent.revisions.last.skills
    with_skill = @agent.reload.conversation.definition[:digest]
    assert_not_equal digest, with_skill

    assert_difference -> { @agent.revisions.count } do
      skill.update!(description: "Plans trips abroad.")
    end
    assert_not_equal with_skill, @agent.reload.conversation.definition[:digest]

    skill.destroy!
    assert_equal digest, @agent.reload.conversation.definition[:digest]
    assert_empty @agent.revisions.last.skills
  end
end
