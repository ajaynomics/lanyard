# Only these reviewed presets are selectable; a form value never names a file.
class Agent::Template < Data.define(:key, :name, :description, :purpose)
  KEYS = %w[ general research inbox_admin builder ].freeze

  def self.all
    presets = YAML.safe_load_file(Rails.root.join("config/agent_templates.yml"))
    KEYS.map do |key|
      preset = presets.fetch(key)
      new(key, preset.fetch("name"), preset.fetch("description"), preset["purpose"])
    end
  end
end
