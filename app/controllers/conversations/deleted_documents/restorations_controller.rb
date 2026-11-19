# Bringing a deleted document back, as it was, before the purge.
class Conversations::DeletedDocuments::RestorationsController < ApplicationController
  def create
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    document = conversation.agent.deleted_documents.find(params[:deleted_document_id])
    document.undelete
    redirect_to conversation_document_path(conversation, document), status: :see_other
  end
end
