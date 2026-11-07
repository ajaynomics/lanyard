# Every minute (config/recurring.yml), deliberately global: new mail in the install's catch-all box
# goes to Action Mailbox, which routes it to the agents it names
# (AgentsMailbox). Where it got to is kept in the cache: lost, the job reads
# the box from the start, and Action Mailbox drops the messages it has.
class EmailFetchJob < ApplicationJob
  limits_concurrency key: "email"

  def perform
    return unless DurableAssistants::Email.inbox?
    validity, after = Rails.cache.read("email/last_uid") || [ nil, 0 ]
    DurableAssistants::Email.fetch(after: after, validity: validity) do |current, uid, raw|
      ActionMailbox::InboundEmail.create_and_extract_message_id!(raw)
      Rails.cache.write("email/last_uid", [ current, uid ])
    end
  end
end
