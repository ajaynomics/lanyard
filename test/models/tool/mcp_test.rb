require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/mcp_test_helper"

class Tool::McpTest < ActiveSupport::TestCase
  include AgentTestHelper
  include McpTestHelper

  PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP2sAAAAASUVORK5CYII=".freeze

  setup do
    @agent = create_user.agents.sole
  end

  test "a server's tool joins the definition under a name the sidecar accepts" do
    make_core(@agent, create_mcp_server(@agent, tools: [ mcp_tool("Get-Page.v2", properties: { id: { type: "string" } }), mcp_tool("x" * 80) ]))
    declarations = @agent.conversation.definition[:tools].select { it[:name].start_with?("mcp__") }

    assert_equal "mcp__wiki__get_page_v2", declarations.first[:name]
    assert_equal({ "type" => "object", "properties" => { "id" => { "type" => "string" } }, "required" => [] }, declarations.first[:parameters])
    assert_equal 64, declarations.last[:name].length
    declarations.each { assert_match(/\A[a-z][a-z0-9_]{0,63}\z/, it[:name]) }
    assert_equal "Get-Page.v2", @agent.conversation.tool("mcp__wiki__get_page_v2").listing["name"]
  end

  test "only a tool the server marks read-only runs without asking" do
    create_mcp_server(@agent, tools: [ mcp_tool("read", annotations: { readOnlyHint: true }),
      mcp_tool("write", annotations: { readOnlyHint: false }), mcp_tool("unmarked") ])

    assert_nil @agent.conversation.tool("mcp__wiki__read").asks
    assert_equal :approval, @agent.conversation.tool("mcp__wiki__write").asks
    assert_equal :approval, @agent.conversation.tool("mcp__wiki__unmarked").asks
    assert_equal :external, @agent.conversation.tool("mcp__wiki__read").effect
  end

  test "arguments are checked against the server's schema" do
    create_mcp_server(@agent, tools: [ mcp_tool("search", properties: { query: { type: "string" } }, required: %w[ query ]) ])
    tool = @agent.conversation.tool("mcp__wiki__search")

    assert_empty tool.errors_for("query" => "rails")
    assert_not_empty tool.errors_for("query" => 1)
    assert_not_empty tool.errors_for({})
  end

  test "a call returns text and images, or structured content and images" do
    create_mcp_server(@agent, tools: [ mcp_tool("search"), mcp_tool("count") ])
    image = { "type" => "image", "mimeType" => "image/png", "data" => PNG }
    stub_mcp_server(calls: {
      "search" => ->(arguments) { { content: [ { type: "text", text: "found #{arguments['q']}" }, image ] } },
      "count" => ->(_) { { content: [ { type: "text", text: "{\"n\":2}" }, image ], structuredContent: { n: 2 } } }
    })
    invocation = Invocation.new(conversation: create_conversation(@agent))

    assert_equal([ { text: "found it" }, [ image ] ], @agent.conversation.tool("mcp__wiki__search").new(invocation).call(q: "it"))
    assert_equal([ { "n" => 2 }, [ image ] ], @agent.conversation.tool("mcp__wiki__count").new(invocation).call)
  end

  test "pictures at the byte limit pass; oversized images and other binaries stay named" do
    create_mcp_server(@agent, tools: [ mcp_tool("read") ])
    bytes = Base64.strict_decode64(PNG).ljust(Conversation::IMAGE_BYTES, "\0")
    valid = Base64.strict_encode64(bytes)
    stub_mcp_server(calls: { "read" => ->(_) { { content: [
      { type: "image", mimeType: "image/png", data: valid },
      { type: "image", mimeType: "image/png", data: Base64.strict_encode64(bytes + "\0") },
      { type: "audio", mimeType: "audio/wav", data: "AAAA" }
    ] } } })
    invocation = Invocation.new(conversation: create_conversation(@agent))

    text, images = @agent.conversation.tool("mcp__wiki__read").new(invocation).call
    assert_equal({ text: "[image image/png]\n\n[audio audio/wav]" }, text)
    assert_equal Digest::SHA256.hexdigest(valid), Digest::SHA256.hexdigest(images.sole.fetch("data"))
  end

  test "a tool's own error and an unreachable server are refusals the model reads" do
    create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    invocation = Invocation.new(conversation: create_conversation(@agent))
    stub_mcp_server(calls: { "search" => ->(_) { { content: [ { type: "text", text: "rate limited" } ], isError: true } } })

    error = assert_raises(Tool::Refusal) { @agent.conversation.tool("mcp__wiki__search").new(invocation).call }
    assert_equal "mcp__wiki__search failed: rate limited", error.message

    stub_request(:post, MCP_URL).to_return(status: 503)
    error = assert_raises(Tool::Refusal) { @agent.conversation.tool("mcp__wiki__search").new(invocation).call }
    assert_match(/Could not reach wiki/, error.message)
  end

  test "a call refused for sign-in tells the model to ask the person, not to retry" do
    create_mcp_server(@agent, tools: [ mcp_tool("search") ])
    invocation = Invocation.new(conversation: create_conversation(@agent))
    stub_request(:post, MCP_URL).to_return(status: 401)

    error = assert_raises(Tool::Refusal) { @agent.conversation.tool("mcp__wiki__search").new(invocation).call }
    assert_equal "wiki needs the person to sign in again, on its Connectors page. Tell them; don't retry until they have.", error.message
  end

  # The real case: a server that answers after the limit was slow, not down,
  # and an agent told "Internal error" gives up on it.
  test "a call cut off at the limit says it timed out and the server may still be working" do
    listener = TCPServer.new("127.0.0.1", 0)
    server = serve_slowly(listener, answer_after: 2)
    create_mcp_server(@agent, tools: [ mcp_tool("search") ], url: "http://127.0.0.1:#{listener.addr[1]}/mcp")
    invocation = Invocation.new(conversation: create_conversation(@agent))

    error = stub_const(McpServer, :TIMEOUT, 1) do
      assert_raises(Tool::Refusal) { @agent.conversation.tool("mcp__wiki__search").new(invocation).call }
    end
    assert_equal "wiki timed out after 1s (the server may still be working).", error.message
    assert_no_match(/Internal error/, error.message)
  ensure
    listener&.close
    server&.kill
  end

  private
    # A real MCP server over HTTP on this machine, which shakes hands at once
    # and answers a tools/call only after `answer_after` seconds.
    def serve_slowly(listener, answer_after:)
      Thread.new do
        loop do
          connection = listener.accept
          Thread.new(connection) do |socket|
            head = +""
            head << socket.readpartial(4096) until head.include?("\r\n\r\n")
            headers, body = head.split("\r\n\r\n", 2)
            length = headers[/^content-length: *(\d+)/i, 1].to_i
            body << socket.readpartial(4096) while body.bytesize < length
            message = JSON.parse(body.presence || "{}")
            reply = case message["method"]
            when "initialize"
              { protocolVersion: MCP::Configuration::LATEST_HANDSHAKE_PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: { name: "slow", version: "1" } }
            when "tools/call"
              sleep answer_after
              { content: [ { type: "text", text: "late" } ] }
            end
            if reply
              json = { jsonrpc: "2.0", id: message["id"], result: reply }.to_json
              socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}")
            else
              socket.write("HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            end
          rescue IOError, SystemCallError
            nil
          ensure
            socket.close
          end
        end
      rescue IOError
        nil
      end
    end
end
