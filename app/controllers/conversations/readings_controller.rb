# The person has read the thread's newest reply: it arrived while they had it
# open (reading_controller), so the agent list no longer shows it unread.
class Conversations::ReadingsController < ApplicationController
  def create
    Current.user.conversations.find(params[:conversation_id]).read!
    head :no_content
  end
end
