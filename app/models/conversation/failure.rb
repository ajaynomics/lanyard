# Why a run stopped, in words a person can act on, by the kind of failure the
# sidecar reports. The thread says it after "Stopped"; a notification says it
# whole, and only for a kind it knows.
module Conversation::Failure
  TEXTS = {
    "compaction_failed" => "couldn't summarise earlier messages. Type /compact to try again.",
    "rate_limited" => "the model's usage limit is reached. Try again later, or switch subscription in settings.",
    "computers_busy" => "too many computers are awake; try again shortly.",
    "stalled" => "the agent stopped making progress, so its turn was ended. Send your message again.",
    "request_limit" => "this turn hit the safety stop on model requests, in case it was stuck in a loop. Send a message to carry on.",
    "request_timeout" => "the model sent nothing for five minutes, so the request was given up. Send a message to try again.",
    "credential_missing" => "this model isn't signed in, or its sign-in can't be opened. Sign in again on the Subscriptions page, or save an API key there."
  }.freeze

  def self.text(reason) = TEXTS.fetch(reason.to_s) { reason.to_s.tr("_", " ") }

  def self.sentence(reason)
    known = TEXTS[reason.to_s]
    known ? "Stopped: #{known}" : "Stopped before finishing. Open the conversation to see why."
  end
end
