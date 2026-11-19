require "test_helper"

# The phone app's Settings tab is the web's /settings (docs/native-app.md,
# "Settings"): a build reads ios_v3, starts the tab there and answers the
# page's session component when it signs out. Before, the tab was the app's
# own table, fed by /settings.json. The Swift is compiled only on the build
# Mac, so this reads the source, as NativeNoticeIsolationTest does; the Mac
# runs the unit and UI tests (BUILD.md).
class NativeSettingsTabTest < ActiveSupport::TestCase
  PHONE = Rails.root.join("ios/Phone")

  test "the app reads ios_v3 and bundles the same rules" do
    assert_match %r{"configurations/ios_v3\.json"}, PHONE.join("AppDelegate.swift").read
    assert_equal PathConfiguration.fetch("ios_v3").as_json, JSON.parse(PHONE.join("path-configuration.json").read)
  end

  test "the Settings tab starts at /settings, with no screen of the app's own" do
    assert_equal "/settings", PathConfiguration::TABS.find { it[:id] == "settings" }[:url], "as Rails serves it"
    assert_match(/AppTab\(id: "settings", [^)]*path: "\/settings"\)/, PHONE.join("AppTab.swift").read, "and as the app falls back to")
    swift = Rails.root.glob("ios/**/*.swift").map(&:read).join
    %w[ SettingsViewController SettingsRoot PhoneRequests.settings PhoneRequests.signOut native/settings ].each do |gone|
      assert_not_includes swift, gone
    end
  end

  test "the app answers the page's session component, whose signed-out starts its tabs afresh" do
    component = PHONE.join("Bridge/SessionComponent.swift").read
    assert_match(/class var name: String \{ "session" \}/, component)
    assert_match(/message\.event == "signed-out"/, component)
    assert_match(/SessionComponent\.self/, PHONE.join("Bridge/Components.swift").read)
    assert_match(/static component = "session"/, Rails.root.join("app/javascript/native/session_controller.js").read)
    assert_match(/this\.send\("signed-out"\)/, Rails.root.join("app/javascript/native/session_controller.js").read)
  end
end
