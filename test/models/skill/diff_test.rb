require "test_helper"

# What an update would change: each file added, removed or changed, its
# lines as `diff -u` shows them, with three lines of context.
class Skill::DiffTest < ActiveSupport::TestCase
  test "files added, removed and changed, and a file that becomes a program says so" do
    before = { "a.md" => [ "same\n", false ], "gone.md" => [ "x", false ], "run" => [ "echo", false ] }
    after = { "a.md" => [ "same\n", false ], "new.md" => [ "y", false ], "run" => [ "echo", true ] }
    changes = Skill::Diff.new(before, after).changes

    assert_equal [ %w[ gone.md removed ], %w[ new.md added ], %w[ run changed ] ], changes.map { [ it.path, it.status ] }
    assert_equal "now runs as a program", changes.last.note
    assert_equal [ [ "+", "y" ] ], changes.second.lines
    assert Skill::Diff.new(before, before).empty?
  end

  test "a changed line shows with its context, and far unchanged lines fold into a count" do
    old = (1..20).map { "line #{it}" }.join("\n")
    new = old.sub("line 10", "line ten")
    lines = Skill::Diff.new({ "a" => [ old, false ] }, { "a" => [ new, false ] }).changes.sole.lines

    assert_equal [ [ "…", 6 ], [ " ", "line 7" ], [ " ", "line 8" ], [ " ", "line 9" ], [ "-", "line 10" ], [ "+", "line ten" ],
      [ " ", "line 11" ], [ " ", "line 12" ], [ " ", "line 13" ], [ "…", 7 ] ], lines
  end

  test "bytes that aren't text are compared by size alone" do
    change = Skill::Diff.new({ "logo.png" => [ "\x89PNG\x00".b, false ] }, { "logo.png" => [ "\x89PNG\x00\x01".b, false ] }).changes.sole
    assert_nil change.lines
    assert_equal "not text: 5 Bytes before, 6 Bytes after", change.note
  end
end
