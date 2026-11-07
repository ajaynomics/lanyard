# Archiving takes a conversation off the active list and unarchiving puts it
# back. Either way the person returns to the page they were on, filters and all.
class Conversations::ArchivesController < ApplicationController
  before_action :set_conversation

  def create
    @conversation.archive
    redirect_back_or_to @conversation, status: :see_other
  end

  def destroy
    @conversation.unarchive
    redirect_back_or_to @conversation, status: :see_other
  end

  private
    def set_conversation
      @conversation = Current.user.conversations.find(params[:conversation_id])
    end
end
