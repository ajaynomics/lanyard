require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Bots::SkillsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  SKILL_MD = "---\nname: trip-planning\ndescription: Use when planning a trip.\n---\n\n# Trip planning\n".freeze

  setup do
    sign_in_via_ajent
    @bot = User.find_by!(oidc_sub: "42").bots.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person adds a skill in the form, edits it and removes it" do
    post bot_skills_path(@bot), params: { skill: { name: "trip", description: "Plans trips.", body: "Steps" } }
    assert_redirected_to bot_path(@bot, anchor: "skills")
    skill = @bot.skills.sole
    follow_redirect!
    assert_select "#skills .list__item", /trip.*Plans trips/m

    patch bot_skill_path(@bot, skill), params: { skill: { description: "" } }
    assert_response :unprocessable_entity
    patch bot_skill_path(@bot, skill), params: { skill: { description: "Plans trips abroad." } }
    assert_equal "Plans trips abroad.", skill.reload.description

    delete bot_skill_path(@bot, skill)
    assert_empty @bot.skills
  end

  test "a pasted or uploaded SKILL.md becomes a skill" do
    post bot_skills_path(@bot), params: { skill: { markdown: SKILL_MD } }
    assert_equal [ "trip-planning", "# Trip planning" ], @bot.skills.sole.values_at(:name, :body)

    file = Rack::Test::UploadedFile.new(StringIO.new(SKILL_MD.sub("trip-planning", "packing")), "text/markdown", original_filename: "SKILL.md")
    post bot_skills_path(@bot), params: { skill: { file: file, markdown: "" } }
    assert_equal %w[ packing trip-planning ], @bot.skills.pluck(:name)

    huge = Rack::Test::UploadedFile.new(StringIO.new(SKILL_MD.sub("trip-planning", "huge") + ("x" * 70_000)), "text/markdown", original_filename: "SKILL.md")
    post bot_skills_path(@bot), params: { skill: { file: huge } }
    assert_response :unprocessable_entity
    assert_select ".flash", /32 KB/
  end

  test "another person's bot and skills are not found" do
    theirs = create_user(name: "Mallory").bots.sole
    skill = theirs.skills.create!(name: "theirs", description: "d", body: "b")

    patch bot_skill_path(@bot, skill), params: { skill: { body: "mine" } }
    assert_response :not_found
    post bot_skills_path(theirs), params: { skill: { markdown: SKILL_MD } }
    assert_response :not_found
    assert_equal "b", skill.reload.body
  end
end
