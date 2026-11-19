# One agent's own inbox (Agent::MailAccount::Inbox), queued each minute by
# EmailFetchJob, and the moment its server says a message landed (MailIdler).
# One read of an account at a time: a read still running when the next is
# queued drops the next, so two never take the same message. Each account is
# its own job, so one slow or refusing server holds up no other.
class MailAccountFetchJob < ApplicationJob
  queue_as :mail
  limits_concurrency key: ->(mail_account) { mail_account }, duration: 15.minutes, on_conflict: :discard

  def perform(mail_account) = mail_account.fetch_inbox
end
