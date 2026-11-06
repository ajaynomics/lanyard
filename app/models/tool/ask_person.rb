class Tool::AskPerson < Tool
  description "Ask the person a question when the choice is theirs. Offer options when you can; the answer is the result."
  argument :question, :string, min_length: 1, max_length: 500
  argument :options, :array, required: false, max_items: 8,
    items: { type: "string", minLength: 1, maxLength: 200 }
  argument :multiple, :boolean, required: false, description: "Whether more than one option may be chosen."
  asks :question

  def call(**)
    answer = invocation.answer or raise Refusal, "The person has not answered."
    { selections: answer.selections, text: answer.text.presence }.compact
  end
end
