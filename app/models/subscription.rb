# A subscription the agents reach a provider through: one grant per provider for
# this app, held encrypted by the sidecar and never seen by Rails. This is the
# sidecar's answer about it (GET /v1/subscriptions/:provider), and the three
# things the owner console can do to it. Each change names the version the
# page saw, so two tabs can't undo each other.
class Subscription
  include ProviderAccess

  # openai-chatgpt is ChatGPT borrowed from a lender, never signed in here.
  PROVIDERS = { "anthropic" => "Claude", "openai-codex" => "ChatGPT", "openai-chatgpt" => "ChatGPT" }.freeze
  SIGN_IN_PAGES = { "anthropic" => "https://claude.ai/oauth/authorize", "openai-codex" => "https://auth.openai.com/oauth/authorize" }.freeze

  # One row per service: ChatGPT's own sign-in or the borrowed one, whichever
  # this server has, and the first when it has neither.
  def self.all = super.group_by(&:service).flat_map { |_, same| same.select(&:configured?).presence || same.first(1) }

  def start(version) = self.class.new(provider, client.start_subscription(provider, version.to_i))

  # Each changes which models the agents are offered (ModelCatalog::SIGNED_IN_FIRST).
  def finish(version:, id:, code:)
    client.finish_subscription(provider, version.to_i, id.to_s, code.to_s)
  ensure
    ModelCatalog.forget
  end

  def disconnect(version)
    client.disconnect_subscription(provider, version.to_i)
  ensure
    ModelCatalog.forget
  end

  def name = "#{service} subscription"

  def connected? = @state&.dig("connected") == true

  def reconnect_required? = @state&.dig("reconnectRequired") == true

  # A grant is saved, but for another scope: the install's name
  # (AGENT_APPLICATION) or SUBSCRIPTION_VAULT_SCOPE changed since the sign-in.
  def sealed_elsewhere? = @state&.dig("sealedElsewhere") == true

  def expires_at = parse(@state&.dig("expiresAt"))

  # Another holder's sign-in, borrowed (docs/agent.md, "Lending a
  # subscription"): this one has none of its own to start or end, and the
  # lender's name says whose it is.
  def borrowed? = @state&.dig("borrowed") == true

  def lender = @state&.dig("lender").presence

  # The install's Claude routes, in its order (docs/agent.md, "Claude
  # routes"): which one calls go to now, and any at its usage limit, with
  # when it resets if Anthropic said.
  Route = Data.define(:name, :state, :fallback, :reset_at) do
    def limited? = state == "limited"
    def active? = state == "active"
  end

  def routes
    Array(@state&.dig("routes")).map do |route|
      Route.new(name: route["name"].to_s, state: route["state"].to_s, fallback: route["fallback"] == true, reset_at: parse(route["resetAt"]))
    end
  end

  # The sign-in link, in start's answer only; never in a page loaded later.
  # Only ever the provider's own sign-in page.
  def authorization_url
    url = @state&.dig("authorizationUrl")
    page = SIGN_IN_PAGES[provider]
    url if page && url.is_a?(String) && url.start_with?("#{page}?")
  end

  # A sign-in waiting for the owner's paste, until it expires.
  def pending
    pending = @state&.dig("pending")
    pending if pending && parse(pending["expiresAt"])&.future?
  end

  def pending_expires_at = parse(pending&.dig("expiresAt"))

  # ChatGPT's sign-in ends on Codex's own localhost address, which a server
  # can't receive, so the owner pastes that address; Claude's shows a code.
  def pastes_address? = provider == "openai-codex"

  private
    def parse(time) = time.present? ? Time.zone.parse(time.to_s) : nil
end
