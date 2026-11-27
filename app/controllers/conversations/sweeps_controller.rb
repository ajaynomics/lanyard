class Conversations::SweepsController < ApplicationController
  def show
    @conversation = Current.user.conversations.find(params[:conversation_id])
    @invocation = @conversation.invocations.waiting_on_person.find { it.approvable_by?(Current.user) }
  end
end
