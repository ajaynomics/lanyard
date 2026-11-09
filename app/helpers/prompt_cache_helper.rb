# The prompt cache in words (Message::PromptCache): under a reply that missed
# it, where the thread ends, and on the settings pages whose changes start it
# over. "Read again in full" is what a miss costs, whoever pays: an API key at
# the full price, a subscription out of its usage limit.
module PromptCacheHelper
  CACHE_MISS_REASONS = {
    "summary" => "after earlier messages were summarised",
    "model" => "after the model changed",
    "changed" => "after the agent's instructions, notes, skills or tools changed"
  }.freeze

  # "Cache missed: 84k tokens read again in full, after 12 minutes idle (the cache keeps 5)."
  def cache_miss_line(message)
    return unless (miss = message.cache_miss)
    why = if miss["reason"] == "idle"
      "after #{distance_of_time_in_words(miss["idle"].to_i)} idle (the cache keeps #{Message::PromptCache::TTL.in_minutes.to_i})"
    else
      CACHE_MISS_REASONS[miss["reason"]]
    end
    "Cache missed: #{thousands(miss["tokens"].to_i)} tokens read again in full, #{why}."
  end

  # "Cache: 96% of the last prompt, 88% over this agent", as pi's footer counts it.
  def cache_line(conversation, reply)
    last = reply&.cache_hit_rate if reply&.cached?
    totals = conversation.usage.to_h
    read = totals["cacheRead"].to_i
    overall = read.fdiv(totals.values_at("input", "cacheRead", "cacheWrite").sum(&:to_i)) if read.positive?
    return unless last || overall
    [ ("#{percent(last)} of the last prompt" if last), ("#{percent(overall)} over this agent" if overall) ].compact
      .join(", ").then { "Cache: #{it}" }
  end

  # What the thread's end says of the cache, kept current by cache_timer_controller,
  # which says the same three things.
  def cache_timer_text(expires_at, tokens)
    left = expires_at - Time.current
    if left <= 0 then "Cache lapsed: your next message reads all #{tokens} tokens again."
    elsif left <= 60 then "Cache lapses in under a minute. After that, your next message reads all #{tokens} tokens again."
    else "Cache warm for #{pluralize((left / 60).ceil, "more minute")}."
    end
  end

  def cache_level(expires_at)
    left = expires_at - Time.current
    left <= 0 ? "over" : left <= 60 ? "near" : "warm"
  end

  def cache_minutes = pluralize(Message::PromptCache::TTL.in_minutes.to_i, "minute")

  def percent(rate) = number_to_percentage(rate * 100, precision: 0)
end
