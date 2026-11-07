# OmniAuth's middleware answers the sign-in request and a callback with a bad
# state itself, before any controller, so a controller's rate_limit never sees
# them. This sits ahead of it: per address, in the app's cache, the same count
# rate_limit keeps, and a plain 429 once it is spent.
class DurableAssistants::SignInLimit
  LIMITS = { "/auth/ajent" => [ "POST", 10, 3.minutes ], "/auth/ajent/callback" => [ "GET", 10, 3.minutes ] }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    request = ActionDispatch::Request.new(env)
    method, to, within = LIMITS[request.path_info.chomp("/")]
    return @app.call(env) unless method && request.request_method == method

    key = "rate-limit:#{request.path_info.chomp('/')}:#{request.remote_ip}"
    if ActionController::Base.cache_store.increment(key, 1, expires_in: within).to_i > to
      [ 429, { "content-type" => "text/plain", "retry-after" => within.to_i.to_s }, [ "Too many sign-in attempts. Try again in a few minutes." ] ]
    else
      @app.call(env)
    end
  end
end
