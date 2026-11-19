# Why a run stopped, in words a person can act on, by the kind of failure the
# sidecar reports. The thread says it after "Stopped"; a notification says it
# whole, and only for a kind it knows.
module Conversation::Failure
  TEXTS = {
    "compaction_failed" => "couldn't summarize earlier messages. Type /compact to try again.",
    "compaction_refused" => "the model's provider refused to summarize earlier messages (safety filter). Switching model may help, or type /compact to try again.",
    "rate_limited" => "the model's usage limit is reached. Try again later, or switch subscription in settings.",
    "computers_busy" => "too many computers are awake; try again shortly.",
    "computer_held" => "this computer is being rebuilt; try again shortly.",
    "stalled" => "the agent stopped making progress, so its turn was ended. Send your message again.",
    "request_limit" => "this turn hit the safety stop on model requests, in case it was stuck in a loop. Send a message to carry on.",
    "request_timeout" => "the model sent nothing for five minutes, so the request was given up. Send a message to try again.",
    "credential_missing" => "this model isn't signed in, or its sign-in can't be opened. Sign in again on the Subscriptions page, or save an API key there."
  }.freeze

  # Why the sidecar refused a send for good, by its category: said when a
  # person's send fails, and when a held one is set aside (Conversation::Holding).
  REFUSALS = {
    "computer_unavailable" => "This agent's computer is not available here. Turn it off in its settings, or ask for it to be set up.",
    "model_unavailable" => "This agent's model is not available here. Choose another in its settings.",
    "tool_limit" => "This agent has more tools than it can be given. In its Tools settings, make a connector looked up rather than core, or switch some tools off."
  }.freeze

  # Why the newest summary failed, under the thread, by the kind the sidecar
  # reports (Sidecar::FramesController::COMPACTION_FAILURES).
  COMPACTION_TEXTS = {
    "refused" => "Couldn't summarize earlier messages: the model's provider refused (safety filter). Switching model may help, or type /compact to try again.",
    "rate_limited" => "Couldn't summarize earlier messages: the model's usage limit is reached. Type /compact to try again later."
  }.freeze

  def self.text(reason) = TEXTS.fetch(reason.to_s) { reason.to_s.tr("_", " ") }

  def self.compaction_text(reason) = COMPACTION_TEXTS.fetch(reason.to_s, "Couldn't summarize earlier messages. Type /compact to try again.")

  def self.sentence(reason)
    known = TEXTS[reason.to_s]
    known ? "Stopped: #{known}" : "Stopped before finishing. Open the conversation to see why."
  end
end
