class Conversations::Invocations::LocationRequestsController < ApplicationController
  include InvocationScoped

  before_action :require_phone_session, only: %i[ create update ]

  rescue_from Invocation::LocationSharing::InvalidLocation, with: -> { head :unprocessable_entity }

  def create
    @invocation.claim_location!(by: Current.user, session_digest: session.id&.private_id)
    head :no_content
  end

  def update
    fix = params[:location_fix]
    fix = fix.is_a?(ActionController::Parameters) ? fix.permit(:latitude, :longitude, :accuracy_m, :timestamp) : {}
    @invocation.share_location!(by: Current.user, session_digest: session.id&.private_id, outcome: params[:outcome], fix: fix)
    head :no_content
  end

  def destroy
    @invocation.skip_location!(by: Current.user, outcome: params[:outcome])
    redirect_to @conversation, status: :see_other
  end

  private
    def require_phone_session
      head :forbidden unless phone_session?
    end
end
