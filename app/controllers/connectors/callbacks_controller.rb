# Where a service's sign-in page sends the person back (the redirect URI).
# Signed in, the `state` finds the sign-in among the connectors of the
# workspaces the person is in, so another person's, or one already finished,
# is not found. A sign-in link may also be sent to someone who never signs in
# here, a client approving their own account: with no session the `state`
# alone finds it, since only the browser that started it holds it and it
# works once. That browser gets a plain page naming nothing, and no session.
class Connectors::CallbacksController < ApplicationController
  include ConnectorPages

  allow_unauthenticated_access only: :show
  # A visit would keep the full landing URL, including the code and state,
  # even if the browser is still signed in when its visit cookie expires.
  skip_before_action :track_ahoy_visit, only: :show
  # A browser with a session is checked as on every other page.
  before_action :require_sign_in, if: -> { session[:user_id] }
  # Counted before the state is looked up, so unknown states count too.
  rate_limit to: 30, within: 1.minute, unless: :signed_in?, name: "connector_callbacks"

  def show
    signed_in? ? finish_for_person : finish_without_session
  end

  private
    def finish_for_person
      connector = Current.user.connectors.find_by(oauth_state: params[:state]) if params[:state].is_a?(String)
      unless connector
        return redirect_to connectors_path, alert: "That sign-in doesn't match one you started, or it was already used. Start again."
      end

      work_in connector.workspace
      connector.finish_sign_in(request.query_parameters)
      McpServerRefreshJob.perform_later(connector)
      redirect_to connector_page(connector), notice: "Signed in to #{connector}. Listing its tools…"
    rescue McpServer::Unreachable => problem
      redirect_to connector_page(connector), alert: problem.message
    end

    def finish_without_session
      request.session_options[:skip] = true

      connector = started_sign_in or return refused
      connector.finish_sign_in(request.query_parameters)
      McpServerRefreshJob.perform_later(connector)
      render :show, layout: "outside"
    rescue McpServer::Unreachable
      refused
    end

    # Looked up by the exact state, then compared in constant time, as
    # McpServer::Authorization does.
    def started_sign_in
      state = params[:state]
      return unless state.is_a?(String) && state.present?
      connector = McpServer.find_by(oauth_state: state) # tenancy-ok: the state is a secret only the browser that started the sign-in holds, used once
      connector if connector && ActiveSupport::SecurityUtils.secure_compare(connector.oauth_state, state)
    end

    def refused
      render :refused, layout: "outside", status: :bad_request
    end
end
