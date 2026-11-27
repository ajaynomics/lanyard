# The models an agent may choose, with the thinking levels each supports. Which
# models is this app's choice (config/pi_durable.yml); which levels is pi-ai's
# fact, so it is asked of the sidecar (GET /v1/models) and kept ten minutes.
# When the sidecar can't say, every allowed model is offered with every level:
# the sidecar runs a model at its nearest supported level anyway.
class ModelCatalog
  # Who pays: an agent's Claude model runs on the subscription or on the API
  # key, never one for the other, so the two labels must differ.
  # openai-chatgpt is a ChatGPT sign-in borrowed from a lender (docs/agent.md,
  # "Lending a subscription"); an install has it or openai-codex, never both.
  PROVIDERS = { "anthropic" => "Claude subscription", "anthropic-api" => "Anthropic API key",
                "openai" => "OpenAI API", "openai-codex" => "ChatGPT subscription",
                "openai-chatgpt" => "ChatGPT subscription" }.freeze

  # Who pays, as a settings row says it under the model's name.
  SOURCES = { "anthropic" => "Subscription", "anthropic-api" => "API key", "openai" => "API key",
              "openai-codex" => "Subscription", "openai-chatgpt" => "Subscription" }.freeze

  Choice = Data.define(:id, :name, :thinking_levels) do
    def source = SOURCES[id.split("/").first]

    # "Claude Haiku 5.5 · Subscription", where a menu has one line for both.
    def option_label = [ name, source ].compact.join(" · ")

    def label
      provider = PROVIDERS[id.split("/").first]
      provider ? "#{name} (#{provider})" : name
    end

    # In a sentence, with who pays and the route to type.
    def described
      provider = PROVIDERS[id.split("/").first]
      "#{name}#{" on the #{provider}" if provider} (#{id})"
    end

    # The level to show selected: the agent's own when this model has it.
    def level_for(level)
      return level if thinking_levels.include?(level)
      thinking_levels.include?("medium") ? "medium" : thinking_levels.first
    end
  end

  def self.choices(including: nil) = new.choices(including: including)
  def self.matching(words) = new.matching(words)
  def self.compact_at(id) = new.compact_at(id)
  def self.context_window(id) = new.context_window(id)

  # Subscriptions whose models are offered only once someone has signed in:
  # until then, choosing one would only stop the next run as "not signed in".
  # Claude's models are offered either way, since a new install's default
  # model is one of them.
  SIGNED_IN_FIRST = %w[ openai-codex openai-chatgpt ].freeze

  # Allowed models the sidecar can run now, and the agent's current model even
  # when it can't, or is no longer allowed, so its settings still show what it
  # has and saving them never changes it.
  def choices(including: nil)
    (Agent.models | [ including ].compact_blank).filter_map do |id|
      model = catalogue&.dig(id)
      next unless id == including || ((catalogue.nil? || model) && signed_in_for?(id))
      levels = Array(model&.dig("thinkingLevels")) & Agent::THINKING_LEVELS
      Choice.new(id: id, name: model&.dig("name").presence || self.class.plain_name(id), thinking_levels: levels.presence || Agent::THINKING_LEVELS)
    end
  end

  # A route as words, when the sidecar can't name it: anthropic/claude-haiku-5-5
  # is "Claude Haiku 5.5", openai-codex/gpt-6.1-sol "GPT 6.1 Sol".
  def self.plain_name(id)
    words = id.to_s.split("/").last.to_s.split("-")
    words.slice_when { |before, after| !(before.match?(/\A\d+\z/) && after.match?(/\A\d+\z/)) }.map { it.join(".") }
      .map { it.casecmp?("gpt") ? "GPT" : it.capitalize }.join(" ")
  end

  # The choice an agent's model is, named in words even when it is no longer offered.
  def self.choice_for(id) = choices(including: id).find { it.id == id } || Choice.new(id: id, name: plain_name(id), thinking_levels: Agent::THINKING_LEVELS)

  # What `/model <words>` means, read loosely as pi's /model reads it: the
  # route itself, else every model on offer whose route or name contains the
  # words. One match is the person's choice; several are a question back.
  def matching(words)
    words = words.to_s.strip.downcase
    return [] if words.empty?
    offered = choices
    offered.select { it.id == words }.presence || offered.select { it.id.include?(words) || it.name.downcase.include?(words) }
  end

  # The models an agent's helpers may run on: those its settings offer, each
  # by its route, name and label as they show it, for the sidecar to choose
  # from (agent/subagent.mjs chooseModel).
  def self.for_helpers = choices.map { { id: it.id, name: it.name, label: it.option_label } }

  # A helper's model and thinking, by the words an agent gave (Tool::RunWorkflow),
  # read as the sidecar reads a `subagent` call's: a model by its label, its
  # route, or its name where only one has it; a level that model has. Returns
  # the route and level, each nil where the agent gave none, so its helper runs
  # on the agent's own. Anything else raises Unoffered, in words, with the
  # choices; a model is never swapped for another.
  class Unoffered < StandardError; end
  def self.for_helper(agent, model: nil, thinking: nil) = new.for_helper(agent, model: model, thinking: thinking)

  def for_helper(agent, model:, thinking:)
    return [ nil, nil ] if model.nil? && thinking.nil?
    choice = model.nil? ? (choices.find { it.id == agent.model } || self.class.choice_for(agent.model)) : offered_named(model)
    if thinking && choice.thinking_levels.exclude?(thinking)
      raise Unoffered, "#{choice.option_label} can't think at “#{thinking}”. Its levels: #{choice.thinking_levels.join(", ")}."
    end
    [ (choice.id if model), thinking ]
  end

  # Where the sidecar summarizes a conversation on this model, in tokens
  # (nil when it can't say).
  def compact_at(id)
    value = catalogue&.dig(id, "compactAt")
    value if value.is_a?(Integer) && value.positive?
  end

  # How much the model can read at once, in tokens (nil when the sidecar can't say).
  def context_window(id)
    value = catalogue&.dig(id, "contextWindow")
    value if value.is_a?(Integer) && value.positive?
  end

  # A sign-in or sign-out changes what is offered at once, not ten minutes later.
  def self.forget = Rails.cache.delete(cache_key)

  CACHE_KEY = "pi_durable/catalogue"

  def self.cache_key(client = DurableAssistants::PiDurable::Client.new)
    [ CACHE_KEY, client.models_cache_generation ].compact.join("/")
  end

  private
    def offered_named(model)
      words = model.to_s.strip.downcase
      found = choices.select { it.id == words || it.option_label.downcase == words }.presence || choices.select { it.name.downcase == words }
      raise Unoffered, "“#{model}” is more than one model here. Name one: #{found.map(&:option_label).join(", ")}." if found.many?
      found.first || raise(Unoffered, "There is no model “#{model}” for a helper here. Choose one of: #{choices.map(&:option_label).join(", ")}.")
    end

    def signed_in_for?(id)
      provider = id.split("/").first
      SIGNED_IN_FIRST.exclude?(provider) || answer&.dig("signed_in")&.include?(provider)
    end

    def catalogue = answer&.dig("models")

    # The sidecar's answer: its models by route, and the subscriptions signed in now.
    def answer
      return @answer if defined?(@answer)
      client = DurableAssistants::PiDurable::Client.new
      @answer = Rails.cache.fetch(self.class.cache_key(client), expires_in: 10.minutes) do
        found = client.models
        { "models" => Array(found["models"]).select { it.is_a?(Hash) && it["id"].is_a?(String) }.index_by { it["id"] },
          "signed_in" => Array(found["signedIn"]).grep(String) }
      end
    rescue DurableAssistants::PiDurable::Client::Error
      @answer = nil
    end
end
