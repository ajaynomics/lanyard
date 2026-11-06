# What production cannot boot without, listed once.
#
# Per-service configuration stays a config_for line in config/application.rb;
# required-secret checking belongs here so a missing value fails the boot
# loudly instead of surfacing as a nil deep inside a request. Every role that
# boots the whole app (web and job) hits this, so each role's env needs the
# same values.
REQUIRED_PRODUCTION_SECRETS = {
  app: %i[url]
}.freeze

# A way to sign in: Ajent, or Cloudflare Access where Ajent has no client for
# this destination. One complete set is enough. GlitchTip is optional: without
# a DSN errors stay in the logs (config/initializers/glitchtip.rb).
SIGN_IN_CONFIGURATIONS = {
  oidc: %i[issuer client_id client_secret],
  cloudflare_access: %i[team_domain audience]
}.freeze

Rails.application.config.after_initialize do
  # Asset precompile in the Docker build runs without real secrets, and so does
  # the production boot step in bin/ci.
  next if ENV["SECRET_KEY_BASE_DUMMY"]
  next unless Rails.env.production?

  blank = ->(service, keys) { keys.select { Rails.application.config.x.public_send(service)&.[](it).blank? }.map { "config.x.#{service}.#{it} (see config/#{service}.yml)" } }
  missing = REQUIRED_PRODUCTION_SECRETS.flat_map { |service, keys| blank.(service, keys) }
  unless SIGN_IN_CONFIGURATIONS.any? { |service, keys| blank.(service, keys).empty? }
    missing << "a way to sign in: every value of one of #{SIGN_IN_CONFIGURATIONS.map { |service, keys| keys.map { "config.x.#{service}.#{it}" }.join(' + ') }.join(', or ')}"
  end

  next if missing.empty?

  raise <<~ERROR
    Missing required production configuration:
      #{missing.join("\n  ")}

    Each value resolves from ENV first, then Rails encrypted credentials.
  ERROR
end
