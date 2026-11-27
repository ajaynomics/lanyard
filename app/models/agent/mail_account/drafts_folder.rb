# An agent's own mailbox's Drafts folder (#618): where it saves a message for
# its person to review and send from their own mail program (Tool::SaveDraft).
# Saving sends nothing and reaches nobody. Only its own sending account, with
# an incoming server and the vault, signed in as for its inbox; never a
# mailbox it only reads, where nothing is drafted.
module Agent::MailAccount::DraftsFolder
  extend ActiveSupport::Concern

  class Unsaved < StandardError; end

  def saves_drafts? = reads_sent?

  # The folder's name; Unsaved, in our words, when it was not saved.
  def save_draft(raw)
    refuse_sending!
    raise Unsaved, "#{address} has no incoming server to save drafts in." unless saves_drafts?
    DurableAssistants::Email.save_draft(imap_mailbox, raw) or raise Unsaved, "#{imap_host} has no Drafts folder."
  rescue *Agent::MailAccount::Inbox::REFUSED
    raise Unsaved, "#{imap_host} refused the saved sign-in or the draft."
  rescue Agent::MailAccount::SignInError, *Agent::MailAccount::Inbox::UNREACHABLE => problem
    raise Unsaved, problem_in_words(problem)
  end
end
