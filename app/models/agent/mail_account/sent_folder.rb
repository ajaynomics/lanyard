# An agent's own mailbox's Sent folder: the one question asked of it about
# what it sent, does it hold this message? Asked only after a send whose
# answer never came (Tool::SendEmail, Dispatch#check), only of the account
# the message went through, and only by the Message-ID the app gave it.
# Nothing is read or kept beyond the answer.
#
# And the one thing written there: a copy of each message the server took
# through this account (AgentMailer), as a mail program files it, since
# some servers file nothing sent over SMTP and the person would never see
# it, nor the question above find it (#225). Only once the server answered:
# a copy of mail whose answer never came would vouch for it here. Signed in
# as for its inbox (Agent::MailAccount::Inbox), with the same rules for
# where the password may go.
module Agent::MailAccount::SentFolder
  extend ActiveSupport::Concern

  class Unreadable < StandardError; end

  # Mail it sends can be looked for: it has an incoming server, and the vault.
  def reads_sent? = !read_only? && imap_host.present? && usable?

  # True or false; Unreadable, in our words, when it can't be asked.
  def sent?(message_id)
    raise Unreadable, "#{address} has no incoming server to look in." unless reads_sent?
    found = DurableAssistants::Email.sent?(imap_mailbox, message_id)
    raise Unreadable, "#{imap_host} has no Sent folder." if found.nil?
    found
  rescue Agent::MailAccount::SignInError, *Agent::MailAccount::Inbox::UNREACHABLE => problem
    raise Unreadable, problem_in_words(problem)
  end

  # The mail has gone whatever happens here: a copy not filed fails nothing,
  # or the agent, told it failed, would send it again. So anything at all is
  # logged, by its kind alone, never the server's words or the message.
  def file_in_sent(raw)
    return unless reads_sent?
    DurableAssistants::Email.file_sent(imap_mailbox, raw) or not_filed("no Sent folder")
  rescue StandardError => problem
    not_filed(problem.class.name)
  end

  private
    def not_filed(why) = Rails.logger.warn("Mail account #{id}: sent mail not filed in Sent (#{why})")
end
