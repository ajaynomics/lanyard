module Bots
  class McpServersController < ApplicationController
    before_action :set_bot

    def create
      server = @bot.mcp_servers.new(params.expect(mcp_server: %i[ name url token ]))
      if server.save
        McpServerRefreshJob.perform_later(server)
        redirect_to bot_path(@bot, anchor: "mcp_servers"), notice: "Added #{server}. Listing its tools…"
      else
        redirect_to bot_path(@bot, anchor: "mcp_servers"), alert: server.errors.full_messages.to_sentence
      end
    end

    def destroy
      server = @bot.mcp_servers.find(params[:id])
      server.destroy!
      redirect_to bot_path(@bot, anchor: "mcp_servers"), notice: "Removed #{server}. #{@bot} cannot use its tools from the next message."
    end

    private
      def set_bot
        @bot = Current.user.bots.find(params[:bot_id])
      end
  end
end
