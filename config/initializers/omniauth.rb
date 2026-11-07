# An install without an Ajent client has no sign-in request to answer: the
# middleware is not even there, and nobody can get in.
if DurableAssistants::Oidc.configured?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, DurableAssistants::Oidc.provider_options
  end
end

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

# The sign-in request asks Ajent for its discovery document, so it is rate
# limited per address like the controllers' rate_limit, in the same store. The
# middleware answers it before any controller, hence a hook; the error lands on
# the failure route, which answers 429.
class TooManySignIns < OmniAuth::AuthenticityError; end
OmniAuth.config.before_request_phase = proc do |env|
  count = SessionsController.cache_store.increment("rate-limit:auth/ajent:#{ActionDispatch::Request.new(env).remote_ip}", 1, expires_in: 3.minutes)
  raise TooManySignIns if count.to_i > 10
end

# Never leak provider internals to the browser. Failures land on a route that
# renders a generic message, or, if Ajent was out of reach, says so.
OmniAuth.config.failure_raise_out_environments = []
OmniAuth.config.on_failure = proc do |env|
  env["omniauth.error.type"] = :unreachable if DurableAssistants::Oidc.unreachable?(env["omniauth.error"])
  env["omniauth.error.type"] = :too_many_requests if env["omniauth.error"].is_a?(TooManySignIns)
  OmniAuth::FailureEndpoint.call(env)
end
