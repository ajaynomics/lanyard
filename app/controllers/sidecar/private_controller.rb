module Sidecar
  # Service-to-service JSON from the sidecar only. Browser resources keep
  # ordinary CSRF protection; these skip it because they authenticate the
  # transport instead, with RAILS_TOKEN, which is never the sidecar's own token.
  class PrivateController < ActionController::API
    wrap_parameters false
    before_action :authenticate_transport

    rescue_from Agent::Access::Forbidden, with: -> { render json: { error: "forbidden" }, status: :forbidden }
    rescue_from ActiveRecord::RecordNotFound, with: -> { render json: { error: "not_found" }, status: :not_found }

    private
      def authenticate_transport
        token = DurableAssistants::PiDurable.setting(:rails_token)
        other = DurableAssistants::PiDurable.setting(:sidecar_token)
        supplied = request.authorization
        valid = token.is_a?(String) && token.length >= 16 && token != other && supplied.is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare("Bearer #{token}", supplied)
        render json: { error: "unauthenticated" }, status: :unauthorized unless valid
      end

      def access
        @access ||= Agent::Access.resolve(request.request_parameters["actorId"], request.request_parameters["workspaceId"])
      end

      def conversation
        @conversation ||= access.agent.conversations.find_by!(durable_id: request.request_parameters["conversationId"].to_s)
      end
  end
end
