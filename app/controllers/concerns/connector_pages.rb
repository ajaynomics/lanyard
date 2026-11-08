# What the connector pages share: which page a connector is listed on, and
# starting its sign-in.
module ConnectorPages
  extend ActiveSupport::Concern

  private
    # A person's connector has its own page; one agent's own is on that agent's.
    def connector_page(connector)
      connector.conversation ? conversation_connectors_path(connector.conversation) : connector_path(connector)
    end

    # Sends the person to the service's sign-in page or, when the server lets
    # us in without one, lists its tools.
    def sign_in_to(connector)
      if (url = connector.sign_in_url)
        redirect_to url, allow_other_host: true
      else
        McpServerRefreshJob.perform_later(connector)
        redirect_to connector_page(connector), notice: "#{connector} needs no sign-in. Listing its tools…"
      end
    rescue McpServer::Unreachable => problem
      redirect_to connector_page(connector), alert: problem.message
    end
end
