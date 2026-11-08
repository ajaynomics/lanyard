# One conversation's connectors: its own, and the person's as this
# conversation uses them. Part of its agent's Tools, in the settings.
class Conversations::ConnectorsController < ApplicationController
  layout "settings"

  def index
    @conversation = Current.user.conversations.find(params[:conversation_id])
    @agent = @conversation.agent
  end
end
