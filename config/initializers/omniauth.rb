# An install without an Ajent client has no sign-in request to answer: the
# middleware is not even there, and nobody can get in.
if DurableAssistants::Oidc.configured?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, DurableAssistants::Oidc.provider_options
  end
  # Open to the internet, and each request starts work with Ajent.
  Rails.application.config.middleware.insert_before OmniAuth::Builder, DurableAssistants::SignInLimit
end

# Its redirects are built on the app's public address, never on whatever Host
# a request names.
OmniAuth.config.full_host = ->(_env) { DurableAssistants.config(:app, :url).to_s.chomp("/").presence || "http://localhost:3000" }

# Sign-in needs Ajent twice (its discovery document, then the token and user
# info), so a hung Ajent must fail in seconds and not keep a person waiting.
OpenIDConnect.http_config do |faraday|
  faraday.options.open_timeout = 5
  faraday.options.timeout = 10
end

# Its warnings and failures go where the app's other logs go.
OmniAuth.config.logger = Rails.logger

# Only POST may begin the request phase. omniauth-rails_csrf_protection then
# enforces an authenticity token on it, which is what stops a third-party page
# from silently starting a sign-in.
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true

# Never leak provider internals to the browser. Failures land on a route that
# renders a generic message, or, if Ajent was out of reach, says so.
OmniAuth.config.failure_raise_out_environments = []
OmniAuth.config.on_failure = proc do |env|
  type = DurableAssistants::Oidc.unreachable?(env["omniauth.error"]) ? :unreachable : env["omniauth.error.type"]
  # OmniAuth's own failure endpoint answers with a relative address, which a
  # server in front may complete with its own host; this one is the app's.
  [ 302, { "location" => "#{OmniAuth.config.full_host.call(env)}/auth/failure?message=#{Rack::Utils.escape(type)}" }, [] ]
end
