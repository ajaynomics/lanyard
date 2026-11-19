class Tool::AskPerson < Tool
  # A question asked without waiting (#84) lives on its card no longer than
  # this; past it nobody answers, and the agent is told.
  LONGEST = 7.days
  ASKED_LATER = "Asked without waiting: carry on. The person's answer comes later as a message naming this question_id; " \
    "decide then whether it still matters. If you settle it yourself first, withdraw it with withdraw_question."

  description "Ask the person a question when the choice is theirs. Offer options when you can; the answer is the result. " \
    "With wait: false you get a question_id at once and carry on; the answer arrives later as a message naming it."
  argument :question, :string, min_length: 1, max_length: 500
  argument :options, :array, required: false, max_items: 8,
    items: { type: "string", minLength: 1, maxLength: 200 }
  argument :multiple, :boolean, required: false, description: "Whether more than one option may be chosen."
  argument :wait, :boolean, required: false,
    description: "false: don't wait for the answer. Use it when you can carry on without it, or may settle it yourself."
  argument :expires_in_hours, :integer, required: false, minimum: 1, maximum: LONGEST.in_hours.to_i,
    description: "With wait: false, how long the question stays open (default 24). Unanswered by then, it closes and you are told."
  asks :question

  # Whether the call ends at once, naming the question, rather than waiting
  # for the answer (Invocation#asked_later?).
  def later? = arguments["wait"] == false

  def expires_in = (arguments["expires_in_hours"]&.hours if later?)

  # A helper's result is the helper's: an answer told to the agent later
  # would reach an agent that never asked. A question that waits ends when
  # the agent's own wait does (Invocation::WAIT).
  def refusal
    if later? && !Invocation.agents_own?(invocation.call_id)
      "A helper waits for its answer: ask without wait: false."
    elsif arguments.key?("expires_in_hours") && !later?
      "expires_in_hours is for a question asked with wait: false."
    end
  end

  # What a card shows of it: the question, never how the agent waits for it.
  def details(arguments) = arguments.slice("question", "options", "multiple")

  # What the agent reads at once, and on every replay, however it ends.
  def asked = { question_id: invocation.id, expires_at: invocation.expires_at.iso8601, note: ASKED_LATER }

  def call(**)
    answer = invocation.answer or raise Refusal, "The person has not answered."
    { selections: answer.selections, text: answer.text.presence }.compact
  end
end
