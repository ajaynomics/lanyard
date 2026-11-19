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

    def agent_unavailable(error)
      message = Conversation::Failure::REFUSALS.fetch(error.category, "The agent is not reachable right now. Try again shortly.")
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: message }
        format.turbo_stream { render turbo_stream: turbo_stream.update("flash", partial: "layouts/flash", locals: { messages: { alert: message } }), status: error.status }
        format.json { render json: { error: error.category || "agent_unavailable", message: message }, status: error.status }
        format.any { head error.status }
      end
    end
end
