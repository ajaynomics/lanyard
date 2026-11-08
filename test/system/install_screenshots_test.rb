require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"

# The pictures a browser's install sheet shows (pwa/manifest.json.erb), taken
# here from made-up agents so they show the app as it is. Every run checks the
# manifest's pictures exist at their sizes; SCREENSHOTS=1 takes them again.
class InstallScreenshotsTest < ApplicationSystemTestCase
  include AgentTestHelper

  SHOTS = { "wide" => [ 1280, 800 ], "narrow" => [ 390, 844 ] }.freeze

  setup do
    install_sidecar_settings
    mock_ajent_auth
    visit "/auth/ajent/callback"
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test's own sign-in
    @agent.update!(name: "Dinner planner")
    @conversation = create_conversation(@agent)
    researcher = @agent.user.agents.create!(name: "Researcher", instructions: "Research.", model: @agent.model)
    create_conversation(researcher, durable_id: "13").messages.create!(entry_key: "1", entry_id: 1, role: "assistant",
      content: "Found three papers on tide pools; the second is the one you want.", created_at: 1.day.ago)
    start = 3.hours.ago
    [ [ "user", "Can you find a dinner spot for Friday?", start ],
      [ "user", "Somewhere near the office, for four.", start + 10.seconds ],
      [ "assistant", "Two places near the office have a table for four on Friday:\n\n1. **Salt & Pine** at 7:30\n2. **Harbour Room** at 8:00", start + 1.minute ],
      [ "assistant", "Shall I book the first?", start + 70.seconds ],
      [ "user", "Yes please, Salt & Pine.", start + 2.hours ],
      [ "assistant", "Booked: Salt & Pine, Friday at 7:30, for four. The confirmation is in your email.", start + 2.hours + 1.minute ] ].each.with_index(1) do |(role, content, at), index|
      @conversation.messages.create!(entry_key: index.to_s, entry_id: index, role:, content:, created_at: at)
    end
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the install sheet's pictures are the app at its sizes" do
    SHOTS.each do |form_factor, (width, height)|
      path = Rails.public_path.join("screenshots/#{form_factor}.png")
      take(path, width, height) if ENV["SCREENSHOTS"]
      assert_equal [ width, height ], path.binread.byteslice(16, 8).unpack("N2"), "#{path} is not #{width}x#{height}; run SCREENSHOTS=1 bin/rails test #{__FILE__}"
    end
  end

  private
    def take(path, width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height:, deviceScaleFactor: 1, mobile: width < 600)
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
      visit conversation_path(@conversation)
      assert_text "Booked: Salt & Pine"
      assert_no_selector ".flash, [role=alert]"
      sleep 0.5 # the view transition and the header's shadow settle
      page.save_screenshot(path.to_s)
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    end
end
