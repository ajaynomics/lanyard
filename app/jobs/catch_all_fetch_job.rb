# The install's catch-all box (docs/email.md), deliberately global: new mail
# in it goes to Action Mailbox, which routes it to the agents it names
# (AgentsMailbox), whoever owns them. Texts arrive here too, forwarded as
# mail (docs/phone.md).
#
# Queued each minute by EmailFetchJob, and the moment the server says a
# message landed (MailIdler). One read of the box at a time: a read still
# running when the next is queued drops the next, so two never take the same
# message. Where it got to is kept in the cache: lost, the box is read from
# the start, and Action Mailbox drops the messages it has.
class CatchAllFetchJob < ApplicationJob
  queue_as :mail
  limits_concurrency key: "email", duration: 15.minutes, on_conflict: :discard

  def perform
    return unless DurableAssistants::Email.inbox?
    validity, after = Rails.cache.read("email/last_uid") || [ nil, 0 ]
    DurableAssistants::Email.fetch(after: after, validity: validity) do |current, uid, raw|
      ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
      Rails.cache.write("email/last_uid", [ current, uid ])
    end
  end
end
