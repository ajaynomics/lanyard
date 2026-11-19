require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Document::ContextTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user(name: "Maya").agents.sole
    @document = @agent.documents.create!(title: "Trip plan")
    @seen = @document.revise("Porto\n", by: "agent")
  end

  test "only an unseen target has a context" do
    assert_nil @document.context
    assert_nil @agent.documents.create!(title: "Empty").context

    target = @document.revise("Sintra\n", by: "person")
    snapshot = @document.context

    assert_equal %w[ diff document_id fallback from_version_id version_id ], snapshot.keys.sort
    assert_equal [ @document.id, @seen.id, target.id ], snapshot.values_at("document_id", "from_version_id", "version_id")
    assert_equal @document.changes_since_seen, snapshot.fetch("diff")

    @document.seen!(version: target)
    assert_nil @document.context
  end

  test "a first version has a diff from the empty document" do
    document = @agent.documents.create!(title: "New")
    target = document.revise("Hello\n", by: "person")

    snapshot = document.context

    assert_nil snapshot.fetch("from_version_id")
    assert_equal target.id, snapshot.fetch("version_id")
    assert_includes snapshot.fetch("diff"), "version 0, the one you last saw"
    assert_includes snapshot.fetch("diff"), "+Hello"
  end

  test "a detached snapshot keeps its captured versions and title after later edits" do
    target = @document.revise("Sintra\n", by: "person")
    snapshot = @document.context
    saved = JSON.parse(JSON.generate(snapshot))
    note = Document.changes_for_agent([ snapshot ], room: 10_000)

    @document.revise("Coimbra\n", by: "person")
    @document.update!(title: "New title")
    @document.seen!
    @document.reload

    assert_equal saved, snapshot
    assert_equal note, Document.changes_for_agent([ snapshot ], room: 10_000)
    assert_equal target.id, snapshot.fetch("version_id")
    assert_includes snapshot.fetch("diff"), "+++ Trip plan (document #{@document.id}, version 2, the person's)"
    assert_includes snapshot.fetch("diff"), "+Sintra"
    assert_not_includes note, "Coimbra"
    assert_not_includes note, "New title"
  end

  test "diff calculation uses captured bodies and labels without a write lock" do
    target = @document.revise("Sintra\n", by: "person")
    unified = Document::Diff.method(:unified)
    check, document = self, @document
    calculate = ->(from_body, to_body, **labels) do
      check.assert from_body.frozen?
      check.assert to_body.frozen?
      document.title.replace("Changed during diff")
      document.versions.create!(body: "Later\n", author: "person", number: 3)
      unified.call(from_body, to_body, **labels)
    end
    @document.define_singleton_method(:with_lock) { |*| raise "a diff must not hold a write lock" }
    Document::Diff.define_singleton_method(:unified, calculate)
    snapshot = @document.context

    assert_equal target.id, snapshot.fetch("version_id")
    assert_includes snapshot.fetch("diff"), "+++ Trip plan (document #{@document.id}, version 2, the person's)"
    assert_includes snapshot.fetch("diff"), "+Sintra"
    assert_includes snapshot.fetch("fallback"), "Trip plan"
    assert_not_includes snapshot.fetch("fallback"), "Changed during diff"
    assert_not_includes snapshot.fetch("diff"), "Later"
  ensure
    Document::Diff.define_singleton_method(:unified, unified) if unified
    @document&.singleton_class&.remove_method(:with_lock) if @document&.singleton_methods&.include?(:with_lock)
  end

  test "context reads a new target even if current_version was cached before another editor saved" do
    assert_equal @seen, @document.current_version
    editor = @agent.documents.find(@document.id)
    target = editor.revise("Sintra\n", by: "person")

    assert_equal target.id, @document.context.fetch("version_id")
  end

  test "acknowledging a captured target leaves a later person's edit pending" do
    target = @document.revise("Sintra\n", by: "person")
    snapshot = @document.context
    editor = @agent.documents.find(@document.id)
    later = editor.revise("Coimbra\n", by: "person")

    @document.seen!(version: snapshot.fetch("version_id"))

    assert_equal target.id, @document.reload.seen_version_id
    assert @document.changed_since_seen?
    assert_equal [ @document ], @agent.documents.changed_since_seen
    pending = @document.context
    assert_equal [ target.id, later.id ], pending.values_at("from_version_id", "version_id")
    assert_includes pending.fetch("diff"), "-Sintra"
    assert_includes pending.fetch("diff"), "+Coimbra"
  end

  test "a stale acknowledgment never regresses a newer seen pointer" do
    target = @document.revise("Sintra\n", by: "person")
    editor = @agent.documents.find(@document.id)
    later = editor.revise("Coimbra\n", by: "person")
    editor.seen!(version: later)

    @document.seen!(version: target)
    @document.seen!(version: target.id)

    assert_equal later.id, @document.reload.seen_version_id
    assert_not @document.changed_since_seen?
  end

  test "acknowledgments resolve versions through their document" do
    other = @agent.documents.create!(title: "Other")
    foreign = other.revise("Other words", by: "person")

    assert_raises(ActiveRecord::RecordNotFound) { @document.seen!(version: foreign) }
    assert_raises(ActiveRecord::RecordNotFound) { @document.seen!(version: foreign.id) }
    assert_equal @seen.id, @document.reload.seen_version_id
  end

  test "full diffs and mandatory pointers obey exact UTF-16 boundaries including emoji" do
    @document.update!(title: "Trip 🌍")
    @document.revise("🌍" * 100, by: "person")
    snapshot = @document.context
    full = Document.changes_for_agent([ snapshot ], room: 10_000)
    full_size = Conversation.utf16_length(full)
    minimal = full.sub(snapshot.fetch("diff"), snapshot.fetch("fallback"))
    minimal_size = Conversation.utf16_length(minimal)

    assert_operator full_size, :>, full.length
    assert_operator minimal_size, :>, minimal.length
    assert_equal full, Document.changes_for_agent([ snapshot ], room: full_size)
    assert_equal minimal, Document.changes_for_agent([ snapshot ], room: full_size - 1)
    assert_equal minimal, Document.changes_for_agent([ @document ], room: minimal_size)
    error = assert_raises(Conversation::Submission::TooLarge) do
      Document.changes_for_agent([ snapshot ], room: minimal_size - 1)
    end
    assert_equal Conversation::Submission::TooLarge.new.message, error.message
  end

  test "all later pointers are reserved before any earlier diff gets spare room" do
    @document.revise("Sintra 🌍\n" * 20, by: "person")
    first = @document.context
    snapshots = [ first ] + (2..30).map do |id|
      first.merge("document_id" => id, "diff" => "x" * 10_000,
        "fallback" => "Document #{id} changed; call read_document with document_id #{id}.")
    end
    minimal_snapshots = snapshots.map { it.merge("diff" => "") }
    minimal = Document.changes_for_agent(minimal_snapshots, room: 10_000)
    room = Conversation.utf16_length(minimal)

    note = Document.changes_for_agent(snapshots, room: room)

    assert_equal minimal, note
    assert_equal room, Conversation.utf16_length(note)
    snapshots.each { assert_includes note, it.fetch("fallback") }
    assert_raises(Conversation::Submission::TooLarge) do
      Document.changes_for_agent(snapshots, room: room - 1)
    end
    assert_raises(Conversation::Submission::TooLarge) do
      Document.changes_for_agent(snapshots, room: 1_000)
    end
  end

  test "returning to the seen words gives a truthful saved-again note" do
    @document.revise("Sintra\n", by: "person")
    @document.revise(@seen.body, by: "person")
    snapshot = @document.context

    assert_equal "", snapshot.fetch("diff")
    assert_equal "Trip plan (document #{@document.id}): saved again with no change to its lines.", snapshot.fetch("fallback")
    note = Document.changes_for_agent([ snapshot ], room: 1_000)
    assert_includes note, snapshot.fetch("fallback")
    assert_not_includes note, "changed too much"
    assert_equal note, Document.changes_for_agent([ snapshot ], room: Conversation.utf16_length(note))
  end
end
