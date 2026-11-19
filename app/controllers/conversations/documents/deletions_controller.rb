# Deleting a document, softly: Recently deleted keeps it, restorable, until
# the purge (Document::Deletable).
class Conversations::Documents::DeletionsController < ApplicationController
  include DocumentScoped

  def create
    @document.soft_delete(by: "person")
    redirect_to conversation_documents_path(@conversation), status: :see_other
  end
end
