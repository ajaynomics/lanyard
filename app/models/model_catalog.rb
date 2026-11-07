# The models an agent may choose, with the thinking levels each supports. Which
# models is this app's choice (config/pi_durable.yml); which levels is pi-ai's
# fact, so it is asked of the sidecar (GET /v1/models) and kept ten minutes.
# When the sidecar can't say, every allowed model is offered with every level:
# the sidecar runs a model at its nearest supported level anyway.
class ModelCatalog
  # Who pays: an agent's Claude model runs on the subscription or on the API
  # key, never one for the other, so the two labels must differ.
  PROVIDERS = { "anthropic" => "Claude subscription", "anthropic-api" => "Anthropic API key",
                "openai" => "OpenAI API", "openai-codex" => "ChatGPT subscription" }.freeze

  Choice = Data.define(:id, :name, :thinking_levels) do
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

  # Allowed models the sidecar can run now, and the agent's current model even
  # when it can't, so its settings still show what it has.
  def choices(including: nil)
    Agent.models.filter_map do |id|
      model = catalogue&.dig(id)
      next unless catalogue.nil? || model || id == including
      levels = Array(model&.dig("thinkingLevels")) & Agent::THINKING_LEVELS
      Choice.new(id: id, name: model&.dig("name").presence || id, thinking_levels: levels.presence || Agent::THINKING_LEVELS)
    end
  end

  # What `/model <words>` means, read loosely as pi's /model reads it: the
  # route itself, else every model on offer whose route or name contains the
  # words. One match is the person's choice; several are a question back.
  def matching(words)
    words = words.to_s.strip.downcase
    return [] if words.empty?
    offered = choices
    offered.select { it.id == words }.presence || offered.select { it.id.include?(words) || it.name.downcase.include?(words) }
  end

  # Where the sidecar summarises a conversation on this model, in tokens
  # (nil when it can't say).
  def compact_at(id)
    value = catalogue&.dig(id, "compactAt")
    value if value.is_a?(Integer) && value.positive?
  end

  private
    def catalogue
      return @catalogue if defined?(@catalogue)
      @catalogue = Rails.cache.fetch("pi_durable/models", expires_in: 10.minutes) do
        Array(DurableAssistants::PiDurable::Client.new.models["models"]).select { it.is_a?(Hash) && it["id"].is_a?(String) }.index_by { it["id"] }
      end
    rescue DurableAssistants::PiDurable::Client::Error
      @catalogue = nil
    end
end
