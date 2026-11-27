class Connectors::ClientSecretSetupsController < ApplicationController
  layout "outside"
  rate_limit to: 10, within: 1.minute

  def create
    no_store
    response.set_header("Referrer-Policy", "no-referrer")
    connector = find_in_workspace(:connectors, params[:connector_id])
    _, token = McpClientSecretSetup.issue!(connector, by: Current.user)
    @link = URI.join(DurableAssistants.config(:app, :url), mcp_client_secret_setup_path).tap { |url| url.fragment = token }
    render :create, status: :created
  end
end
