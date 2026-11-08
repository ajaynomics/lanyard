# Bringing an old version back makes a new one with its words, written by the
# person, so nothing in the history is lost.
class Conversations::Documents::RestorationsController < ApplicationController
  include DocumentScoped

  def create
    @document.restore(@document.versions.find(params.expect(:version_id)))
    redirect_to conversation_document_path(@conversation, @document), status: :see_other
  end
end
