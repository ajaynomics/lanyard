# A provider keeps the prompt a model call read for a few minutes, and a later
# call that begins with the same words reads them back from that cache, fast
# and at a tenth of the price. The cache lasts from when it was last read: an
# hour for Anthropic's models, which the sidecar asks for, and a few minutes
# for OpenAI's (cache_ttl). Anything that
# changes the start of the prompt (the agent's instructions, notes, skills,
# tools or model, or a summary of earlier messages) starts it over.
#
# A reply that read back much less than the reply before it put in the cache
# missed it: everything before was read again in full. That is told when the
# reply is recorded, with the likeliest reason, and shown under it
# (messages/_message). docs/prompt-cache.md says the whole of it.
module Message::PromptCache
  extend ActiveSupport::Concern

  SHORT = 5.minutes
  LONG = 1.hour
  # Providers cache nothing shorter (Anthropic's floor is 1,024 to 4,096
  # tokens by model), so a short prompt is never said to have missed.
  MINIMUM = 4_096

  included do
    before_create :note_cache_miss, if: -> { role == "assistant" && prompt_tokens.positive? }
  end

  # Everything the model read for this reply: new words, words read back from
  # the cache, and words written to it.
  def prompt_tokens = usage.to_h.values_at("input", "cacheRead", "cacheWrite").sum(&:to_i)

  # The share of that read back from the cache, from 0 to 1.
  def cache_hit_rate = (usage["cacheRead"].to_i.fdiv(prompt_tokens) if prompt_tokens.positive?)

  # Whether the provider cached anything for this reply at all; one that
  # never caches has no misses to tell.
  def cached? = usage.to_h.values_at("cacheRead", "cacheWrite").sum(&:to_i).positive?

  # How long this reply's cache lasts: Anthropic's an hour (the sidecar's
  # cacheRetention), anyone else's the provider's few minutes.
  def cache_ttl = cache_model.to_s.start_with?("anthropic") ? LONG : SHORT

  # When this reply's cache lapses, if it made one worth keeping.
  def cache_expires_at = (created_at + cache_ttl if cached? && prompt_tokens >= MINIMUM)

  # How long before it lapses the thread starts to say so: the last minute of
  # a short cache, the last five of an hour's.
  def cache_warning = cache_ttl >= LONG ? 5.minutes : 1.minute

  # { "tokens" => this reply's words not read from the cache, "reason" =>
  #   summary | model | idle | changed, "idle" => seconds since the reply
  #   before, "before" => that reply's whole prompt }, or nil for a hit.
  def cache_miss = usage.to_h["cacheMiss"]

  private
    # A reply recorded before replies named their model ran on the agent's.
    def cache_model = usage.to_h["model"] || conversation&.agent&.model

    def note_cache_miss
      before = conversation.messages.where(role: "assistant").where(entry_id: ..entry_id).order(entry_id: :desc, id: :desc)
        .limit(20).detect { it.prompt_tokens.positive? }
      return unless before&.cached? && before.prompt_tokens >= MINIMUM
      read = usage["cacheRead"].to_i
      return if read >= before.prompt_tokens / 2

      idle = ((created_at || Time.current) - before.created_at).round
      reason =
        if conversation.messages.where(role: "summary", entry_id: before.entry_id..entry_id).exists? then "summary"
        elsif before.usage["model"] && usage["model"] && before.usage["model"] != usage["model"] then "model"
        elsif idle > before.cache_ttl then "idle"
        else "changed"
        end
      # What this reply read in full, not the prompt before less what it read
      # back: after a summary that counted the words summarised away.
      fresh = usage.to_h.values_at("input", "cacheWrite").sum(&:to_i)
      self.usage = usage.merge("cacheMiss" => { "tokens" => fresh, "reason" => reason, "idle" => idle, "ttl" => before.cache_ttl.to_i,
                                                "before" => before.prompt_tokens })
    end
end
