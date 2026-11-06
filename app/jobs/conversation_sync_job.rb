class ConversationSyncJob < ApplicationJob
  # Pings arrive in bursts while a run streams; pulls of one conversation
  # run one at a time, and each pulls everything committed so far.
  limits_concurrency key: ->(conversation) { conversation }
  retry_on DurableAssistants::PiDurable::Client::Error, wait: 2.seconds, attempts: 3

  def perform(conversation)
    conversation.sync!
    conversation.clear_live unless conversation.busy?
  end
end
