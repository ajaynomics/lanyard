require "test_helper"

class AppNameTest < ActionDispatch::IntegrationTest
  test "the screens and the installed app take the deployment's name from APP__NAME" do
    with_setting(:app, :name, "Durable Assistants") do
      get sign_in_path
      assert_select "h1", "Durable Assistants"
      assert_select "meta[name=application-name][content=?]", "Durable Assistants"

      get pwa_manifest_path(format: :json)
      assert_equal [ "Durable Assistants" ] * 2, response.parsed_body.values_at("name", "short_name")
    end
  end
end
