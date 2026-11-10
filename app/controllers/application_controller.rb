class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from DurableAssistants::PiDurable::Client::Error, with: :agent_unavailable

  private
    # A small setting saved as it changed: back to the page it was changed on,
    # which morphs in place and says "Saved" (layouts/settings).
    def saved(fallback)
      flash[:saved] = true
      redirect_back_or_to fallback, status: :see_other
    end

    AGENT_REFUSALS = {
      "computer_unavailable" => "This agent's computer is not available here. Turn it off in its settings, or ask for it to be set up.",
      "model_unavailable" => "This agent's model is not available here. Choose another in its settings.",
      "tool_limit" => "This agent has more tools than it can be given. Set a connector to \"Look up when needed\", or switch some tools off, in its settings."
    }.freeze

    def agent_unavailable(error)
      message = AGENT_REFUSALS.fetch(error.category, "The agent is not reachable right now. Try again shortly.")
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: message }
        format.turbo_stream { render turbo_stream: turbo_stream.update("flash", partial: "layouts/flash", locals: { messages: { alert: message } }), status: error.status }
        format.any { head error.status }
      end
    end
end
