require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/bluebubbles_test_helper"

# A photo from an iMessage chat (docs/imessage.md), fetched by the sidecar the
# way a Gmail attachment is (test/integration/google_files_test.rb): the bytes
# come from the Mac when asked, and a Mac that won't give them is a 502 that
# names no address or password.
class ImessageFilesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include BluebubblesTestHelper
  include ActiveJob::TestHelper

  JPEG = "\xFF\xD8\xFF\xE0 binary".b.freeze

  setup do
    install_sidecar_settings
    install_bluebubbles_settings
    @agent = create_user(name: "Alice").agents.sole
    @agent.update!(tool_names: @agent.tool_names | %w[ imessage_attachment ])
    @conversation = create_conversation(@agent)
  end

  teardown do
    remove_bluebubbles_settings
    remove_sidecar_settings
  end

  test "the sidecar gets the photo's bytes, and an error from the Mac without its address" do
    stub_bluebubbles_attachment(JPEG, name: "IMG_0002.JPG", type: "image/jpeg")
    assert_equal true, run_call("toolu_1")["file"]
    post "/agent/files", params: fetch("toolu_1"), headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal JPEG, response.body.b
    assert_equal "no-store", response.headers["Cache-Control"]

    run_call("toolu_2")
    stub_request(:get, "#{BLUEBUBBLES}/api/v1/attachment/#{PHOTO}/download").with(query: hash_including({})).to_return(status: 500)
    post "/agent/files", params: fetch("toolu_2"), headers: rails_bearer, as: :json
    assert_response :bad_gateway
    assert_equal({ "error" => "bluebubbles", "message" => "BlueBubbles answered HTTP 500" }, response.parsed_body)
  end

  test "a 30 MB attachment is saved, and reaches the sidecar whole from a file on disk" do
    big = Random.new(2).bytes(30.megabytes)
    stub_bluebubbles_attachment(big, name: "Package.zip", type: "application/zip")
    assert_equal true, run_call("toolu_1")["file"]
    post "/agent/files", params: fetch("toolu_1"), headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal big.bytesize.to_s, response.headers["Content-Length"]
    assert_equal Digest::SHA256.hexdigest(big), Digest::SHA256.hexdigest(response.body.b)
  end

  private
    def run_call(call_id)
      arguments = { "attachment" => PHOTO }
      2.times do |time|
        perform_enqueued_jobs(only: InvocationCallJob) if time == 1
        @last = invocation_payload(@conversation, tool: "imessage_attachment", arguments: arguments, call_id: call_id)
        post "/agent/invocations", params: @last, headers: rails_bearer, as: :json
      end
      response.parsed_body
    end

    def fetch(call_id) = { actorId: @last[:actorId], workspaceId: @last[:workspaceId], conversationId: @last[:conversationId], taskId: @last[:taskId], callId: call_id }
end
