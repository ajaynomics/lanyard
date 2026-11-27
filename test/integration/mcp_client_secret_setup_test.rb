require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class McpClientSecretSetupFlowTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  VALUE = "made up OAuth input, not a credential"

  setup do
    @owner = create_user(name: "SetupOwner", email: "operator@example.com")
    @connector = @owner.personal_workspace.mcp_servers.create!(user: @owner, name: "setup_example", url: "https://connector.example.org/mcp",
      conversation: @owner.agents.sole.conversation, oauth_client: { "client_id" => "public-client-example" })
    sign_in_via_ajent(subject: "sub-setupowner", email: @owner.email, name: @owner.name)
  end

  test "only a scoped write-only form accepts a secret from an outside browser" do
    post connector_client_secret_setup_path(@connector)
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    link = URI(css_select("#setup-link").sole["value"])
    assert_equal mcp_client_secret_setup_path, link.path
    assert_nil link.query
    token = link.fragment
    visitor = open_session
    visitor.get link.path
    assert_equal 200, visitor.response.status
    assert_equal "no-referrer", visitor.response.headers["Referrer-Policy"]
    assert_equal "no-store", visitor.response.headers["Cache-Control"]
    assert_not_includes visitor.response.body, token
    assert_not_includes visitor.response.body, @connector.name

    visitor.post link.path, params: { setup_token: token, client_secret: VALUE, connector_id: @connector.id }
    assert_equal 400, visitor.response.status
    assert_not_includes visitor.response.body, VALUE
    assert_nil @connector.reload.oauth_client["client_secret"]

    output = StringIO.new
    previous = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(output)
    visitor.post link.path, params: { setup_token: token, client_secret: VALUE }
    assert_equal 200, visitor.response.status
    assert_not_includes visitor.response.body, VALUE
    assert_not_includes visitor.response.body, token
    assert_includes output.string, "[FILTERED]"
    assert_not_includes output.string, VALUE
    assert_not_includes output.string, token
    assert_equal VALUE, @connector.reload.oauth_client["client_secret"]
    assert_nil @connector.oauth_pending
    visitor.post link.path, params: { setup_token: token, client_secret: "another made up value" }
    assert_equal 410, visitor.response.status
    assert_equal VALUE, @connector.reload.oauth_client["client_secret"]
  ensure
    ActionController::Base.logger = previous if previous
  end

  test "only eligible connector issuers can create links and GET never consumes the token" do
    setup, token = McpClientSecretSetup.issue!(@connector, by: @owner)
    visitor = open_session
    visitor.post connector_client_secret_setup_path(@connector)
    assert visitor.response.redirect?
    visitor.get mcp_client_secret_setup_path
    assert_equal 200, visitor.response.status
    assert_nil setup.reload.used_at
    visitor.get mcp_client_secret_setup_path, params: { setup_token: token }
    assert_equal 400, visitor.response.status
    assert_not_includes visitor.response.body, token

    other = create_user(name: "OtherMember", email: "member@example.com")
    sign_in_via_ajent(subject: "sub-othermember", email: other.email, name: other.name)
    post connector_client_secret_setup_path(@connector)
    assert_response :not_found
  end
end
