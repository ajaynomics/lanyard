require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class DocumentTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user(name: "Maya").agents.sole
    @document = @agent.documents.create!(title: "Trip plan")
    @document.revise("Day 1: Lisbon\nDay 2: Porto\nDay 3: home\n", by: "agent")
  end

  test "each change is a numbered version, saying who wrote it; the body is the newest" do
    @document.revise("Day 1: Lisbon\nDay 2: Sintra\nDay 3: home\n", by: "person")

    assert_equal [ [ 1, "agent" ], [ 2, "person" ] ], @document.versions.pluck(:number, :author)
    assert_equal "Day 1: Lisbon\nDay 2: Sintra\nDay 3: home\n", @document.reload.body
    assert_equal 2, @document.number
  end

  test "the same words again make no new version" do
    assert_no_difference -> { @document.versions.count } do
      @document.revise(@document.body, by: "person")
    end
  end

  test "a targeted edit replaces text found exactly once, and all its edits apply or none" do
    @document.edit([ { "find" => "Porto", "replace" => "Coimbra" }, { "find" => "home", "replace" => "Madrid" } ], by: "agent")
    assert_equal "Day 1: Lisbon\nDay 2: Coimbra\nDay 3: Madrid\n", @document.reload.body

    missing = assert_raises(Document::EditRefused) { @document.edit([ { "find" => "Lisbon", "replace" => "Faro" }, { "find" => "Seville", "replace" => "x" } ], by: "agent") }
    assert_match(/"Seville" is not in Trip plan/, missing.message)
    repeated = assert_raises(Document::EditRefused) { @document.edit([ { "find" => "Day", "replace" => "Night" } ], by: "agent") }
    assert_match(/"Day" is in Trip plan 3 times/, repeated.message)
    assert_equal 2, @document.reload.versions.count, "nothing applied"
  end

  test "restoring an old version makes a new one with its words, written by the person" do
    first = @document.current_version
    @document.revise("Something else", by: "agent")

    restored = @document.restore(first)

    assert_equal [ 3, "person", first.body ], [ restored.number, restored.author, @document.reload.body ]
  end

  test "the agent has seen what it wrote; the person's versions wait, as a diff, until it sees them" do
    assert_not @document.changed_since_seen?
    assert_empty @agent.documents.changed_since_seen

    @document.revise("Day 1: Lisbon\nDay 2: Sintra\nDay 3: home\n", by: "person")
    assert @document.changed_since_seen?
    assert_equal [ @document ], @agent.documents.changed_since_seen

    assert_equal <<~DIFF.strip, @document.changes_since_seen
      --- Trip plan (document #{@document.id}, version 1, the one you last saw)
      +++ Trip plan (document #{@document.id}, version 2, the person's)
      @@ -1,3 +1,3 @@
       Day 1: Lisbon
      -Day 2: Porto
      +Day 2: Sintra
       Day 3: home
    DIFF

    @document.seen!
    assert_empty @agent.documents.changed_since_seen
  end

  test "the diff keeps three lines of context, and starts a new hunk where changes are further apart" do
    old = (1..20).map { "line #{it}" }.join("\n")
    new = old.sub("line 2", "line two").sub("line 18", "line eighteen") + "\nline 21"

    diff = Document::Diff.unified(old, new, from: "a", to: "b")

    assert_equal <<~DIFF.strip, diff
      --- a
      +++ b
      @@ -1,5 +1,5 @@
       line 1
      -line 2
      +line two
       line 3
       line 4
       line 5
      @@ -15,6 +15,7 @@
       line 15
       line 16
       line 17
      -line 18
      +line eighteen
       line 19
       line 20
      +line 21
    DIFF
    assert_equal "", Document::Diff.unified(old, old, from: "a", to: "b")
    assert_equal "--- a\n+++ b\n@@ -0,0 +1,1 @@\n+new", Document::Diff.unified("", "new", from: "a", to: "b")
  end

  test "the agent's note of changes fits in the room left, pointing to read_document for what does not" do
    @document.revise("Day 1: Faro\nDay 2: Porto\nDay 3: home\n", by: "person")
    big = @agent.documents.create!(title: "Novel").tap { it.revise("a", by: "agent") }
    big.revise("b\n" * 3_000, by: "person")

    note = Document.changes_for_agent([ @document, big ], room: 1_000)

    assert note.start_with?("\n\n<document_changes>\nThe person changed these documents in the canvas")
    assert_includes note, "+Day 1: Faro"
    assert_includes note, "Novel (document #{big.id}) changed too much to show here; call read_document with document_id #{big.id}."
    assert note.end_with?("</document_changes>")
  end

  test "a file is named for its title and kind" do
    assert_equal [ "trip-plan.md", "text/markdown" ], [ @document.filename, @document.content_type ]
    @document.update!(kind: "code", language: "Ruby")
    assert_equal [ "trip-plan.rb", "text/plain", "Ruby code" ], [ @document.filename, @document.content_type, @document.kind_name ]
    @document.update!(language: "html")
    assert_equal [ "trip-plan.html", "text/plain", "HTML code" ], [ @document.filename, @document.content_type, @document.kind_name ]
    @document.update!(language: "objective-c")
    assert_equal "trip-plan.txt", @document.filename
    assert_not @document.update(kind: "svg"), "a page or a picture is code: there is no preview"
  end

  test "a title is unique to its agent" do
    assert_not @agent.documents.new(title: "  Trip   plan ").valid?
    assert create_user(name: "Robin").agents.sole.documents.new(title: "Trip plan").valid?
  end
end
