# Earlier messages of an agent's thread, a page at a time, for the lazy frame
# at the top of the thread as the person scrolls up (Conversation::Page).
class Conversations::MessagesController < ApplicationController
  def index
    @conversation = Current.user.conversations.find(params[:conversation_id])
    @page = Conversation::Page.new(@conversation, before: params.expect(:before).to_i)
  end
end
