require "test_helper"
require_relative "../../test_helpers/skill_test_helper"

# A skill in a public GitHub repository (docs/skills.md), found as `npx
# skills add` finds one and fetched at one commit. GitHub is stubbed.
class Skill::GithubTest < ActiveSupport::TestCase
  include SkillTestHelper

  test "owner/repo@skill finds the skill's folder where npx skills looks, and pins the commit" do
    stub_github("acme/skills", files: { "README.md" => "Hi", "skills/trip/SKILL.md" => skill_md, "skills/trip/scripts/plan.sh" => [ "echo", "100755" ],
      "skills/other/SKILL.md" => skill_md("other"), "examples/trip/SKILL.md" => skill_md })
    folder, source = Skill::Github.parse("acme/skills@trip").fetch

    assert_equal %w[ SKILL.md scripts/plan.sh ], folder.entries.map(&:path)
    assert folder.bundled.sole.executable
    assert_equal({ github_repo: "acme/skills", github_path: "skills/trip", github_ref: nil, github_sha: SHA }, source)
  end

  test "a repository that is one skill, or holds one, needs no name; one with several asks for one" do
    stub_github("acme/one", files: { "SKILL.md" => skill_md, "references/a.md" => "A" })
    folder, source = Skill::Github.parse("https://github.com/acme/one").fetch
    assert_equal [ %w[ SKILL.md references/a.md ], "" ], [ folder.entries.map(&:path), source[:github_path] ]

    stub_github("acme/many", files: { ".claude/skills/b/SKILL.md" => skill_md("b"), ".claude/skills/a/SKILL.md" => skill_md("a") })
    error = assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/many").fetch }
    assert_equal "acme/many has 2 skills. Add @ and one's name, as acme/many@a. It has a and b.", error.message
  end

  test "a link to a folder, on a branch whose name has a slash, or to its SKILL.md" do
    stub_github_missing("acme/skills", "feature")
    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md }, refs: { "feature/new" => SHA })
    _, source = Skill::Github.parse("https://github.com/acme/skills/tree/feature/new/skills/trip").fetch
    assert_equal({ github_repo: "acme/skills", github_path: "skills/trip", github_ref: "feature/new", github_sha: SHA }, source)

    _, source = Skill::Github.parse("https://github.com/acme/skills/blob/feature/new/skills/trip/SKILL.md").fetch
    assert_equal "skills/trip", source[:github_path]
  end

  test "each thing that doesn't exist says what" do
    stub_github_missing("acme/nothing")
    assert_equal "There is no public repository at github.com/acme/nothing.", assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/nothing@trip").fetch }.message

    stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "docs/x.md" => "x" }, refs: { "HEAD" => SHA, "main" => SHA })
    assert_equal "acme/skills has no skill called packing. It has trip.", assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/skills@packing").fetch }.message
    assert_equal "There is no SKILL.md in acme/skills at docs.", assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("https://github.com/acme/skills/tree/main/docs").fetch }.message
    stub_request(:get, %r{\Ahttps://api.github.com/repos/acme/skills/commits/nope}).to_return(status: 404)
    assert_equal "acme/skills has no branch, tag or commit called nope.", assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("https://github.com/acme/skills/tree/nope/skills/trip").fetch }.message

    stub_github("acme/empty", files: { "README.md" => "x" })
    assert_equal "acme/empty has no SKILL.md in it, so it holds no skills.", assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/empty").fetch }.message

    [ "", "acme", "https://gitlab.com/acme/skills", "acme/skills@Trip Plan", "acme/../etc" ].each do |text|
      assert_match(/isn't a skill on GitHub/, assert_raises(Skill::Folder::Invalid, text) { Skill::Github.parse(text) }.message)
    end
  end

  test "a folder too large is refused from GitHub's listing, before a file is fetched" do
    raw = stub_github("acme/big", files: { "SKILL.md" => skill_md, "assets/huge.bin" => "x" * (Skill::Folder::FILE_BYTES + 1) })
    assert_match(/assets\/huge\.bin is over 1 MB/, assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/big").fetch }.message)
    raw.each_value { assert_not_requested it }
  end

  test "a link inside the folder is refused, and a rate limit says so" do
    stub_github("acme/linked", files: { "SKILL.md" => skill_md, "secrets" => [ "/etc/passwd", "120000" ] })
    assert_match(/secrets is a link/, assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/linked").fetch }.message)

    stub_request(:get, "https://api.github.com/repos/acme/busy/commits/HEAD").to_return(status: 403, headers: { "x-ratelimit-remaining" => "0" })
    assert_match(/limiting requests/, assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/busy").fetch }.message)
  end

  test "an update fetches only the files whose git name changed" do
    raw = stub_github("acme/skills", files: { "skills/trip/SKILL.md" => skill_md, "skills/trip/references/a.md" => "A" }, sha: NEWER, refs: { "HEAD" => NEWER })
    known = [ Skill::BundledFile.new(path: "references/a.md", content: "A") ]
    folder, = Skill::Github.new(repo: "acme/skills", path: "skills/trip").fetch(known: known)

    assert_equal "A", folder.bundled.sole.content
    assert_not_requested raw["skills/trip/references/a.md"]
    assert_requested raw["skills/trip/SKILL.md"]
  end

  test "a listing GitHub cut short is read only through the linked folder's own listing, or refused" do
    md, ref = skill_md, "skills/trip/references/a.md"
    stub_request(:get, "https://api.github.com/repos/acme/huge/commits/main").to_return(body: SHA)
    stub_request(:get, "https://api.github.com/repos/acme/huge/commits/HEAD").to_return(body: SHA)
    stub_request(:get, "https://api.github.com/repos/acme/huge/git/trees/#{SHA}?recursive=1").to_return(body: { truncated: true, tree: [
      { path: "skills/trip", type: "tree", mode: "040000", sha: NEWER }, { path: "skills/trip/SKILL.md", type: "blob", mode: "100644", size: md.bytesize, sha: Skill::Folder.git_sha(md) } ] }.to_json)
    stub_request(:get, "https://api.github.com/repos/acme/huge/git/trees/#{NEWER}?recursive=1").to_return(body: { truncated: false, tree: [
      { path: "SKILL.md", type: "blob", mode: "100644", size: md.bytesize, sha: Skill::Folder.git_sha(md) },
      { path: "references", type: "tree", mode: "040000", sha: "3" * 40 },
      { path: "references/a.md", type: "blob", mode: "100644", size: 1, sha: Skill::Folder.git_sha("A") } ] }.to_json)
    stub_request(:get, "https://raw.githubusercontent.com/acme/huge/#{SHA}/skills/trip/SKILL.md").to_return(body: md)
    stub_request(:get, "https://raw.githubusercontent.com/acme/huge/#{SHA}/#{ref}").to_return(body: "A")

    folder, source = Skill::Github.parse("https://github.com/acme/huge/tree/main/skills/trip").fetch
    assert_equal [ %w[ SKILL.md references/a.md ], "skills/trip" ], [ folder.entries.map(&:path), source[:github_path] ]

    too_large = "This repository is too large to read whole; link the skill's folder directly."
    assert_equal too_large, assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("acme/huge@trip").fetch }.message
    assert_equal too_large, assert_raises(Skill::Folder::Invalid) { Skill::Github.parse("https://github.com/acme/huge/tree/main/skills/other").fetch }.message
  end
end
