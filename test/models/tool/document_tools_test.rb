require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The canvas's tools, through the ledger as the sidecar calls them. The
# agent's own scratch space: nothing asks the person first.
class Tool::DocumentToolsTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @maya = create_user(name: "Maya")
    @agent = @maya.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "every agent has them, and none asks first" do
    names = @conversation.definition[:tools].pluck(:name)
    %w[ write_document edit_document read_document ].each do |name|
      assert_includes names, name
      assert_nil @conversation.tool(name).asks
    end
  end

  test "switched off for one agent, they are gone from its next message" do
    @agent.switch_tool("write_document", false)

    assert_not_includes @agent.reload.conversation.definition[:tools].pluck(:name), "write_document"
    assert_includes @agent.conversation.definition[:tools].pluck(:name), "edit_document"
  end

  test "write_document makes a document, and writing the same title again replaces its body" do
    written = call("write_document", { "title" => "Packing list", "body" => "- passport\n- charger\n" })
    assert_equal "done", written[:status]
    document = @agent.documents.sole
    assert_equal({ document_id: document.id, title: "Packing list", kind: "markdown", version: 1 }, written[:result])

    call("write_document", { "title" => "Packing list", "body" => "puts 1", "kind" => "code", "language" => "ruby" }, call_id: "c2")
    assert_equal [ "puts 1", "code", "ruby", 2 ], document.reload.then { [ it.body, it.kind, it.language, it.number ] }

    call("write_document", { "title" => "Packing", "body" => "puts 1", "document_id" => document.id }, call_id: "c3")
    assert_equal [ "Packing", 2 ], [ document.reload.title, document.number ]
  end

  test "edit_document applies targeted edits, or refuses saying which find failed" do
    document = @agent.documents.create!(title: "Packing list").tap { it.revise("- passport\n- charger\n- charger cable\n", by: "agent") }

    edited = call("edit_document", { "document_id" => document.id, "edits" => [ { "find" => "passport", "replace" => "passports" } ] })
    assert_equal 2, edited[:result][:version]
    assert_equal "- passports\n- charger\n- charger cable\n", document.reload.body

    refused = call("edit_document", { "document_id" => document.id, "edits" => [ { "find" => "charger", "replace" => "adapter" } ] }, call_id: "c2")
    assert refused[:isError]
    assert_equal "No edits applied. \"charger\" is in Packing list 2 times. Include more of the text around it so it matches once.", refused[:result][:error]

    invalid = call("edit_document", { "document_id" => document.id, "edits" => [ { "find" => "", "replace" => "x" } ] }, call_id: "c3")
    assert invalid[:isError]
    assert_match(/Invalid arguments/, invalid[:result][:error])
  end

  test "read_document lists the documents, reads one with or without line numbers, and has then seen it" do
    document = @agent.documents.create!(title: "Notes").tap { it.revise("one\ntwo\n", by: "agent") }
    document.revise("one\ntwo\nthree\n", by: "person")

    listed = call("read_document", {})[:result][:documents]
    assert_equal [ [ document.id, "Notes", 2 ] ], listed.map { it.values_at(:document_id, :title, :version) }
    assert document.reload.changed_since_seen?, "a list is not a read"

    read = call("read_document", { "document_id" => document.id, "line_numbers" => true }, call_id: "c2")[:result]
    assert_equal "1\tone\n2\ttwo\n3\tthree\n", read[:body]
    assert_not document.reload.changed_since_seen?
  end

  test "another agent's document is not found" do
    other = create_user(name: "Robin").agents.sole.documents.create!(title: "Secret").tap { it.revise("x", by: "agent") }

    outcome = call("read_document", { "document_id" => other.id })

    assert outcome[:isError]
    assert_empty @agent.documents
  end

  test "list_documents and delete_document ask nobody first, and are looked up, so no agent declares more tools" do
    definition = @conversation.definition
    %w[ list_documents delete_document ].each do |name|
      assert_nil @conversation.tool(name).asks, name
      assert_includes definition[:lookup].pluck(:name), name
      assert_not_includes definition[:tools].pluck(:name), name
    end
    assert_equal %w[ ask_person current_time edit_document find_tools forget_note list_notes read_document remember_note use_tool write_document ],
      definition[:tools].pluck(:name).sort, "what every agent declares is as it was"
  end

  test "list_documents lists the agent's own documents newest first, with their size, a title filter and a limit" do
    plan = @agent.documents.create!(title: "Trip plan").tap { it.revise("Day 1", by: "agent") }
    packing = @agent.documents.create!(title: "Packing list").tap { it.revise("- hat\n- passport", by: "agent") }
    @agent.documents.create!(title: "Old trip notes").tap { it.revise("x", by: "agent") }.update_columns(updated_at: 1.day.ago)
    plan.update_columns(updated_at: 1.hour.ago)
    create_user(name: "Robin").agents.sole.documents.create!(title: "Robin's trip").tap { it.revise("y", by: "agent") }

    listed = call("list_documents", {})[:result][:documents]
    assert_equal [ "Packing list", "Trip plan", "Old trip notes" ], listed.pluck(:title)
    assert_equal({ document_id: packing.id, title: "Packing list", updated_at: packing.reload.updated_at.iso8601, size: 16 }, listed.first)

    assert_equal [ "Trip plan", "Old trip notes" ], call("list_documents", { "title" => "TRIP" }, call_id: "c2")[:result][:documents].pluck(:title)
    assert_equal [ "Packing list" ], call("list_documents", { "limit" => 1 }, call_id: "c3")[:result][:documents].pluck(:title)
    assert_equal [], call("list_documents", { "title" => "100%_" }, call_id: "c4")[:result][:documents]
  end

  test "delete_document deletes softly: gone from list, read and edit, and a person may restore it" do
    document = @agent.documents.create!(title: "Packing list").tap { it.revise("- hat", by: "agent") }

    deleted = call("delete_document", { "document_id" => document.id })
    assert_equal "done", deleted[:status], deleted.to_json
    assert_equal [ document.id, "Packing list" ], deleted[:result].values_at(:document_id, :title)
    assert_equal [ "agent", (document.reload.deleted_at + 30.days).iso8601 ], [ document.deleted_by, deleted[:result][:restorable_until] ]

    assert_empty call("list_documents", {}, call_id: "c2")[:result][:documents]
    assert_empty call("read_document", {}, call_id: "c3")[:result][:documents]
    assert call("read_document", { "document_id" => document.id }, call_id: "c4")[:isError]
    assert call("edit_document", { "document_id" => document.id, "edits" => [ { "find" => "hat", "replace" => "cap" } ] }, call_id: "c5")[:isError]
    assert call("delete_document", { "document_id" => document.id }, call_id: "c6")[:isError], "deleted once"
    assert_equal "- hat", document.body

    written = call("write_document", { "title" => "Packing list", "body" => "- cap" }, call_id: "c7")[:result]
    assert_not_equal document.id, written[:document_id], "its title is free for a new one"

    document.undelete
    assert_equal [ "Packing list (2)", "- hat", nil ], [ document.title, document.body, document.deleted_at ]
    assert_equal [ "Packing list", "Packing list (2)" ], call("list_documents", {}, call_id: "c8")[:result][:documents].pluck(:title).sort
  end

  test "an agent cannot delete a document outside its reach" do
    other = create_user(name: "Robin").agents.sole.documents.create!(title: "Secret").tap { it.revise("x", by: "agent") }

    outcome = call("delete_document", { "document_id" => other.id })

    assert outcome[:isError]
    assert_nil other.reload.deleted_at
  end

  private
    def call(tool, arguments, call_id: "c1")
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
