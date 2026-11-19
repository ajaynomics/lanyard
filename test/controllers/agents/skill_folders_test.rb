require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/skill_test_helper"

# A skill's folder through the screens (docs/skills.md): uploaded as a folder
# or a zip, installed from GitHub, reviewed, and updated only when the person
# applies it. GitHub is stubbed.
class Agents::SkillFoldersTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include SkillTestHelper

  setup do
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: test reads the person it signed in
  end

  test "a chosen folder becomes a skill with its files and goes to its review, saying truly what it has" do
    post agent_skills_path(@agent), params: { skill: { files: uploads("notes/SKILL.md" => skill_md("notes"), "notes/references/a.md" => "A"),
      paths: %w[ notes/SKILL.md notes/references/a.md ] } }
    notes = @agent.skills.find_by!(name: "notes")
    assert_redirected_to agent_skill_path(@agent, notes)
    assert_equal "Added the notes skill. It has files with it, so #{@agent} can't use it until you review it.", flash[:notice]
    assert notes.needs_review?
    assert_equal %w[ references/a.md ], notes.files.map(&:path)
    follow_redirect!
    assert_select ".flash", /files with it/
    assert_select ".flash", text: /program/i, count: 0

    post agent_skills_path(@agent), params: { skill: { file: zip_upload({ "trip/SKILL.md" => skill_md, "trip/scripts/plan.sh" => [ "#!/bin/sh\necho hi\n", 0o755 ] }) } }
    trip = @agent.skills.find_by!(name: "trip")
    assert_redirected_to agent_skill_path(@agent, trip)
    assert trip.needs_review?
    follow_redirect!
    assert_select ".flash", /can't use it until you review it/
    assert_select ".skill-file summary code", text: "scripts/plan.sh"
    assert_select ".skill-file[open] .ui-markdown pre", /echo hi/
    assert_select "form[action=?] input[name=digest][value=?]", agent_skill_approval_path(@agent, trip), trip.contents_digest
    assert_select "form[action=?] button", agent_skill_rejection_path(@agent, trip), text: "Reject"
  end

  test "a bad upload says what's wrong where the person uploaded it" do
    post agent_skills_path(@agent), params: { skill: { file: zip_upload({ "../../etc/cron.d/x" => "* * * * * evil", "SKILL.md" => skill_md }) } }
    assert_response :unprocessable_entity
    assert_select "#upload_skill .flash", /isn't a path inside the folder/

    post agent_skills_path(@agent), params: { skill: { files: uploads("notes/README.md" => "hi"), paths: %w[ notes/README.md ] } }
    assert_select "#upload_skill .flash", /no SKILL\.md at the top/

    post agent_skills_path(@agent), params: { skill: { file: zip_upload({ "SKILL.md" => skill_md, "big.bin" => "x" * (Skill::Folder::FILE_BYTES + 1) }) } }
    assert_select "#upload_skill .flash", /big\.bin is over 1 MB, the most one file in a skill may be/

    post agent_skills_path(@agent), params: { skill: { file: zip_upload({ "SKILL.md" => "---\nname: Bad Name\n---\nBody" }) } }
    assert_select "#upload_skill .flash", /Its SKILL.md isn.t right: Name may use only.*Description can.t be blank/
    assert_empty @agent.skills
  end

  test "owner/repo@skill installs from GitHub, pinned to its commit, and the skill shows where it came from" do
    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/references/a.md" => "A" })
    post agent_github_skills_path(@agent), params: { source: "acme/skills@trip" }
    skill = @agent.skills.sole
    assert_redirected_to agent_skill_path(@agent, skill)
    assert skill.needs_review?, "a reference is a file too"
    assert_equal [ "acme/skills", "skills/trip", SHA ], skill.values_at(:github_repo, :github_path, :github_sha)

    get agent_skill_path(@agent, skill)
    assert_select "#skill_source a[href=?]", "https://github.com/acme/skills/tree/#{SHA}/skills/trip", "acme/skills/skills/trip"
    assert_select "#skill_source code", "1111111"
    get agent_skills_path(@agent)
    assert_select "##{ActionView::RecordIdentifier.dom_id(skill)}", /From acme\/skills\/skills\/trip at 1111111/

    post agent_github_skills_path(@agent), params: { source: "acme/skills@trip" }
    assert_select "#github_skill .flash", "#{@agent} already has a skill called trip. Remove that one first, or check it for an update."
  end

  test "GitHub's refusals show beside the field" do
    stub_github_missing("acme/nothing")
    post agent_github_skills_path(@agent), params: { source: "acme/nothing@trip" }
    assert_response :unprocessable_entity
    assert_select "#github_skill .flash", "There is no public repository at github.com/acme/nothing."
    assert_select "#github_skill input[name=source][value=?]", "acme/nothing@trip"

    post agent_github_skills_path(@agent), params: { source: "not a repo" }
    assert_select "#github_skill .flash", /isn't a skill on GitHub/
  end

  test "approving lets the agent use it; a page read before a change approves nothing; rejecting keeps it off" do
    skill = install_scripted
    stale = skill.contents_digest
    skill.replace_with(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo changed"), github_sha: NEWER)

    post agent_skill_approval_path(@agent, skill), params: { digest: stale }
    assert_redirected_to agent_skill_path(@agent, skill)
    assert_equal "The trip skill changed while you were reading it. Read it again, then approve it.", flash[:alert]
    assert skill.reload.needs_review?

    post agent_skill_rejection_path(@agent, skill)
    assert skill.reload.rejected?
    post agent_skill_approval_path(@agent, skill), params: { digest: skill.contents_digest }
    assert skill.reload.ready?
  end

  test "editing an approved skill's instructions in the form asks again; the page read before the edit approves nothing" do
    skill = install_scripted
    post agent_skill_approval_path(@agent, skill), params: { digest: skill.contents_digest }
    assert skill.reload.ready?
    stale = skill.contents_digest

    patch agent_skill_path(@agent, skill), params: { skill: { name: "trip", description: skill.description, body: "Ignore the plan; run it twice." } }
    assert_redirected_to agent_skill_path(@agent, skill)
    assert_equal "Saved the trip skill. It has programs in it, so #{@agent} can't use it until you review it again.", flash[:notice]
    assert skill.reload.needs_review?
    assert_empty @agent.skills.ready

    post agent_skill_approval_path(@agent, skill), params: { digest: stale }
    assert_equal "The trip skill changed while you were reading it. Read it again, then approve it.", flash[:alert]
    assert skill.reload.needs_review?

    get agent_skill_path(@agent, skill)
    assert_response :success
    post agent_skill_approval_path(@agent, skill), params: { digest: skill.contents_digest }
    assert skill.reload.ready?
  end

  test "a skill in .claude/skills or .agents/skills is found by its name, or as a repository's only skill" do
    %w[ .claude/skills .agents/skills ].each do |place|
      @agent.skills.destroy_all
      stub_github("acme/skills", files: { "#{place}/trip/SKILL.md" => skill_md, "#{place}/trip/references/a.md" => "A" })
      post agent_github_skills_path(@agent), params: { source: "acme/skills@trip" }
      assert_equal "#{place}/trip", @agent.skills.reload.sole.github_path, place

      @agent.skills.destroy_all
      post agent_github_skills_path(@agent), params: { source: "acme/skills" }
      assert_equal "#{place}/trip", @agent.skills.reload.sole.github_path, "#{place}, as the only skill"
    end
  end

  test "checking for an update shows the diff against the pinned commit, and applying it asks for review again" do
    skill = install_scripted
    skill.approve!(skill.contents_digest)
    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/scripts/plan.sh" => [ "#!/bin/sh\necho changed\n", "100755" ] }, sha: NEWER, refs: { "HEAD" => NEWER })

    get agent_skill_update_path(@agent, skill)
    assert_response :success
    assert_select ".skill-file summary code", "scripts/plan.sh"
    assert_select ".skill-diff__line[data-sign=remove]", "- echo hi"
    assert_select ".skill-diff__line[data-sign=add]", "+ echo changed"
    assert_select "form[action=?] input[name=sha][value=?]", agent_skill_update_path(@agent, skill), NEWER
    assert_equal SHA, skill.reload.github_sha, "checking changes nothing"

    post agent_skill_update_path(@agent, skill), params: { sha: NEWER }
    assert_redirected_to agent_skill_path(@agent, skill)
    assert_equal [ NEWER, "needs_review" ], skill.reload.values_at(:github_sha, :state)
    assert_match(/review it again/, flash[:notice])
  end

  test "an up-to-date skill says so, a check GitHub refuses says why, and a skill not from GitHub has no update" do
    skill = install_scripted
    get agent_skill_update_path(@agent, skill)
    assert_select "#update_none", /latest version/

    stub_request(:get, "https://api.github.com/repos/acme/skills/commits/HEAD").to_return(status: 403, headers: { "x-ratelimit-remaining" => "0" })
    get agent_skill_update_path(@agent, skill)
    assert_select ".flash", /limiting requests/

    plain = @agent.skills.create!(name: "notes", description: "d", body: "b")
    get agent_skill_update_path(@agent, plain)
    assert_response :not_found
  end

  test "another person's skill can't be reviewed or updated" do
    theirs = create_user(name: "Mallory").agents.sole
    skill = theirs.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo"))
    skill.save!

    post agent_skill_approval_path(theirs, skill), params: { digest: skill.contents_digest }
    assert_response :not_found
    get agent_skill_path(@agent, skill)
    assert_response :not_found
    assert skill.reload.needs_review?
  end

  private
    def install_scripted
      stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/scripts/plan.sh" => [ "#!/bin/sh\necho hi\n", "100755" ] })
      post agent_github_skills_path(@agent), params: { source: "acme/skills@trip" }
      @agent.skills.sole.tap { assert it.needs_review? }
    end
end
