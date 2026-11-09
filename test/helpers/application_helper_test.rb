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
    assert_match "its sign-in can't be opened. Sign in again on the Subscriptions page", failure_text("credential_missing")
    assert_equal "too many computers are awake; try again shortly.", failure_text("computers_busy")
  end

  test "code is highlighted by class, and the model's own markup still never gets through" do
    html = markdown("```ruby\ndef greet = 1 # hi\n```\n\n<span class=\"x\" onclick=\"steal()\">raw</span>")
    assert_match %r{\A<pre class="syntax-highlighting">}, html
    assert_match %r{<span class="keyword[^"]*">def</span>}, html
    assert_no_match(/onclick|style=|class="x"/, html)
  end

  test "a link opens in a new tab; a bare one shows its address short, the whole in its title" do
    html = markdown("Pages: https://company-wiki.example.com/doc/people-1ClS8ajGbo-and-more, [the docs](https://example.com/a), www.example.com and [here](/agents).")
    assert_dom_equal <<~HTML.squish, html.squish
      <p>Pages: <a href="https://company-wiki.example.com/doc/people-1ClS8ajGbo-and-more" target="_blank" rel="noopener noreferrer"
        title="https://company-wiki.example.com/doc/people-1ClS8ajGbo-and-more">company-wiki.example.com/doc/people-1Cl…</a>,
      <a href="https://example.com/a" target="_blank" rel="noopener noreferrer">the docs</a>,
      <a href="http://www.example.com" target="_blank" rel="noopener noreferrer" title="http://www.example.com">example.com</a>
      and <a href="/agents">here</a>.</p>
    HTML
  end

  test "a picture from elsewhere is a link, never loaded; tasks keep their boxes; a footnote is its number and its note" do
    assert_dom_equal '<p><a href="https://example.com/cat.png" target="_blank" rel="noopener noreferrer">Picture: a cat</a></p>',
      markdown("![a cat](https://example.com/cat.png)").strip
    tasks = markdown("- [ ] call the bank\n- [x] book flights")
    assert_select_in tasks, "li input[type=checkbox][disabled]:not([checked])", count: 1
    assert_select_in tasks, "li input[type=checkbox][disabled][checked]", count: 1
    notes = markdown("Booked[^1]\n\n[^1]: the confirmation email")
    assert_match %r{Booked<sup class="footnote-ref">1</sup>}, notes
    assert_match "the confirmation email", notes
    assert_no_match(/\bid=|href="#/, notes)
  end

  test "a link can't be a script, and the model's own inputs never get through" do
    assert_no_match(/javascript/, markdown("[x](javascript:alert(1))"))
    assert_no_match(/<input/, markdown("<input type=\"text\" name=\"q\">"))
  end

  test "words a person or channel sent stay exactly as sent, their links live" do
    html = linked("see https://example.com/x, and <b>bold</b> (https://example.com/a_(b)).")
    assert_equal "see https://example.com/x, and <b>bold</b> (https://example.com/a_(b)).", Nokogiri::HTML5.fragment(html).text
    assert_equal [ "https://example.com/x", "https://example.com/a_(b)" ], Nokogiri::HTML5.fragment(html).css("a[target=_blank]").map { it["href"] }
    assert_no_match(/<b>/, html)
  end

  private
    def assert_select_in(html, selector, **options) = assert_equal(options[:count], Nokogiri::HTML5.fragment(html).css(selector).size, selector)
end
