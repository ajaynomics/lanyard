# A person answers the bot's question; the answer becomes the call's result.
class Conversations::Invocations::AnswersController < ApplicationController
  include InvocationScoped

  def create
    answer = params.fetch(:answer, {}).permit(:text, selections: [])
    @invocation.answer!(selections: Array(answer[:selections]).compact_blank, text: answer[:text], by: Current.user)
    redirect_to @conversation, status: :see_other
  rescue ActiveRecord::RecordInvalid => invalid
    redirect_to @conversation, alert: invalid.record.errors.full_messages.to_sentence, status: :see_other
  end
end
