require "test_helper"

class ConfigurationsControllerTest < ActionDispatch::IntegrationTest
  NATIVE = { "User-Agent" => "NativeSignIn/1; Hotwire Native iOS; Turbo Native iOS; bridge-components: [button menu]" }.freeze

  test "a native app reads its path rules before anyone signs in; forms open as a modal" do
    %w[ ios_v1 ios_v2 ios_v3 android_v1 ].each do |platform|
      get "/configurations/#{platform}.json"
      assert_response :success
      assert_match(/public/, response.headers["Cache-Control"])
      rules = response.parsed_body["rules"]
      assert_equal "default", rules.first.dig("properties", "context")
      assert_equal "modal", properties(rules, "/agents/new")["context"]
    end

    get "/configurations/web_v1.json"
    assert_response :not_found
  end

  test "the phone app's version: forms, settings, a card and signing in are sheets; lists and threads push and refresh" do
    get "/configurations/ios_v2.json"
    rules = response.parsed_body["rules"]

    %w[ /agents/new /agents/3/skills/9/edit /settings /settings/account /agents/3 /agents/3/tools /connectors /subscriptions ].each do |path|
      sheet = properties(rules, path)
      assert_equal [ "modal", "large", false ], sheet.values_at("context", "modal_style", "pull_to_refresh_enabled"), path
    end
    assert_equal [ "modal", "medium" ], properties(rules, "/approvals/12").values_at("context", "modal_style")
    assert_equal false, properties(rules, "/sign_in")["modal_dismiss_gesture_enabled"], "signing in is not swiped away"
    assert_equal "full", properties(rules, "/conversations/4/screen")["modal_style"]

    %w[ / /approvals /conversations/4 ].each do |path|
      pushed = properties(rules, path)
      assert_equal [ "default", true ], pushed.values_at("context", "pull_to_refresh_enabled"), path
    end
    assert_equal "settings", properties(rules, "/native/settings")["view_controller"], "the Settings tab is the app's own"
  end

  # Renaming a tab, or giving it another start, should not wait on a TestFlight build (REVIEW.md finding 14). The
  # tabs ride in ios_v3, the version a build that reads them reads, with Settings the web's /settings; a build
  # reading an older version draws its own tabs, so those serve none.
  test "the phone app's tabs come from Rails: each its id, title, symbol and first page, in order" do
    get "/configurations/ios_v3.json"
    assert_equal [
      { "id" => "agents", "title" => "Agents", "ios_image" => "bubble.left.and.bubble.right", "url" => "/" },
      { "id" => "needs-you", "title" => "Needs you", "ios_image" => "hand.raised", "url" => "/approvals" },
      { "id" => "settings", "title" => "Settings", "ios_image" => "gearshape", "url" => "/settings" }
    ], response.parsed_body.dig("settings", "tabs")

    %w[ ios_v1 ios_v2 android_v1 ].each do |platform|
      get "/configurations/#{platform}.json"
      assert_equal({}, response.parsed_body["settings"], "#{platform}'s apps have no tabs to serve")
    end
  end

  # The sheet's close button was chosen in Swift by repeating these rules' paths (REVIEW.md finding 16).
  test "the rules say which sheets are left by Cancel: a form and signing in; any other sheet by Done" do
    get "/configurations/ios_v3.json"
    rules = response.parsed_body["rules"]

    %w[ /agents/new /agents/3/skills/9/edit /workspaces/2/edit /sign_in ].each do |path|
      assert_equal "cancel", properties(rules, path)["close"], path
    end
    %w[ /approvals/12 /settings /settings/account /agents/3 /conversations/4/screen ].each do |path|
      assert_nil properties(rules, path)["close"], path
    end
  end

  # A build reading ios_v2 is installed and draws its own Settings tab: its rules stay as they are.
  test "ios_v3 is ios_v2 with the Settings tab a web page: /settings is the tab's root, its places still sheets" do
    get "/configurations/ios_v2.json"
    v2 = response.parsed_body["rules"]
    get "/configurations/ios_v3.json"
    v3 = response.parsed_body["rules"]

    assert_equal [ "default", true ], properties(v3, "/settings").values_at("context", "pull_to_refresh_enabled"), "the tab starts here"
    %w[ /agents/new /settings/account /settings/notifications /settings/watches /agents/3 /connectors /subscriptions /workspaces ].each do |path|
      assert_equal properties(v2, path), properties(v3, path), path
    end
    %w[ / /approvals /conversations/4 /approvals/12 /sign_in /conversations/4/screen ].each do |path|
      assert_equal properties(v2, path), properties(v3, path), path
    end
    assert v3.none? { it["properties"].key?("view_controller") }, "no screen of the app's own"
    assert_equal "settings", properties(v2, "/native/settings")["view_controller"], "ios_v2 unchanged"
  end

  test "the phone app bundles the rules it reads, ios_v3, for a launch with no network" do
    get "/configurations/ios_v3.json"
    bundled = JSON.parse(Rails.root.join("ios/Phone/path-configuration.json").read)
    assert_equal response.parsed_body, bundled
  end

  test "a page says whether a native app shows it, so the web's own header can step aside" do
    sign_in_via_ajent
    get root_path, headers: NATIVE
    assert_select "html[data-native-app]"
    get root_path
    assert_select "html[data-native-app]", count: 0
  end

  private
    # As Hotwire Native merges them: every matching rule in order, the later winning.
    def properties(rules, path)
      rules.select { |rule| rule["patterns"].any? { Regexp.new(it).match?(path) } }.reduce({}) { |merged, rule| merged.merge(rule["properties"]) }
    end
end
