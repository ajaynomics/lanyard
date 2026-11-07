require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agents::SkillsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  SKILL_MD = "---\nname: trip-planning\ndescription: Use when planning a trip.\n---\n\n# Trip planning\n".freeze

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "the person adds a skill in the form, edits it and removes it" do
    post agent_skills_path(@agent), params: { skill: { name: "trip", description: "Plans trips.", body: "Steps" } }
    assert_redirected_to agent_path(@agent, anchor: "skills")
    skill = @agent.skills.sole
    follow_redirect!
    assert_select "#skills .list__item", /trip.*Plans trips/m

    patch agent_skill_path(@agent, skill), params: { skill: { description: "" } }
    assert_response :unprocessable_entity
    patch agent_skill_path(@agent, skill), params: { skill: { description: "Plans trips abroad." } }
    assert_equal "Plans trips abroad.", skill.reload.description

    delete agent_skill_path(@agent, skill)
    assert_empty @agent.skills
  end

  test "a pasted or uploaded SKILL.md becomes a skill" do
    post agent_skills_path(@agent), params: { skill: { markdown: SKILL_MD } }
    assert_equal [ "trip-planning", "# Trip planning" ], @agent.skills.sole.values_at(:name, :body)

    file = Rack::Test::UploadedFile.new(StringIO.new(SKILL_MD.sub("trip-planning", "packing")), "text/markdown", original_filename: "SKILL.md")
    post agent_skills_path(@agent), params: { skill: { file: file, markdown: "" } }
    assert_equal %w[ packing trip-planning ], @agent.skills.pluck(:name)

    huge = Rack::Test::UploadedFile.new(StringIO.new(SKILL_MD.sub("trip-planning", "huge") + ("x" * 70_000)), "text/markdown", original_filename: "SKILL.md")
    post agent_skills_path(@agent), params: { skill: { file: huge } }
    assert_response :unprocessable_entity
    assert_select ".flash", /32 KB/
  end

  test "another person's agent and skills are not found" do
    theirs = create_user(name: "Mallory").agents.sole
    skill = theirs.skills.create!(name: "theirs", description: "d", body: "b")

    patch agent_skill_path(@agent, skill), params: { skill: { body: "mine" } }
    assert_response :not_found
    post agent_skills_path(theirs), params: { skill: { markdown: SKILL_MD } }
    assert_response :not_found
    assert_equal "b", skill.reload.body
  end
end
