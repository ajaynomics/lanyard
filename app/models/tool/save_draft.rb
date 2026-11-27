# Saves an email as a draft in the agent's own mail account's Drafts folder
# (#618), for its person to review and send from their own mail program.
# Saving sends nothing and reaches nobody, so it asks no one first; sending
# stays send_email's, asked as ever. Only its own sending account, never a
# mailbox it only reads (Agent::MailAccount::DraftsFolder).
class Tool::SaveDraft < Tool
  description "Save an email as a draft in your own mail account's Drafts folder, for the person to review and send from their mail " \
    "program. Nothing is sent. To draft a reply, pass the message id of the email it answers as in_reply_to and keep its subject " \
    "with Re: in front."
  argument :to, :array, **Tool::SendEmail::ADDRESSES, min_items: 1
  argument :cc, :array, **Tool::SendEmail::ADDRESSES, required: false, description: "Addresses to copy, shown to every recipient."
  argument :subject, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: 64_000, description: DurableAssistants::EmailBody::DESCRIPTION
  argument :in_reply_to, :string, required: false, max_length: 998, pattern: "^[^<>\\s]+$",
    description: "The message id of the email this answers, as it was given to you."
  effect :external

  def permitted? = !!agent.mail_account&.saves_drafts?

  def call(to:, subject:, body:, cc: [], in_reply_to: nil)
    account = agent.mail_account
    raw = AgentMailer.draft(account, to: to, cc: cc, subject: subject, body: body, in_reply_to: in_reply_to).message.encoded
    { saved: account.save_draft(raw), to: to, subject: subject }
  rescue Agent::MailAccount::DraftsFolder::Unsaved, Agent::MailAccount::ReadOnly => error
    raise Refusal, "The draft wasn't saved: #{error.message}"
  end
end
