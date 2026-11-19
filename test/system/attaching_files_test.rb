require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# A person attaches a file that is not a picture in the thread, in a real
# browser against Falcon. The sidecar is stubbed at Rails' HTTP client
# (WebMock): it says where it saved the file and hands back the person's
# message as it recorded it.
class AttachingFilesTest < ApplicationSystemTestCase
  include AgentTestHelper

  FOLDER = "/home/agent/files/5e6f7a8b9c"

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
    @conversation = create_conversation(@agent)
    @agent.create_computer!(provider: "sprites", state: "on")
    @entries, @sent = [], nil
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "waiting", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return { { body: { entries: @entries, cursor: @entries.size.nonzero?, more: false }.to_json } }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/files").to_return { |request|
      { status: 200, body: { files: JSON.parse(request.body)["files"].map { it.merge("saved" => "#{FOLDER}/#{it["name"]}") } }.to_json } }
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @sent = JSON.parse(request.body)
      @entries = [ { id: "1", entryId: 1, role: "user", content: @sent["content"], requestId: @sent["requestId"], author: { userId: @agent.user_id.to_s } } ]
      { status: 202, body: { id: 3 }.to_json } }
    @docx = Rails.root.join("tmp/Q3 plan #{SecureRandom.hex(4)}.docx").tap { it.binwrite("PK\x03\x04".b + Random.new(3).bytes(12_000)) }
  end

  teardown do
    @docx&.delete
    @big&.delete
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the paperclip takes a .docx: a chip before sending, the path in what the agent reads, and a chip that downloads it after" do
    visit conversation_path(@conversation)
    assert_selector "label.composer__attach[title='Attach pictures or files']"

    find("#composer input[type=file][name='images[]']", visible: false).attach_file(@docx.to_s)
    within(".composer__attachments .ui-files__file") do
      assert_selector ".ui-files__name", exact_text: @docx.basename.to_s
      assert_selector ".ui-files__size", exact_text: "11.7 KB"
    end
    click_on "Remove #{@docx.basename}"
    assert_no_selector ".composer__attachments .ui-files__file"

    find("#composer input[type=file][name='images[]']", visible: false).attach_file(@docx.to_s)
    find("#composer textarea").send_keys("Notes from today", :enter)

    assert_selector "#messages [data-role=user] .ui-files a.ui-files__file[href*='/rails/active_storage/blobs/']", text: @docx.basename.to_s
    assert_selector "#messages [data-role=user] .ui-files__size", text: "11.7 KB"
    assert_selector "#messages [data-role=user] .ui-bubble__text", exact_text: "Notes from today"
    assert_no_selector ".composer__attachments .ui-files__file"
    assert_match "- #{@docx.basename} (application/vnd.openxmlformats-officedocument.wordprocessingml.document, 11.7 KB): saved at #{FOLDER}/#{@docx.basename}",
      @sent["content"]
  end

  test "a file over 25 MB is refused at once, in plain words, and nothing is attached" do
    @big = Rails.root.join("tmp/scan-#{SecureRandom.hex(4)}.pdf").tap { File.open(it, "wb") { |file| file.truncate(Conversation::FILE_BYTES + 1) } }
    visit conversation_path(@conversation)

    find("#composer input[type=file][name='images[]']", visible: false).attach_file(@big.to_s)

    assert_selector "#composer_error", text: "#{@big.basename} is over 25 MB: each file must be 25 MB or smaller."
    assert_no_selector ".composer__attachments .ui-files__file"
    assert_nil @sent
  end
end
