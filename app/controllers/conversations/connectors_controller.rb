# One agent's connectors: its own, and the person's as this agent uses them.
class Conversations::ConnectorsController < ApplicationController
  def index
    @conversation = Current.user.conversations.find(params[:conversation_id])
  end
end
