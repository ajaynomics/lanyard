class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  rescue_from DurableAssistants::PiDurable::Client::Error, with: :agent_unavailable

  private
    def agent_unavailable(error)
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: "The assistant is not reachable right now. Try again shortly." }
        format.any { head error.status }
      end
    end
end
