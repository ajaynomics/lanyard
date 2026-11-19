require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/skill_test_helper"

# Skill folders in a browser (docs/skills.md): a folder chosen from the
# computer, a skill installed from GitHub, its programs read and approved,
# and an update shown as a diff and reviewed again. GitHub is stubbed.
class SkillsTest < ApplicationSystemTestCase
  include AgentTestHelper
  include SkillTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
  end
  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  test "a chosen folder arrives with each file's path, and a program in it waits for review" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "trip/scripts"))
      File.write(File.join(root, "trip/SKILL.md"), skill_md)
      File.write(File.join(root, "trip/scripts/plan.sh"), "#!/bin/sh\necho hi\n")
      visit new_agent_skill_path(@agent)
      attach_file "A skill's folder", File.join(root, "trip"), make_visible: true
      within("#upload_skill") { click_on "Add" }

      assert_text "It has programs in it, so #{@agent} can't use it until you review it."
      assert_selector ".skill-file summary code", text: "scripts/plan.sh"
    end
    assert_equal %w[ scripts/plan.sh ], @agent.skills.sole.files.map(&:path)
  end

  test "install from GitHub, read the program, approve it; an update shows its diff and asks again, and is rejected" do
    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/scripts/plan.sh" => [ "#!/bin/sh\necho hi\n", "100755" ] })
    visit new_agent_skill_path(@agent)
    fill_in "Repository and skill, or a link to its folder", with: "acme/skills@trip"
    click_on "Install"

    assert_text "can't use this skill yet"
    assert_selector "#skill_source", text: "acme/skills/skills/trip"
    assert_selector ".skill-file[open] pre", text: "echo hi"
    click_on "Approve"
    assert_text "Approved the trip skill."
    assert_selector ".ui-status", text: "Ready"

    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/scripts/plan.sh" => [ "#!/bin/sh\necho bye\n", "100755" ] },
      sha: NEWER, refs: { "HEAD" => NEWER })
    click_on "Check for update"
    assert_selector ".skill-diff__line[data-sign=remove]", text: "- echo hi"
    assert_selector ".skill-diff__line[data-sign=add]", text: "+ echo bye"
    click_on "Apply update"
    assert_text "review it again"
    assert_selector ".ui-status", text: "Waiting for your review"
    click_on "Reject"
    assert_text "Rejected the trip skill."
    assert @agent.skills.sole.rejected?
  end

  test "an error from GitHub shows beside the field" do
    stub_github_missing("acme/nothing")
    visit new_agent_skill_path(@agent)
    fill_in "Repository and skill, or a link to its folder", with: "acme/nothing@trip"
    click_on "Install"

    assert_selector "#github_skill .flash", text: "There is no public repository at github.com/acme/nothing."
  end
end
