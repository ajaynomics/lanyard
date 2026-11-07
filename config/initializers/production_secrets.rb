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
REQUIRED_PRODUCTION_SECRETS = {
  app: %i[url],
  oidc: %i[issuer client_id client_secret]
}.freeze

Rails.application.config.after_initialize do
  # Asset precompile in the Docker build runs without real secrets, and so does
  # the production boot step in bin/ci.
  next if ENV["SECRET_KEY_BASE_DUMMY"]
  next unless Rails.env.production?

  blank = ->(service, keys) { keys.select { Rails.application.config.x.public_send(service)&.[](it).blank? }.map { "config.x.#{service}.#{it} (see config/#{service}.yml)" } }
  missing = REQUIRED_PRODUCTION_SECRETS.flat_map { |service, keys| blank.(service, keys) }

  next if missing.empty?

  raise <<~ERROR
    Missing required production configuration:
      #{missing.join("\n  ")}

    Each value resolves from ENV first, then Rails encrypted credentials.
  ERROR
end
