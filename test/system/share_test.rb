require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# Something shared from another app, in a browser: Share with… lists the
# agents, and the chosen one's composer opens with the words in the box and
# the picture attached through the composer's own path, unsent.
class ShareTest < ApplicationSystemTestCase
  include AgentTestHelper

  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Robin")
    @robin = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @iris = name_agent(@robin.agents.sole, "Iris")
    @conversation = create_conversation(@iris)
    @robin.start_agent("Sam's errands")
    stub_request(:get, "#{SIDECAR}/v1/conversations/12").with(query: hash_including({}))
      .to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, "#{SIDECAR}/v1/conversations/12/entries").with(query: hash_including({}))
      .to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    @share = @robin.shares.create!(text: "Sintra\nhttps://travel.example.com/sintra")
    @share.files.attach(io: StringIO.new(PNG), filename: "sintra.png", content_type: "image/png")
  end
  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "Share with… opens the chosen agent's composer with the words and the picture, and sends nothing" do
    submissions = stub_request(:post, %r{#{SIDECAR}/v1/conversations/\d+/submissions})
    visit share_path(@share)
    assert_selector "h1", text: "Share with…"
    assert_selector ".share__agent", text: "Sam's errands"
    find(".share__agent", text: "Iris").click

    assert_current_path conversation_path(@conversation, share: @share)
    assert_equal "Sintra\nhttps://travel.example.com/sintra", find("#composer textarea").value
    assert_selector ".composer__thumb img[alt='sintra.png']", wait: 15
    assert_equal 1, page.evaluate_script("document.querySelector('#composer input[type=file]').files.length")
    assert_not_requested submissions
  end
end
