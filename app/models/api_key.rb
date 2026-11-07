# An API key the agents reach a provider with, beside its subscription and
# never instead of it: an agent's model names which one it uses
# (anthropic-api/… is the key, anthropic/… the subscription). The owner pastes
# it here; Rails passes it straight to the sidecar, which checks it with the
# provider, keeps it encrypted, and shows back only its last four characters.
# Rails never stores it. Each change names the version the page saw, as a
# Subscription's do.
class ApiKey
  PROVIDERS = { "anthropic-api" => "Claude" }.freeze

  attr_reader :provider

  def self.all = PROVIDERS.keys.map { find(it) }

  def self.find(provider)
    raise ActiveRecord::RecordNotFound unless PROVIDERS.key?(provider)
    new(provider, client.api_key(provider))
  rescue DurableAssistants::PiDurable::Client::Error => error
    raise unless error.category == "subscription_not_configured"
    new(provider, nil)
  end

  def self.client = DurableAssistants::PiDurable::Client.new

  def initialize(provider, state)
    @provider = provider
    @state = state
  end

  def update(key:, version:) = client.save_api_key(provider, version.to_i, key.to_s.strip)

  def destroy(version) = client.remove_api_key(provider, version.to_i)

  # "Claude".
  def service = PROVIDERS.fetch(provider)

  def name = "#{service} API key"

  # Whether this server has a place for a key at all (docs/agent.md).
  def configured? = !@state.nil?

  def set? = @state&.dig("connected") == true

  def version = @state&.dig("version")

  # The key's last four characters, all the sidecar ever shows of it.
  def hint
    hint = @state&.dig("hint")
    hint if hint.is_a?(String) && hint.match?(/\A[\x21-\x7e]{4}\z/)
  end

  def to_param = provider

  private
    def client = self.class.client
end
