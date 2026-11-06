# The models a bot may choose, with the thinking levels each supports. Which
# models is this app's choice (config/pi_durable.yml); which levels is pi-ai's
# fact, so it is asked of the sidecar (GET /v1/models) and kept ten minutes.
# When the sidecar can't say, every allowed model is offered with every level:
# the sidecar runs a model at its nearest supported level anyway.
class ModelCatalog
  PROVIDERS = { "anthropic" => "Anthropic", "openai" => "OpenAI API", "openai-codex" => "ChatGPT subscription" }.freeze

  Choice = Data.define(:id, :name, :thinking_levels) do
    def label
      provider = PROVIDERS[id.split("/").first]
      provider ? "#{name} (#{provider})" : name
    end

    # The level to show selected: the bot's own when this model has it.
    def level_for(level)
      return level if thinking_levels.include?(level)
      thinking_levels.include?("medium") ? "medium" : thinking_levels.first
    end
  end

  def self.choices(including: nil) = new.choices(including: including)

  # Allowed models the sidecar can run now, and the bot's current model even
  # when it can't, so its settings still show what it has.
  def choices(including: nil)
    Bot.models.filter_map do |id|
      model = catalogue&.dig(id)
      next unless catalogue.nil? || model || id == including
      levels = Array(model&.dig("thinkingLevels")) & Bot::THINKING_LEVELS
      Choice.new(id: id, name: model&.dig("name").presence || id, thinking_levels: levels.presence || Bot::THINKING_LEVELS)
    end
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
