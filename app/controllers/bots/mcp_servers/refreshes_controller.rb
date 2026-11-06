module Bots
  module McpServers
    class RefreshesController < ApplicationController
      def create
        bot = Current.user.bots.find(params[:bot_id])
        server = bot.mcp_servers.find(params[:mcp_server_id])
        McpServerRefreshJob.perform_later(server)
        redirect_to bot_path(bot, anchor: "mcp_servers"), notice: "Listing #{server}'s tools again…"
      end
    end
  end
end
