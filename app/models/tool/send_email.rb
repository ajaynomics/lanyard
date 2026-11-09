# Sends mail from the agent's own address. Mail to the install's admitted
# people goes at once; to anyone else the person approves the exact message
# first, as with any tool that reaches outside.
class Tool::SendEmail < Tool
  description "Send an email from your own address. To reply to an email you were sent, pass its message id as in_reply_to " \
    "and keep its subject with Re: in front, so it stays in the same thread. Mail to anyone but the people you work with " \
    "waits for the person's approval."
  argument :to, :array, items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 }, min_items: 1, max_items: 10
  argument :subject, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: 64_000, description: "Plain text."
  argument :in_reply_to, :string, required: false, max_length: 998, pattern: "^[^<>\\s]+$",
    description: "The message id of the email this answers, as it was given to you."
  asks :approval
  reaches_others
  effect :external

  # Only mail that leaves the install's own people waits for a person.
  def asks = invocation.arguments["to"].to_a.all? { Admission.admits?(it) } ? nil : super

  def permitted? = DurableAssistants::Email.configured?

  def recipients = invocation.arguments["to"].to_a.map { it.strip.downcase }.uniq

  def call(to:, subject:, body:, in_reply_to: nil)
    message = AgentMailer.message_from(agent, to: to, subject: subject, body: body, in_reply_to: in_reply_to).deliver_now
    { sent: to, messageId: message.message_id }
  end
end
