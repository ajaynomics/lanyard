# Earlier messages of an agent's thread, a page at a time, for the lazy frame
# at the top of the thread as the person scrolls up (Conversation::Page).
#
# As JSON, for the Watch with its own token: the thread's newest turns as
# plain words, or those before an entry (Conversation::Transcript). Found in
# any of the person's workspaces, as its list is, and left unread.
class Conversations::MessagesController < ApplicationController
  allow_watch_access only: :index

  def index
    respond_to do |format|
      format.html do
        @conversation = find_in_workspace(:conversations, params[:conversation_id])
        @page = Conversation::Page.new(@conversation, before: params.expect(:before).to_i)
      end
      format.json do
        conversation = find_in_workspace(:conversations, params[:conversation_id])
        render json: Conversation::Transcript.new(conversation, before: params[:before].presence&.to_i)
      end
    end
  end
end
