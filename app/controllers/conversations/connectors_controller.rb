# One conversation's connectors: its own, and the person's as this conversation uses them.
class Conversations::ConnectorsController < ApplicationController
  def index
    @conversation = Current.user.conversations.find(params[:conversation_id])
  end
end
