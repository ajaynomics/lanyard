require "test_helper"
require "action_mailbox/test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# A file someone mails an agent (ReceivedMail::Files, docs/email.md,
# "Attachments"): saved on its computer as a file a tool finds is
# (Invocation#hold_file, agent/files.mjs), and listed in the message it reads,
# with its name, type, size and where it was saved, or why it wasn't. WebMock
# stands in for the sidecar, which fetches each file back from POST
# /agent/files, as it does here.
class MailAttachmentsTest < ActionDispatch::IntegrationTest
  include ActionMailbox::TestHelper
  include AgentTestHelper
  include EmailTestHelper

  PDF = "%PDF-1.4\n".b + Random.new(7).bytes(40_000) + "\n%%EOF\n".b
  JPEG = "\xFF\xD8\xFF\xE0".b + Random.new(8).bytes(3_000)
  LOGO = "\x89PNG\r\n\x1A\n".b + Random.new(9).bytes(500)
  FOLDER = "/home/agent/files/0a1b2c3d4e"

  setup do
    install_sidecar_settings
    install_email_settings
    @agent = create_user(name: "Robin").agents.sole
    Agent.where(id: @agent.id).update_all(name: "Desk", email_name: "desk")
    @agent.reload
    @submissions, @saves = [], []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "c-thread" }.to_json)
    stub_request(:post, "#{SIDECAR}/v1/conversations/c-thread/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    # The sidecar saves each file under its own name in the call's folder.
    stub_request(:post, "#{SIDECAR}/v1/conversations/c-thread/files").to_return { |request|
      @saves << JSON.parse(request.body)
      { status: 200, body: { files: @saves.last["files"].map { it.merge("saved" => "#{FOLDER}/#{it["name"]}") } }.to_json } }
  end

  teardown do
    remove_email_settings
    remove_sidecar_settings
  end

  test "a PDF attached to mail with a plain and an HTML body is saved on the agent's computer and listed in what it reads" do
    @agent.create_computer!(provider: "sprites", state: "on")
    receive_inbound_email_from_source(statement.to_s)

    content = words(@submissions.sole["content"])
    assert_match "See the extract attached.", content
    assert_match "Attachments:\n- Extract.pdf (application/pdf, 39.1 KB): saved at #{FOLDER}/Extract.pdf", content

    save = @saves.sole
    assert_equal @agent.computer.descriptor.as_json, save["computer"]
    assert_equal [ { "name" => "Extract.pdf", "type" => "application/pdf", "size" => PDF.bytesize, "held" => 0 } ], save["files"]
    post "/agent/files", params: fetch(save, index: 0), headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PDF, response.body.b, "the sidecar reads the file's bytes back, whole"
    assert_not_includes @agent.conversation.invocations.sole.attributes.to_json, Base64.strict_encode64(PDF[0, 300]), "the bytes are never in the ledger"
  end

  test "an attached photo and an inline image named only by its Content-ID are both saved and listed" do
    @agent.create_computer!(provider: "sprites", state: "on")
    mail = Mail.new(from: "Kim Example <kim@example.com>", to: "desk@agents.example", subject: "Photos", message_id: "<photos@example.com>",
      content_type: "multipart/mixed")
    mail.add_part Mail::Part.new(content_type: "text/html; charset=UTF-8", body: %(<p>Here is the room <img src="cid:logo@example.com"></p>))
    mail.attachments["room.jpg"] = { mime_type: "image/jpeg", content: JPEG }
    # A picture the body shows, with no name of its own.
    mail.add_part Mail::Part.new(content_type: "image/png", content_transfer_encoding: "base64", content_disposition: "inline",
      content_id: "<logo@example.com>", body: Base64.encode64(LOGO))
    receive_inbound_email_from_source(mail.to_s)

    content = words(@submissions.sole["content"])
    assert_match "Here is the room", content
    assert_match "- room.jpg (image/jpeg, 2.93 KB): saved at #{FOLDER}/room.jpg", content
    assert_match "- logo.png (image/png, 508 Bytes): saved at #{FOLDER}/logo.png", content
    save = @saves.sole
    assert_equal [ [ "image/jpeg", "room.jpg" ], [ "image/png", "logo.png" ] ], save["files"].map { it.values_at("type", "name") }.sort
    { "room.jpg" => JPEG, "logo.png" => LOGO }.each do |name, bytes|
      post "/agent/files", params: fetch(save, index: save["files"].find { it["name"] == name }["held"]), headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal bytes, response.body.b, name
    end
  end

  test "an agent with no computer is told each file was not saved, and why" do
    receive_inbound_email_from_source(statement.to_s)

    content = words(@submissions.sole["content"])
    assert_match "- Extract.pdf (application/pdf, 39.1 KB): not saved: you have no computer here to save it on.", content
    assert_empty @saves
    assert_empty @agent.conversation.invocations
  end

  test "a file the computer would not take is listed with the computer's reason; mail read again keeps what was said" do
    @agent.create_computer!(provider: "sprites", state: "on")
    stub_request(:post, "#{SIDECAR}/v1/conversations/c-thread/files").to_return { |request|
      @saves << JSON.parse(request.body)
      { status: 200, body: { files: @saves.last["files"].map { it.merge("saved" => nil, "note" => "The file needs 0.1 MB and the computer has 0.0 MB free, so it was not saved.") } }.to_json } }
    receive_inbound_email_from_source(statement.to_s)
    receive_inbound_email_from_source(statement.to_s)

    assert_match "- Extract.pdf (application/pdf, 39.1 KB): not saved: The file needs 0.1 MB and the computer has 0.0 MB free, so it was not saved.",
      words(@submissions.first["content"])
    assert_equal 1, @saves.size, "the same message again is not saved twice"
  end

  test "a computer the sidecar cannot reach is said plainly, and the mail still arrives" do
    @agent.create_computer!(provider: "sprites", state: "on")
    stub_request(:post, "#{SIDECAR}/v1/conversations/c-thread/files").to_return(status: 503, body: { error: "computer_held" }.to_json)
    receive_inbound_email_from_source(statement.to_s)

    assert_match "- Extract.pdf (application/pdf, 39.1 KB): not saved: your computer is held while it is rebuilt.", words(@submissions.sole["content"])
  end

  private
    # multipart/mixed { multipart/alternative { text/plain, text/html }, application/pdf }
    def statement
      alternative = Mail::Part.new(content_type: "multipart/alternative")
      alternative.add_part Mail::Part.new(content_type: "text/plain; charset=UTF-8", body: "See the extract attached.")
      alternative.add_part Mail::Part.new(content_type: "text/html; charset=UTF-8", body: "<p>See the extract attached.</p>")
      Mail.new(from: "Sam Example <sam@example.com>", to: "desk@agents.example", subject: "Statement", message_id: "<statement@example.com>",
        content_type: "multipart/mixed").tap do |mail|
        mail.add_part alternative
        mail.attachments["Extract.pdf"] = { mime_type: "application/pdf", content: PDF }
      end
    end

    def fetch(save, index:)
      { actorId: save["actorId"], workspaceId: save["workspaceId"], conversationId: "c-thread", taskId: save["taskId"], callId: save["callId"], index: index }
    end
end
