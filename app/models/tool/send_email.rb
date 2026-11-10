# Sends mail from the agent's own address. Mail to the install's admitted
# people goes at once; to anyone else the person approves the exact message
# first, as with any tool that reaches outside. Files from the agent's
# computer go with it: the card names each, and the approval holds to their
# bytes, so a file changed after it is approved asks again.
class Tool::SendEmail < Tool
  description "Send an email from your own address. To reply to an email you were sent, pass its message id as in_reply_to " \
    "and keep its subject with Re: in front, so it stays in the same thread. Mail to anyone but the people you work with " \
    "waits for the person's approval."
  argument :to, :array, items: { type: "string", pattern: "^[^@\\s<>,]+@[^@\\s<>,]+$", maxLength: 254 }, min_items: 1, max_items: 10
  argument :subject, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: 64_000, description: "Plain text."
  argument :in_reply_to, :string, required: false, max_length: 998, pattern: "^[^<>\\s]+$",
    description: "The message id of the email this answers, as it was given to you."
  argument :attachments, :array, required: false, items: { type: "string", minLength: 1, maxLength: 1_024 }, max_items: 10, unique_items: true,
    description: "Paths of files on your computer to attach, up to 10."
  reads_files :attachments, each: -> { DurableAssistants::Email.attachment_bytes }, total: -> { DurableAssistants::Email.attachments_bytes }
  asks :approval
  reaches_others
  effect :external

  # Only mail that leaves the install's own people waits for a person.
  def asks = invocation.arguments["to"].to_a.all? { Admission.admits?(it) } ? nil : super

  def permitted? = DurableAssistants::Email.configured?

  def recipients = invocation.arguments["to"].to_a.map { it.strip.downcase }.uniq

  # The card shows the message with its files' names and sizes, and the
  # approval binds their bytes (Invocation#changed_since_approved?).
  def previews? = paths.any?

  def preview
    found = files
    return { "error" => "#{(paths - found.map(&:path)).first} didn't arrive from the computer. Ask the agent to send again." } if found.size < paths.size
    { "to" => invocation.arguments["to"], "subject" => invocation.arguments["subject"],
      "attachments" => found.map { "#{it.name} (#{ActiveSupport::NumberHelper.number_to_human_size(it.size)})" },
      "body" => invocation.arguments["body"], "digest" => Digest::SHA256.hexdigest(found.map { [ it.path, it.sha256 ] }.to_json) }
  end

  def call(to:, subject:, body:, in_reply_to: nil, attachments: [])
    found = files
    raise Tool::Refusal, "#{(attachments - found.map(&:path)).first} didn't arrive from your computer, so nothing was sent. Send again." if found.size < attachments.size
    message = AgentMailer.message_from(agent, to: to, subject: subject, body: body, in_reply_to: in_reply_to,
      files: found.map { [ it.name, it.file.download ] }).deliver_now
    invocation.uploads.destroy_all
    { sent: to, messageId: message.message_id, attached: (found.map(&:name) if found.any?) }.compact
  end

  private
    def paths = invocation.arguments["attachments"].to_a

    # In the order the agent listed them.
    def files = invocation.uploads.where(path: paths).includes(file_attachment: :blob).sort_by { paths.index(it.path) }
end
