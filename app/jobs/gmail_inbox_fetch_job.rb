# A slow Gmail mailbox cannot hold up any other inbox; two polls of the same
# mailbox-to-agent binding must not compete over its history cursor.
class GmailInboxFetchJob < ApplicationJob
  queue_as :mail
  limits_concurrency key: ->(gmail_inbox) { gmail_inbox }, duration: 15.minutes, on_conflict: :discard

  def perform(gmail_inbox) = gmail_inbox.fetch
end
