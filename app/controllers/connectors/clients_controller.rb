# Who this install is, for a connector's sign-in server that reads it rather
# than taking a registration (a Client ID Metadata Document): the server
# fetches this address, finds itself named as the client_id, and checks the
# redirect address against it. The same for everyone, and nothing about anyone.
class Connectors::ClientsController < ApplicationController
  allow_unauthenticated_access

  def show
    expires_in 1.hour, public: true
    render json: McpServer.client_metadata.merge(client_id: McpServer.client_metadata_url)
  end
end
