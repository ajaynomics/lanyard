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

  test "a stop reason reads as words, a usage limit as what to do about it" do
    assert_equal "model error", failure_text("model_error")
    assert_match "usage limit is reached", failure_text("rate_limited")
    assert_match "save its API key, on the Subscriptions page", failure_text("credential_missing")
    assert_equal "too many computers are awake; try again shortly.", failure_text("computers_busy")
  end

  test "code is highlighted by class, and the model's own markup still never gets through" do
    html = markdown("```ruby\ndef greet = 1 # hi\n```\n\n<span class=\"x\" onclick=\"steal()\">raw</span>")
    assert_match %r{\A<pre class="syntax-highlighting">}, html
    assert_match %r{<span class="keyword[^"]*">def</span>}, html
    assert_no_match(/onclick|style=|class="x"/, html)
  end
end
