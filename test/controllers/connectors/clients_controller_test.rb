require "test_helper"

class Connectors::ClientsControllerTest < ActionDispatch::IntegrationTest
  test "a sign-in server reads who this install is without signing in, named as its own client_id" do
    original = Rails.application.config.x.app[:url]
    Rails.application.config.x.app[:url] = "https://agents.example.com"

    get "/connectors/client"
    assert_response :success
    assert_equal "application/json", response.media_type
    document = response.parsed_body
    assert_equal "https://agents.example.com/connectors/client", document["client_id"]
    assert_equal [ "https://agents.example.com/connectors/callback" ], document["redirect_uris"]
    assert_equal "none", document["token_endpoint_auth_method"]
    assert_equal DurableAssistants.config(:app, :name), document["client_name"]
  ensure
    Rails.application.config.x.app[:url] = original
  end
end
