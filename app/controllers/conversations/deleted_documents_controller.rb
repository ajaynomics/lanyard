# Recently deleted: the thread's agent's deleted documents, newest first,
# each restorable until the purge (Document::Deletable).
class Conversations::DeletedDocumentsController < ApplicationController
  def index
    @conversation = find_in_workspace(:conversations, params[:conversation_id])
    @documents = @conversation.agent.deleted_documents.with_size.order(deleted_at: :desc)
  end
end
