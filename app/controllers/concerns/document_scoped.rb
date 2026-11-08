# The canvas's pages: a document of the thread's agent, reached through the
# person, so another person's is not found.
module DocumentScoped
  extend ActiveSupport::Concern

  included do
    before_action do
      @conversation = Current.user.conversations.find(params[:conversation_id])
      id = params[:document_id] || params[:id]
      @document = @conversation.agent.documents.find(id) if id
    end
  end
end
