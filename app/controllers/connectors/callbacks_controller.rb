# Where a service's sign-in page sends the person back (the redirect URI). The
# `state` finds the sign-in among the person's own connectors, so one that
# someone else started, or one already finished, is not found.
class Connectors::CallbacksController < ApplicationController
  include ConnectorPages

  def show
    connector = Current.user.mcp_servers.find_by(oauth_state: params[:state]) if params[:state].is_a?(String)
    unless connector
      return redirect_to connectors_path, alert: "That sign-in doesn't match one you started, or it was already used. Start again."
    end

    connector.finish_sign_in(request.query_parameters)
    McpServerRefreshJob.perform_later(connector)
    redirect_to connector_page(connector), notice: "Signed in to #{connector}. Listing its tools…"
  rescue McpServer::Unreachable => problem
    redirect_to connector_page(connector), alert: problem.message
  end
end
