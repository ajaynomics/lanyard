# A conversation's family on one page: where each branch was taken, and a
# way to jump to any of them.
class Conversations::TreesController < ApplicationController
  def show
    @conversation = Current.user.conversations.find(params[:conversation_id])
    @tree = @conversation.tree
  end
end
