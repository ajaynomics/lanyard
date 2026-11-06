module Agent
  # Browser resources. They keep the application's CSRF protection; identity
  # comes from the application's adapter, and a workspace in the URL is only a
  # lookup key that the authorization adapter must confirm.
  class BaseController < ApplicationController
    wrap_parameters false
    before_action :authenticate_access

    rescue_from Access::Unauthenticated, with: -> { head :unauthorized }
    rescue_from Access::Forbidden, with: -> { head :forbidden }
    rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
    rescue_from DurableAssistants::PiDurable::Client::Error, with: :agent_error

    private
      def authenticate_access
        @access = Access.for_browser(self)
      end

      def conversation
        @conversation ||= @access.conversations.find(params[:conversation_id] || params[:id])
      end

      def client
        @client ||= DurableAssistants::PiDurable::Client.new
      end

      def request_id
        id = request.request_parameters["request_id"]
        raise ActionController::BadRequest unless Access.valid_id?(id)
        id
      end

      def back_to_conversation
        redirect_to workspace_agent_conversation_path(@access.workspace_id, conversation), status: :see_other
      end

      def agent_error(error)
        respond_to do |format|
          format.json { render json: { error: "agent_unavailable" }, status: error.status }
          format.any { head error.status }
        end
      end
  end
end
