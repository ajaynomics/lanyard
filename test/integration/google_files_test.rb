require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A file a Google tool found (docs/connectors.md): the call answers with what
# the file is and says there is one; the sidecar then fetches its bytes once,
# soon after, to save on the agent's computer. The bytes are never in the
# ledger, and only Google's file tools can be fetched this way.
class GoogleFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me".freeze
  DRIVE = "https://www.googleapis.com/drive/v3".freeze
  PDF = "%PDF-1.7\n\xE2\xE3\xCF\xD3 binary".b.freeze

  setup do
    install_sidecar_settings
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    stub_request(:get, "#{GMAIL}/messages/m1").with(query: { format: "full" }).to_return(json(id: "m1", payload: {
      mimeType: "multipart/mixed", parts: [ { partId: "0", mimeType: "text/plain", filename: "", body: { data: Base64.urlsafe_encode64("Hi") } },
        { partId: "1", mimeType: "application/pdf", filename: "../Plan\u0000.pdf", body: { attachmentId: "ANGjdJ-changes-each-read", size: PDF.bytesize } } ] }))
    @bytes = stub_request(:get, "#{GMAIL}/messages/m1/attachments/ANGjdJ-changes-each-read").to_return(json(size: PDF.bytesize, data: Base64.urlsafe_encode64(PDF)))
  end
  teardown { remove_sidecar_settings }

  test "an attachment is named and sized in the ledger, and its bytes go to the sidecar once asked, never into the ledger" do
    connector("gmail")
    done = run_call("mcp__gmail__get_attachment", { "message_id" => "m1", "attachment_id" => "1" })

    assert_equal true, done["file"]
    assert_equal({ "name" => "Plan.pdf", "type" => "application/pdf", "size" => PDF.bytesize }, done.dig("result", "file"))
    assert_not_requested @bytes

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_not_includes @conversation.invocations.sole.attributes.to_json, Base64.urlsafe_encode64(PDF)
  end

  test "a file can be fetched only soon after its call, only with RAILS_TOKEN, and only from a Google file tool" do
    connector("gmail")
    run_call("mcp__gmail__get_attachment", { "message_id" => "m1", "attachment_id" => "1" })

    post "/agent/files", params: fetch, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
    travel Invocation::FILE_WITHIN + 1.minute do
      post "/agent/files", params: fetch, headers: rails_bearer, as: :json
      assert_response :gone
    end

    stub_request(:get, "#{GMAIL}/messages/m1").with(query: { format: "full" }).to_return(json(id: "m1", payload: {}))
    listed = run_call("mcp__gmail__get_message", { "message_id" => "m1" }, call_id: "toolu_2")
    assert_nil listed["file"]
    post "/agent/files", params: fetch(call_id: "toolu_2"), headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "a Drive PDF is fetched as bytes, as it is" do
    connector("drive")
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: McpServer::Google::Drive::FIELDS))
      .to_return(json(id: "f1", name: "Report.pdf", mimeType: "application/pdf", size: PDF.bytesize.to_s))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(fields: "size")).to_return(json(size: PDF.bytesize.to_s))
    stub_request(:get, "#{DRIVE}/files/f1").with(query: hash_including(alt: "media")).to_return(body: PDF)

    done = run_call("mcp__drive__read_file", { "file_id" => "f1" })
    assert_equal true, done["file"]
    assert_equal "Report.pdf", done.dig("result", "file", "name")

    post "/agent/files", params: fetch, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b
  end

  private
    def run_call(tool, arguments, call_id: "toolu_1")
      with_google_app do
        invoke(tool, arguments, call_id)
        perform_enqueued_jobs(only: InvocationCallJob)
        invoke(tool, arguments, call_id)
      end
    end

    def invoke(tool, arguments, call_id)
      @last = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id)
      post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      response.parsed_body
    end

    def fetch(call_id: "toolu_1")
      { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: call_id }
    end

    def connector(kind)
      with_google_app do
        @alice.mcp_servers.create!(name: kind, **McpServer.gallery_attributes(kind), refreshed_at: Time.current,
          oauth_tokens: { "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => 1.hour.from_now.to_i })
      end
    end

    def with_google_app
      x = Rails.application.config.x
      saved, x.connectors = x.connectors, x.connectors.to_h.deep_merge(apps: { google: { client_id: "instance-id", client_secret: "instance-secret" } })
      yield
    ensure
      x.connectors = saved
    end

    def json(body) = { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
end
