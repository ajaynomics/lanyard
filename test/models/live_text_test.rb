require "test_helper"

class LiveTextTest < ActiveSupport::TestCase
  test "a block settles at a blank line before an unindented line; the last is still being written" do
    live = LiveText.new("Here's the plan:\n\n## Flights\n- Out on the 12th\n\nWant me to ho")
    assert_equal [ "Here's the plan:\n", "## Flights\n- Out on the 12th\n" ], live.settled
    assert_equal "Want me to ho", live.open
  end

  test "a blank line ends nothing inside a code fence, before an indented line, or before a line not yet begun" do
    assert_empty LiveText.new("```\nputs 1\n\nputs 2\n```").settled
    assert_empty LiveText.new("1. Step one\n\n   More about it").settled
    assert_empty LiveText.new("A paragraph.\n\n").settled
    assert_equal [ "```\na\n\nb\n```\n" ], LiveText.new("```\na\n\nb\n```\n\nAfter").settled
  end

  test "settled_since gives the blocks that settled after the bytes already sent, with their places" do
    text = "Café first.\n\nSecond.\n\nThird is being wri"
    assert_equal [ [ "Second.\n", 1 ] ], LiveText.new(text).settled_since("Café first.\n\nSec".bytesize).to_a
    assert_equal [ [ "Café first.\n", 0 ], [ "Second.\n", 1 ] ], LiveText.new(text).settled_since(0).to_a
    assert_empty LiveText.new(text).settled_since(text.bytesize).to_a
  end

  test "an empty text is one empty block, still being written" do
    assert_empty LiveText.new("").settled
    assert_equal "", LiveText.new(nil).open
  end
end
