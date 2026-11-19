require "test_helper"
require_relative "../../test_helpers/skill_test_helper"

# A skill's folder before it is a skill (docs/skills.md): however it came,
# its SKILL.md is at the top, every path stays inside it, it is small enough,
# and a program in it is known as one.
class Skill::FolderTest < ActiveSupport::TestCase
  include SkillTestHelper

  test "a chosen folder arrives inside its own name, which is dropped, and the litter an OS leaves is ignored" do
    folder = Skill::Folder.from_uploads(uploads("trip/SKILL.md" => skill_md, "trip/references/a.md" => "A", "trip/.DS_Store" => "x",
      "trip/scripts/plan.sh" => "echo"), %w[ trip/SKILL.md trip/references/a.md trip/.DS_Store trip/scripts/plan.sh ])

    assert_equal %w[ SKILL.md references/a.md scripts/plan.sh ], folder.entries.map(&:path)
    assert_equal %w[ references/a.md scripts/plan.sh ], folder.bundled.map(&:path)
    assert_equal({ "references/a.md" => false, "scripts/plan.sh" => true }, folder.bundled.to_h { [ it.path, it.executable ] })
    assert_match(/name: trip/, folder.markdown)
  end

  test "a program is one by its mode, a shebang, a Linux binary's first bytes or the scripts/ folder" do
    assert Skill::Folder.executable?("tool", "x", true)
    assert Skill::Folder.executable?("bin/go", "#!/usr/bin/env python3\n")
    assert Skill::Folder.executable?("lib/x.so", "\x7FELF\x02".b)
    assert Skill::Folder.executable?("scripts/notes.txt", "plain")
    assert Skill::Folder.executable?("tools/run.py", "print(1)")
    assert Skill::Folder.executable?("lib/helper.JS", "x")
    assert_not Skill::Folder.executable?("references/scripts.md", "# Scripts")
  end

  test "a zip unpacks to the same folder, its modes kept, read only up to each limit" do
    zip = zip_upload("trip/SKILL.md" => skill_md, "trip/bin/run" => [ "echo", 0o755 ], "trip/assets/logo.txt" => [ "logo", 0o644 ], "__MACOSX/trip/._SKILL.md" => "x")
    folder = Skill::Folder.from_uploads([ zip ])

    assert_equal %w[ SKILL.md assets/logo.txt bin/run ], folder.entries.map(&:path)
    assert_equal [ false, true ], folder.bundled.map(&:executable)
  end

  test "no path leaves the folder: absolute, .., backslashes, a drive and control characters are refused" do
    [ "/etc/passwd", "../evil", "a/../../evil", "a\\..\\evil", "C:/evil", "a//b", "a/./b", "bad\u0000name", "a/#{'x' * 101}", "a/#{'é' * 51}" ].each do |path|
      error = assert_raises(Skill::Folder::Invalid, path) { skill_folder("SKILL.md" => skill_md, path => "x") }
      assert_match(/isn't a path inside the folder/, error.message)
    end
    error = assert_raises(Skill::Folder::Invalid) { Skill::Folder.from_uploads([ zip_upload("SKILL.md" => skill_md, "../../outside.sh" => "echo") ]) }
    assert_match(/outside\.sh.*isn't a path inside the folder/, error.message)
  end

  test "a file can't also be a folder: a and a/b are refused before either reaches a computer" do
    [ { "notes" => "x", "notes/a.md" => "y" }, { "references/a" => "x", "references/a/b/c.md" => "y" }, { "SKILL.md/x" => "y" } ].each do |files|
      error = assert_raises(Skill::Folder::Invalid, files.keys.inspect) { skill_folder({ "SKILL.md" => skill_md }.merge(files)) }
      assert_match(/is both a file and a folder/, error.message)
    end
    assert skill_folder("SKILL.md" => skill_md, "notes.md" => "x", "notes/a.md" => "y"), "a name that only starts the same is fine"
  end

  test "a folder without SKILL.md at its top, or whose SKILL.md isn't text, is refused and says why" do
    assert_match(/no SKILL\.md at the top/, assert_raises(Skill::Folder::Invalid) { skill_folder("README.md" => "hi") }.message)
    assert_match(/no SKILL\.md at the top/, assert_raises(Skill::Folder::Invalid) { skill_folder("a/SKILL.md" => skill_md, "b/x.md" => "x") }.message)
    assert_match(/isn't text/, assert_raises(Skill::Folder::Invalid) { skill_folder("SKILL.md" => "\x00\xFF".b) }.message)
    assert_match(/Choose a folder/, assert_raises(Skill::Folder::Invalid) { Skill::Folder.from_uploads([]) }.message)
  end

  test "too many files, a file too large, or a folder too large is refused before it is a skill" do
    many = (1..Skill::Folder::FILES + 1).to_h { [ "references/#{it}.md", "x" ] }
    assert_match(/at most 100/, assert_raises(Skill::Folder::Invalid) { skill_folder({ "SKILL.md" => skill_md }.merge(many)) }.message)

    big = "x" * (Skill::Folder::FILE_BYTES + 1)
    assert_match(/assets\/big\.bin is over 1 MB, the most one file in a skill may be\./, assert_raises(Skill::Folder::Invalid) { skill_folder("SKILL.md" => skill_md, "assets/big.bin" => big) }.message)
    assert_match(/big\.txt is over 1 MB/, assert_raises(Skill::Folder::Invalid) { Skill::Folder.from_uploads([ zip_upload("SKILL.md" => skill_md, "big.txt" => big) ]) }.message)

    six = (1..6).to_h { [ "assets/#{it}.bin", "x" * (Skill::Folder::FILE_BYTES - 10) ] }
    assert_match(/over 5 MB/, assert_raises(Skill::Folder::Invalid) { skill_folder({ "SKILL.md" => skill_md }.merge(six)) }.message)
  end

  test "a zip that is not one, or holds a link, is refused" do
    broken = Rack::Test::UploadedFile.new(StringIO.new("not a zip"), "application/zip", true, original_filename: "skill.zip")
    assert_match(/couldn't be opened/, assert_raises(Skill::Folder::Invalid) { Skill::Folder.from_uploads([ broken ]) }.message)

    io = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      zip.put_next_entry("SKILL.md")
      zip.write(skill_md)
      link = Zip::Entry.new("", "secrets")
      link.instance_variable_set(:@ftype, :symlink)
      zip.put_next_entry(link)
      zip.write("/etc/passwd")
    end
    linked = Rack::Test::UploadedFile.new(StringIO.new(io.string), "application/zip", true, original_filename: "skill.zip")
    assert_match(/secrets is a link/, assert_raises(Skill::Folder::Invalid) { Skill::Folder.from_uploads([ linked ]) }.message)
  end
end
