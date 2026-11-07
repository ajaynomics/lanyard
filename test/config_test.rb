require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  test "config collapses empty values to the default and passes false and zero through" do
    config = Rails.application.config.x

    config.scratch = ActiveSupport::OrderedOptions.new
    config.scratch.flag = false
    config.scratch.count = 0
    config.scratch.blank = ""
    config.scratch.nested = { "key" => "value" }

    assert_equal false, DurableAssistants.config(:scratch, :flag, default: true)
    assert_equal 0, DurableAssistants.config(:scratch, :count, default: 5)
    assert_equal "fallback", DurableAssistants.config(:scratch, :blank, default: "fallback")
    assert_equal "fallback", DurableAssistants.config(:scratch, :missing, default: "fallback")
    assert_equal "value", DurableAssistants.config(:scratch, :nested, "key")
    assert_equal "fallback", DurableAssistants.config(:never_configured, :key, default: "fallback")
    assert_raises(ArgumentError) { DurableAssistants.config }
  ensure
    # Nothing can remove a key from config.x; nil reads as unset to the reader.
    config.scratch = nil
  end

  test "revision prefers KAMAL_VERSION, and an empty one is no revision" do
    with_env("KAMAL_VERSION" => "abc123", "REVISION" => "stale") { assert_equal "abc123", DurableAssistants.revision }
    with_env("KAMAL_VERSION" => "", "REVISION" => "") { assert_nil DurableAssistants.revision }
  end

  test "every service config is loaded where the initializers can read it" do
    %i[app glitchtip oidc analytics].each do |service|
      assert Rails.application.config.x.public_send(service).present?, "config.x.#{service} is empty; see config/#{service}.yml"
    end
  end

  test "production cannot boot without the app url and a complete sign-in client" do
    assert_equal({ app: %i[url], oidc: %i[issuer client_id client_secret] }, REQUIRED_PRODUCTION_SECRETS)
  end

  test "errors are inert without a DSN, so development and CI never report anywhere" do
    assert_nil Rails.application.config.x.glitchtip.dsn
    assert_not Sentry.initialized?
  end

  test "OIDC discovers its endpoints, pins PKCE and the signing algorithm" do
    options = DurableAssistants::Oidc.provider_options

    assert_equal :ajent, options[:name]
    assert options[:discovery]
    assert options[:pkce]
    assert_equal :RS256, options[:client_signing_alg]
    assert_equal "test_client_id", options.dig(:client_options, :identifier)
  end

  test "error reports carry no request bodies or locals" do
    sentry = Sentry::Configuration.new
    DurableAssistants::Glitchtip.apply(sentry)

    assert_not sentry.send_default_pii
    assert_not sentry.include_local_variables

    event = Struct.new(:request).new(Struct.new(:data, :cookies, :query_string, :env).new("body", "cookie", "q=1", { "a" => 1 }))
    scrubbed = DurableAssistants::Glitchtip.scrub(event, nil).request

    assert_nil scrubbed.data
    assert_nil scrubbed.cookies
    assert_nil scrubbed.query_string
    assert_nil scrubbed.env
  end

  private
    def with_env(variables)
      previous = ENV.slice(*variables.keys)
      variables.each { |key, value| ENV[key] = value }
      yield
    ensure
      variables.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
    end
end
