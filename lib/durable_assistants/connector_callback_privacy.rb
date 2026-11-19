# A callback address carries a one-time code. The headers also belong on
# redirects, rate limits and public error pages formed outside its controller.
class DurableAssistants::ConnectorCallbackPrivacy
  CALLBACK = %r{\A/connectors/callback(?:\.[^/]+)?/?\z}

  def initialize(app) = @app = app

  def call(env)
    path = Rack::Utils.unescape_path(env.fetch("PATH_INFO")).b.squeeze("/")
    return @app.call(env) unless CALLBACK.match?(path)

    status, headers, body = @app.call(env)
    [ status, headers.merge("cache-control" => "no-store", "referrer-policy" => "no-referrer"), body ]
  end
end
