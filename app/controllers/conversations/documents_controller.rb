# A document in the canvas. Opened from its card in the thread, it fills the
# thread's canvas frame beside the messages; on its own, it is a page with a
# way back. Saving writes the person's version.
class Conversations::DocumentsController < ApplicationController
  include DocumentScoped

  # The canvas closed: an empty frame beside the thread, or, on its own page, the thread.
  def index
    redirect_to @conversation unless turbo_frame_request?
  end

  def show
  end

  # The version the box began from comes back with the words: if the agent
  # wrote one since, the person's words stay in the box, the new version shows
  # in View, and a second Save replaces it knowingly.
  def update
    @draft = params.expect(document: [ :body ])[:body].to_s.gsub("\r\n", "\n")
    if params[:version_id].to_i == @document.current_version&.id
      @document.revise(@draft, by: "person")
      redirect_to conversation_document_path(@conversation, @document), status: :see_other
    else
      @problem = "#{@conversation.agent} changed this while you were editing. Your words are still here: View shows its version, and Save replaces it with yours."
      render :show, status: :conflict
    end
  rescue ActiveRecord::RecordInvalid => invalid
    @problem = invalid.record.errors.full_messages.to_sentence
    render :show, status: :unprocessable_entity
  end
end
