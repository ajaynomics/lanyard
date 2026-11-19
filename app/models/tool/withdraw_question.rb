# Takes back a question the agent asked without waiting and has since
# settled itself (#84), so the person never answers a dead one: its card
# closes and can no longer be answered. Withdrawing asks no one; it only
# ever removes a card, never answers or allows anything.
class Tool::WithdrawQuestion < Tool
  description "Withdraw a question you asked with ask_person wait: false that you have settled yourself or no longer need. " \
    "Its card closes and the person can no longer answer it."
  argument :question_id, :integer, minimum: 1, description: "The question_id ask_person gave you."

  def call(question_id:)
    question = conversation.invocations.find_by(id: question_id)
    raise Refusal, "There is no question #{question_id} in this conversation that you asked without waiting." unless question&.asked_later?
    question.withdraw!
    { withdrawn: question_id }
  rescue Invocation::Conflict
    raise Refusal, "Question #{question_id} is no longer open: it was answered or it expired, and you were told."
  end
end
