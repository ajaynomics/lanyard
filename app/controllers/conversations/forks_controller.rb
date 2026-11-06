# A branch of a conversation, from one of its messages. "Branch from here" on
# a reply keeps the reply; "Edit" on a person's message branches just before
# it and opens the branch with those words in the box, to change and send.
class Conversations::ForksController < ApplicationController
  def create
    conversation = Current.user.conversations.find(params[:conversation_id])
    message = conversation.messages.find(params.expect(:message_id))
    raise ActionController::BadRequest unless Agent::Access.valid_id?(params[:request_id]) && (message.from_person? || message.answer?)

    branch = conversation.branch(request_id: params[:request_id], after: message.fork_point)
    # The words travel as the parent's message id, never in the address.
    redirect_to conversation_path(branch, draft: (message.id if message.from_person?)), status: :see_other
  rescue Conversation::Mismatch
    head :conflict
  end
end
