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

  private
    def call(tool, arguments, call_id: "c1")
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
