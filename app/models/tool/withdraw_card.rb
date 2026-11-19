# Takes back an approval card the agent raised and has since replaced or
# settled another way (#251), so nobody allows a call the agent no longer
# wants: its card closes and the call never runs. The real miss: a
# replacement send card went up while the first was still waiting, the
# person allowed both, and two near-identical emails went.
#
# Withdrawing asks no one, as withdrawing a question does not: it only ever
# takes a pending action away, never adds or allows one.
class Tool::WithdrawCard < Tool
  description "Withdraw an approval card you raised and no longer want, after replacing the call or settling it another way. " \
    "Its card closes, the person can no longer allow it, and the call never runs. " \
    "The card's id is in the answer you got when the call stopped waiting (\"Its card is <id>\")."
  argument :card_id, :integer, minimum: 1, description: "The card id you were given when the call stopped waiting."

  def call(card_id:)
    card = conversation.invocations.find_by(id: card_id)
    raise Refusal, "There is no card #{card_id} in this conversation waiting on a call of your own. " \
      "Withdraw a question with withdraw_question instead." unless card&.own_approval_card?
    card.withdraw!
    { withdrawn: card_id }
  rescue Invocation::Conflict
    raise Refusal, "Card #{card_id} is no longer open: it was allowed, declined, withdrawn or it expired."
  end
end
