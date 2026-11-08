# An API key the agents reach a provider with, beside its subscription and
# never instead of it: an agent's model names which one it uses
# (anthropic-api/… is the key, anthropic/… the subscription). The owner pastes
# it here; Rails passes it straight to the sidecar, which checks it with the
# provider, keeps it encrypted, and shows back only its last four characters.
# Rails never stores it. Each change names the version the page saw, as a
# Subscription's do.
class ApiKey
  include ProviderAccess

  PROVIDERS = { "anthropic-api" => "Claude" }.freeze

  def update(key:, version:) = client.save_api_key(provider, version.to_i, key.to_s.strip)

  def destroy(version) = client.remove_api_key(provider, version.to_i)

  def name = "#{service} API key"

  def set? = @state&.dig("connected") == true

  # The key's last four characters, all the sidecar ever shows of it.
  def hint
    hint = @state&.dig("hint")
    hint if hint.is_a?(String) && hint.match?(/\A[\x21-\x7e]{4}\z/)
  end
end
