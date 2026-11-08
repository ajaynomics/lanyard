require "test_helper"

class ConfigurationsControllerTest < ActionDispatch::IntegrationTest
  test "a native app reads its path rules before anyone signs in; forms open as a modal" do
    %w[ ios_v1 android_v1 ].each do |platform|
      get "/configurations/#{platform}.json"
      assert_response :success
      rules = response.parsed_body["rules"]
      assert_equal "default", rules.first.dig("properties", "context")
      modal = rules.find { it.dig("properties", "context") == "modal" }
      assert(modal["patterns"].any? { "/agents/new".match?(Regexp.new(it)) })
    end

    get "/configurations/web_v1.json"
    assert_response :not_found
  end

  test "a page says whether a native app shows it, so the web's own header can step aside" do
    sign_in_via_ajent
    get root_path, headers: { "User-Agent" => "Hotwire Native iOS; Turbo Native iOS" }
    follow_redirect! while response.redirect?
    assert_select "html[data-native-app]"
    get root_path
    follow_redirect! while response.redirect?
    assert_select "html[data-native-app]", count: 0
  end
end
