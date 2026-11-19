require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/mcp_test_helper"

# A file in any connector's answer (Tool::Mcp::FoundFile): an embedded
# resource's bytes, or a link to one. The app saves it on the agent's
# computer as it does a Gmail attachment, and the model reads its name, type,
# size and where it is. Every file is saved, each in its own place. A link is fetched only from the connector's own
# address, with the connector's own credentials (McpServer::LinkedFile);
# one anywhere else is refused, and nothing is fetched.
class ConnectorFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include McpTestHelper
  include ActiveJob::TestHelper

  ORIGIN = "https://mcp.example.test".freeze
  ZIP = "PK\x03\x04 zipped".b.freeze

  setup do
    install_sidecar_settings
    @agent = create_user(name: "Alice").agents.sole
    @agent.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@agent)
    make_core(@agent, create_mcp_server(@agent, name: "records", token: "records-key",
      tools: [ mcp_tool("export", annotations: { readOnlyHint: true }) ]))
  end
  teardown { remove_sidecar_settings }

  test "an embedded file is saved, and the model reads its name, type and size" do
    answer_with({ type: "text", text: "Here it is." },
      { type: "resource", resource: { uri: "file:///exports/../Report.zip", mimeType: "application/zip", blob: Base64.strict_encode64(ZIP) } })
    done = run_call

    assert_equal true, done["file"]
    assert_equal([ { "name" => "Report.zip", "type" => "application/zip", "size" => ZIP.bytesize, "held" => 0 } ], done.dig("result", "found_files"))
    assert_not_includes @conversation.invocations.sole.attributes.to_json, Base64.strict_encode64(ZIP), "the bytes are never in the ledger"

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal ZIP, response.body.b
  end

  test "a link on the connector's own address is fetched there, with its credentials, once the sidecar asks" do
    bytes = stub_request(:get, "#{ORIGIN}/files/report.zip?v=2").with(headers: { "Authorization" => "Bearer records-key" }).to_return(body: ZIP)
    answer_with({ type: "resource_link", uri: "#{ORIGIN}/files/report.zip?v=2", name: "report.zip", mimeType: "application/zip", size: ZIP.bytesize })
    done = run_call

    assert_equal true, done["file"]
    assert_equal [ "report.zip" ], done.dig("result", "found_files").pluck("name")
    assert_not_requested bytes

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal ZIP, response.body.b
    assert_requested bytes, times: 1
  end

  test "every file in an answer is saved, each fetched by its place in files" do
    stub_request(:get, "#{ORIGIN}/files/c.csv").with(headers: { "Authorization" => "Bearer records-key" }).to_return(body: "a,b\n")
    answer_with({ type: "text", text: "Three files." },
      { type: "resource", resource: { uri: "file:///Report.zip", mimeType: "application/zip", blob: Base64.strict_encode64(ZIP) } },
      { type: "resource", resource: { uri: "file:///Report.zip", mimeType: "application/zip", blob: Base64.strict_encode64("second".b) } },
      { type: "resource_link", uri: "#{ORIGIN}/files/c.csv", name: "c.csv", mimeType: "text/csv" })
    done = run_call

    assert_equal true, done["file"]
    files = done.dig("result", "found_files")
    assert_equal [ "Report.zip", "Report.zip", "c.csv" ], files.pluck("name")
    [ ZIP, "second".b, "a,b\n".b ].each_with_index do |bytes, index|
      post "/agent/files", params: fetch.merge(index: index), headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal bytes, response.body.b, "file #{index}"
    end
    post "/agent/files", params: fetch.merge(index: 3), headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "a long answer that carries a file saves both: the file, and the whole answer" do
    long = "これは長い答えの一行です。\n" * 2_000
    answer_with({ type: "text", text: long },
      { type: "resource", resource: { uri: "file:///Report.zip", mimeType: "application/zip", blob: Base64.strict_encode64(ZIP) } })
    done = run_call

    assert_equal [ "Report.zip", "export-answer.txt" ], done.dig("result", "found_files").pluck("name")
    assert long.start_with?(done.dig("result", "text"))
    post "/agent/files", params: fetch.merge(index: 1), headers: rails_bearer, as: :json
    assert_equal "#{long}\n\n[resource file:///Report.zip]", response.body.force_encoding(Encoding::UTF_8), "the whole answer, as the model reads it"
    post "/agent/files", params: fetch.merge(index: 0), headers: rails_bearer, as: :json
    assert_equal ZIP, response.body.b
  end

  test "a link anywhere else is refused with a note, and nothing is fetched" do
    [ "https://files.example.net/report.zip", "http://mcp.example.test/report.zip", "https://mcp.example.test:8443/report.zip",
      "file:///etc/passwd", "https://169.254.169.254/latest/meta-data" ].each_with_index do |link, index|
      answer_with({ type: "resource_link", uri: link, name: "report.zip", mimeType: "application/zip" })
      done = run_call("toolu_#{index}")

      assert_nil done["file"], link
      assert_nil done.dig("result", "found_files"), link
      assert_match "not at the connector's own address", done.dig("result", "note"), link
      post "/agent/files", params: fetch("toolu_#{index}"), headers: rails_bearer, as: :json
      assert_response :gone
    end
    assert_not_requested :get, /example|169\.254/
  end

  test "a file with no computer to save it on is named, not held" do
    @agent.computer.update!(state: "off")
    answer_with({ type: "resource", resource: { uri: "file:///Report.zip", mimeType: "application/zip", blob: Base64.strict_encode64(ZIP) } })
    done = run_call

    assert_nil done["file"]
    assert_equal [ "Report.zip" ], done.dig("result", "not_saved").pluck("name")
    assert_match "no computer of this app's", done.dig("result", "note")
    assert_not @conversation.invocations.sole.held_files.attached?
  end

  private
    def answer_with(*content)
      stub_mcp_server(calls: { "export" => ->(_) { { content: content } } })
    end

    def run_call(call_id = "toolu_1")
      invoke(call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      invoke(call_id)
    end

    def invoke(call_id)
      @last = invocation_payload(@conversation, tool: "mcp__records__export", arguments: {}, call_id: call_id)
      post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      response.parsed_body
    end

    def fetch(call_id = "toolu_1") = { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: call_id }
end
