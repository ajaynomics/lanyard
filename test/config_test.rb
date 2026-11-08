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

  test "the accent hue is a whole number of degrees, or the boot fails" do
    config = Rails.application.config.x.app
    original = config[:accent_hue]
    { 0 => 0, "360" => 360, nil => 255, "" => 255 }.each do |value, hue|
      config[:accent_hue] = value
      assert_equal hue, DurableAssistants.accent_hue
    end
    [ "361", "-1", "emerald", "160.5" ].each do |value|
      config[:accent_hue] = value
      error = assert_raises(ArgumentError) { DurableAssistants.accent_hue }
      assert_match "APP__ACCENT_HUE", error.message
    end
  ensure
    config[:accent_hue] = original
  end

  test "every service config is loaded where the initializers can read it" do
    %i[app glitchtip oidc analytics].each do |service|
      assert Rails.application.config.x.public_send(service).present?, "config.x.#{service} is empty; see config/#{service}.yml"
    end
  end

  test "the secrets check reads the app's real configuration, not only a stand-in for it" do
    assert_kind_of Array, ProductionSecrets.missing
  end

  test "production cannot boot without the app url and a complete sign-in client" do
    complete = { app: { url: "https://assistants.example" }, oidc: { issuer: "https://id.example", client_id: "id", client_secret: "secret" } }
    assert_empty ProductionSecrets.missing(config_like(complete))

    blank = config_like(complete.deep_merge(app: { url: "" }, oidc: { client_secret: nil }))
    assert_equal [ "config.x.app.url (see config/app.yml)", "config.x.oidc.client_secret (see config/oidc.yml)" ], ProductionSecrets.missing(blank)
    assert_equal 4, ProductionSecrets.missing(config_like({})).size, "a service with no config at all is missing every key"

    error = assert_raises(RuntimeError) { ProductionSecrets.check!(blank) }
    assert_match "config.x.oidc.client_secret", error.message
  end

  test "Web Push is optional, but once a key is set the pair and a subject are required" do
    complete = { app: { url: "https://assistants.example" }, oidc: { issuer: "https://id.example", client_id: "id", client_secret: "secret" } }
    assert_empty ProductionSecrets.missing(config_like(complete.merge(web_push: { subject: "mailto:ops@example.com" })))
    assert_empty ProductionSecrets.missing(config_like(complete.merge(web_push: { public_key: "pub", private_key: "priv", subject: "mailto:ops@example.com" })))
    assert_equal [ "config.x.web_push.private_key (see config/web_push.yml)", "config.x.web_push.subject (see config/web_push.yml)" ],
      ProductionSecrets.missing(config_like(complete.merge(web_push: { public_key: "pub" })))
  end

  test "Web Push's subject is the one set, or the install's mail address" do
    subject = ->(env) do
      with_env(env) do
        Rails.app.creds.reload
        YAML.load(ERB.new(Rails.root.join("config/web_push.yml").read).result, aliases: false).dig("shared", "subject")
      end
    end
    assert_equal "https://ops.example.com", subject.({ "WEB_PUSH__SUBJECT" => "https://ops.example.com", "APP__MAILER_FROM" => "agents@example.com" })
    assert_equal "mailto:agents@example.com", subject.({ "WEB_PUSH__SUBJECT" => "", "APP__MAILER_FROM" => "agents@example.com" })
    assert_nil subject.({ "WEB_PUSH__SUBJECT" => "", "APP__MAILER_FROM" => "" })
  ensure
    Rails.app.creds.reload
  end

  # Unquoted, a client id of 0123 would read as a number and one starting with
  # ! or & as YAML syntax.
  test "the sign-in client's values stay the strings they were set to" do
    with_env("OIDC__ISSUER" => "&issuer", "OIDC__CLIENT_ID" => "0123", "OIDC__CLIENT_SECRET" => "true") do
      Rails.app.creds.reload # it reads ENV once and keeps it
      shared = YAML.load(ERB.new(Rails.root.join("config/oidc.yml").read).result, aliases: false).fetch("shared")

      assert_equal [ "&issuer", "0123", "true" ], shared.values_at("issuer", "client_id", "client_secret")
    end
  ensure
    Rails.app.creds.reload
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
    def config_like(services)
      ActiveSupport::OrderedOptions.new.tap do |config|
        services.each { |service, values| config[service] = ActiveSupport::OrderedOptions.new.merge!(values) }
      end
    end

    def with_env(variables)
      previous = ENV.slice(*variables.keys)
      variables.each { |key, value| ENV[key] = value }
      yield
    ensure
      variables.each_key { |key| previous.key?(key) ? ENV[key] = previous[key] : ENV.delete(key) }
    end
end
