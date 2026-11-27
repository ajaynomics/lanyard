module DurableAssistants
  # Rails' request logging and Rack's form handling precede controller guards.
  # Treat only the two marked callbacks as opaque there, even if someone lies
  # about the media type. The authenticated action still checks the real type.
  class ForgeBody
    CONTENT_TYPE = "durable_assistants.forge_content_type"
    BINARY = "application/octet-stream"
    PATH = %r{\A/agent/(files|uploads)(?:\.[^/]+)?\z}

    def initialize(app) = @app = app

    def call(env)
      if env["REQUEST_METHOD"] == "POST" && env.key?("HTTP_X_FORGE_MODE") &&
          PATH.match?(ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"]))
        env[CONTENT_TYPE] = env["CONTENT_TYPE"]
        env["CONTENT_TYPE"] = BINARY
      end
      @app.call(env)
    end
  end
end
