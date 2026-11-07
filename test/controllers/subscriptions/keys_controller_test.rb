require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Subscriptions::KeysControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  # Made up: never a real key in a test.
  KEY = "sk-ant-usr01-made-up-for-tests-only-wxyz".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent
    stub_page
  end
  teardown { remove_sidecar_settings }

  def key_status(**overrides) = { configured: true, connected: false, version: 0, hint: nil }.merge(overrides)

  def stub_page(**key)
    %w[ anthropic openai-codex ].each do |provider|
      stub_request(:get, "#{SIDECAR}/v1/subscriptions/#{provider}").to_return(body: { connected: false, version: 1 }.to_json)
    end
    stub_request(:get, "#{SIDECAR}/v1/subscriptions/anthropic-api").with(headers: { "Authorization" => "Bearer #{SIDECAR_TOKEN}" })
      .to_return(body: key_status(**key).to_json)
  end

  test "the page shows the key's card: not set, with a password field to save one, and the billing note" do
    get subscriptions_path
    assert_select "#api_key_anthropic_api h2", "Claude API key"
    assert_select "#api_key_anthropic_api dd", /Not set/
    assert_select "#api_key_anthropic_api", /Billed by Anthropic per token, separately from any subscription\./
    assert_select "#api_key_anthropic_api", /Only agents on an anthropic-api\/… model use it; those on anthropic\/…\s+still uses the subscription\./
    assert_select "form[action=?] input[type=password][name='api_key[key]']", subscription_key_path("anthropic-api")
    assert_select "form[action=?] input[name='api_key[version]'][value=0]", subscription_key_path("anthropic-api")
    assert_select "form[action=?] input[type=submit][value='Save key']", subscription_key_path("anthropic-api")
    assert_select "#api_key_anthropic_api button", text: "Remove key", count: 0
  end

  test "a saved key shows only its last four characters, and can be removed" do
    stub_page(connected: true, version: 2, hint: "wxyz")
    get subscriptions_path
    assert_select "#api_key_anthropic_api dd", /Connected · key ending wxyz/
    assert_select "form[action=?] button", subscription_key_path("anthropic-api"), text: "Remove key"
  end

  test "a server without a place for a key says so" do
    stub_request(:get, "#{SIDECAR}/v1/subscriptions/anthropic-api").to_return(status: 404, body: { error: "subscription_not_configured" }.to_json)
    get subscriptions_path
    assert_select "#api_key_anthropic_api", /isn't set up for a Claude API key/
    assert_select "form[action=?]", subscription_key_path("anthropic-api"), count: 0
  end

  test "saving passes the key straight to the sidecar with the version the page saw, and never logs it" do
    saved = stub_request(:put, "#{SIDECAR}/v1/subscriptions/anthropic-api/key").with(body: { version: 0, key: KEY })
      .to_return(body: key_status(connected: true, version: 1, hint: "wxyz").to_json)
    log = StringIO.new
    logger = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(log)
    begin
      patch subscription_key_path("anthropic-api"), params: { api_key: { version: 0, key: " #{KEY}\n" } }
    ensure
      ActionController::Base.logger = logger
    end
    assert_requested saved
    assert_redirected_to subscriptions_path
    assert_match "Claude API key", flash[:notice]
    assert_match "Parameters", log.string
    assert_no_match KEY, log.string
    assert_equal "[FILTERED]", request.filtered_parameters["api_key"]
  end

  test "a key Anthropic refuses, one it couldn't check, or a change in another tab says so in plain words" do
    { "invalid_api_key" => [ 422, /didn't accept that key/ ], "api_key_unverified" => [ 503, /Couldn't reach Anthropic.*wasn't saved/ ],
      "subscription_changed" => [ 412, /another tab/ ] }.each do |category, (code, message)|
      stub_request(:put, "#{SIDECAR}/v1/subscriptions/anthropic-api/key").to_return(status: code, body: { error: category }.to_json)
      patch subscription_key_path("anthropic-api"), params: { api_key: { version: 0, key: KEY } }
      assert_redirected_to subscriptions_path
      assert_match message, flash[:alert]
    end
  end

  test "removing names the version it saw" do
    gone = stub_request(:delete, "#{SIDECAR}/v1/subscriptions/anthropic-api/key").with(body: { version: 2 })
      .to_return(body: key_status(version: 3).to_json)
    delete subscription_key_path("anthropic-api"), params: { version: 2 }
    assert_requested gone
    assert_redirected_to subscriptions_path
    assert_match "Removed", flash[:notice]
  end

  test "only known providers have a key" do
    patch subscription_key_path("anthropic"), params: { api_key: { version: 0, key: KEY } }
    assert_response :not_found
  end

  test "signed out, a key can't be saved" do
    delete sign_out_path
    patch subscription_key_path("anthropic-api"), params: { api_key: { version: 0, key: KEY } }
    assert_redirected_to sign_in_path
  end
end
