require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "a tool's label reads as words, an MCP tool's with its server after it" do
    assert_equal "remember note", tool_label("remember_note")
    assert_equal "code", tool_label("codemode")
    assert_equal "helper", tool_label("subagent")
    assert_equal "web search", tool_label("web_search")
    assert_equal "read wiki structure (deepwiki)", tool_label("mcp__deepwiki__read_wiki_structure")
    assert_equal "list issues (my_github)", tool_label("mcp__my_github__list_issues")
  end
end
