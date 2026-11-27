require "test_helper"

# The Agents list's search in the phone app answers to "native-search", not Bridge Components' "search", which builds
# already out answer unchecked (docs/native-app.md). The Swift is compiled only on the build Mac, so this reads the
# source, as NativeSettingsTabTest does.
class NativeSearchComponentTest < ActiveSupport::TestCase
  test "the app registers its own native-search, the name the page's controller talks to" do
    bridge = Rails.root.join("ios/Phone/Bridge")
    assert_match(/class var name: String \{ "native-search" \}/, bridge.join("NativeSearchComponent.swift").read)
    assert_match(/NativeSearchComponent\.self/, bridge.join("Components.swift").read)
    assert_match(/static component = "native-search"/, Rails.root.join("app/javascript/native/search_controller.js").read)
  end
end
