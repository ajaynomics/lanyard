# What production cannot boot without, listed once.
#
# Per-service configuration stays a config_for line in config/application.rb;
# required-secret checking belongs here so a missing value fails the boot
# loudly instead of surfacing as a nil deep inside a request. Every role that
# boots the whole app (web and job) hits this, so each role's env needs the
# same values.
#
# A way in is required: an Ajent (or other OIDC) client. Without one nobody can
# sign in. GlitchTip is optional: without a DSN errors stay in the logs
# (config/initializers/glitchtip.rb).
# The check is a module of its own so test/config_test.rb can run it: the boot
# never does in a test, and CI's production boot skips it.
module ProductionSecrets
  REQUIRED = {
    app: %i[url],
    oidc: %i[issuer client_id client_secret]
  }.freeze

  def self.missing(config = Rails.application.config.x)
    REQUIRED.flat_map do |service, keys|
      keys.select { config.public_send(service)&.[](it).blank? }.map { "config.x.#{service}.#{it} (see config/#{service}.yml)" }
    end
  end

  def self.check!(config = Rails.application.config.x)
    missing = missing(config)
    return if missing.empty?

    raise <<~ERROR
      Missing required production configuration:
        #{missing.join("\n  ")}

      Each value resolves from ENV first, then Rails encrypted credentials.
    ERROR
  end
end

Rails.application.config.after_initialize do
  # Asset precompile in the Docker build runs without real secrets, and so does
  # the production boot step in bin/ci.
  next if ENV["SECRET_KEY_BASE_DUMMY"]
  next unless Rails.env.production?

  ProductionSecrets.check!
end
