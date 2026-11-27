# Which refresh token a renewal is spending, and since when (McpServer::Renewal):
# a digest, never the token. Two empty columns: no connector is renewing, and
# code from before neither reads nor writes them.
class AddRefreshClaimToMcpServers < ActiveRecord::Migration[8.2]
  def change
    add_column :mcp_servers, :refresh_claim, :string
    add_column :mcp_servers, :refresh_claimed_at, :datetime
  end
end
