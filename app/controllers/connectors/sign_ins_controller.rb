# Signing in to a connector's service, and out again, which forgets its tokens.
class Connectors::SignInsController < ApplicationController
  include ConnectorPages

  before_action { @connector = Current.user.mcp_servers.find(params[:connector_id]) }

  def create
    sign_in_to @connector
  end

  def destroy
    @connector.sign_out
    redirect_to connector_page(@connector), notice: "Signed out of #{@connector}. Its tools are gone until you sign in again."
  end
end
