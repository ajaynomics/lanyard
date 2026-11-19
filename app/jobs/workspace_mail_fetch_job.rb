# A workspace's own catch-all box (Workspace::MailDomain), queued each minute
# by EmailFetchJob, and the moment its server says a message landed
# (MailIdler). One read of a box at a time: a read still running when the
# next is queued drops the next, so two never take the same message.
class WorkspaceMailFetchJob < ApplicationJob
  queue_as :mail
  limits_concurrency key: ->(mail_domain) { mail_domain }, duration: 15.minutes, on_conflict: :discard

  def perform(mail_domain) = mail_domain.fetch_catch_all
end
