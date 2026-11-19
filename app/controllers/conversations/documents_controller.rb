# A document in the canvas. Opened from its card in the thread, or from the
# list of them all, it fills the thread's canvas frame beside the messages;
# on its own, it is a page with a way back. A person makes one with a title
# and its words, and saving writes the person's version.
class Conversations::DocumentsController < ApplicationController
  include DocumentScoped

  def index
    @documents = @conversation.agent.documents.with_size.order(updated_at: :desc, id: :desc)
    @deleted = @conversation.agent.deleted_documents.count
  end

  def show
  end

  def new
    @document = @conversation.agent.documents.new
  end

  # The person's words are its first version, which the agent sees with their next message.
  def create
    attributes = params.expect(document: [ :title, :body ])
    @document = @conversation.agent.documents.new(title: attributes[:title])
    @body = attributes[:body].to_s.gsub("\r\n", "\n")
    Document.transaction do
      @document.save!
      @document.revise(@body, by: "person")
    end
    redirect_to conversation_document_path(@conversation, @document), status: :see_other
  rescue ActiveRecord::RecordInvalid => invalid
    @problem = invalid.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
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
