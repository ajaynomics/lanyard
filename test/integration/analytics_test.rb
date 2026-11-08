require "test_helper"

class AnalyticsTest < ActionDispatch::IntegrationTest
  test "the Rybbit tag is on the sign-in page with a site id, and nowhere without one" do
    get sign_in_path
    assert_select "script[data-site-id]", false

    with_analytics(site_id: "25", host: "https://analytics.example") do
      get sign_in_path
      assert_select "script[src='https://analytics.example/api/script.js'][data-site-id='25'][defer]"
      assert_select "script[data-replay-mask-all-inputs='false']"
      options = JSON.parse(css_select("script[data-site-id]").first["data-replay-mask-input-options"])
      assert_equal({ "password" => true, "email" => false }, options, "secrets stay masked")
    end
  end

  test "replay masking is a setting" do
    with_analytics(site_id: "25", host: "https://analytics.example", replay_masking: true) do
      get sign_in_path
      assert_select "script[data-replay-mask-all-inputs='true']"
    end
  end

  private
    def with_analytics(**settings)
      analytics = Rails.configuration.x.analytics
      saved = settings.keys.index_with { analytics[it] }
      settings.each { |key, value| analytics[key] = value }
      yield
    ensure
      saved.each { |key, value| analytics[key] = value }
    end
end
