# What a Subscription and an ApiKey share: the sidecar's answer about how the
# agents reach one provider (GET /v1/subscriptions/:provider), which holds
# both. A server with no place for either answers subscription_not_configured.
module ProviderAccess
  extend ActiveSupport::Concern

  class_methods do
    def all = self::PROVIDERS.keys.map { find(it) }

    def find(provider)
      raise ActiveRecord::RecordNotFound unless self::PROVIDERS.key?(provider)
      new(provider, client.subscription(provider))
    rescue DurableAssistants::PiDurable::Client::Error => error
      raise unless error.category == "subscription_not_configured"
      new(provider, nil)
    end

    def client = DurableAssistants::PiDurable::Client.new
  end

  included do
    attr_reader :provider
  end

  def initialize(provider, state)
    @provider = provider
    @state = state
  end

  # "Claude", "ChatGPT".
  def service = self.class::PROVIDERS.fetch(provider)

  # Whether this server has a place for it at all (docs/agent.md).
  def configured? = !@state.nil?

  def version = @state&.dig("version")

  def to_param = provider

  private
    def client = self.class.client
end
