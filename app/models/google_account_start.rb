# One outside OAuth attempt for a disabled conversation connector. Ordinary
# OAuth state and tokens stay on that connector and are not the attempt's storage.
class GoogleAccountStart < ApplicationRecord
  LASTS = 15.minutes
  TOKEN = /\A[A-Za-z0-9]{40}\z/
  NONCE = /\A[A-Za-z0-9_-]{43}\z/
  STATE = /\Agstart\.[A-Za-z0-9_-]{43}\z/
  Grant = DurableAssistants::Google::AccountGrant
  class InvalidAddress < StandardError; end

  belongs_to :mcp_server
  belongs_to :issued_by, class_name: "User"
  encrypts :issued_email

  class << self
    def issue!(connector, by:, issued_email:, expected_email:, agent_id: nil)
      token = SecureRandom.base58(40)
      transaction do
        connector.reload(lock: true)
        managed = !agent_id.nil?
        issuer = issuer_membership(connector, by.reload, agent_bound: managed)
        raise ActiveRecord::RecordNotFound unless issuer && Admission.admits?(issued_email) && eligible?(connector)
        if managed
          raise ActiveRecord::RecordNotFound unless bindable?(connector) && connector.conversation.agent_id.to_s == agent_id.to_s
        elsif connector.gmail_grant?
          raise ActiveRecord::RecordNotFound
        end
        email = normalize_email(expected_email)
        raise InvalidAddress unless email

        bind_agent!(connector, email) if managed
        connector.google_account_starts.delete_all
        connector.google_account_starts.create!(issued_by: by, issued_email: issued_email, expected_email_digest: digest("email", email),
          target_digest: target(connector, issuer), token_digest: digest("start", token), expires_at: LASTS.from_now)
      end
      token
    end

    def may_issue?(connector, by:)
      !connector.gmail_grant? && eligible?(connector) && issuer_membership(connector, by).present?
    end

    def may_bind_agent?(connector, by:)
      eligible?(connector) && bindable?(connector) && connector.gmail_grant_owner?(by)
    end

    def canonical_origin
      uri = URI.parse(DurableAssistants.config(:app, :url).to_s)
      return unless uri.is_a?(URI::HTTPS) || (Rails.env.local? && uri.is_a?(URI::HTTP) && uri.host.in?(McpServer::LOCAL_HOSTS))
      return if uri.host.blank? || uri.userinfo
      uri.origin
    rescue URI::InvalidURIError
      nil
    end

    def callback_state?(value) = value.is_a?(String) && STATE.match?(value)
    def browser_nonce?(value) = value.is_a?(String) && NONCE.match?(value)

    def preview_digest(token)
      # Malformed tokens take the same lookup path but cannot match an issued token.
      digest("start", token.is_a?(String) && TOKEN.match?(token) ? token : "!" * 40)
    end

    def preview_connector(digest)
      # Let the lookup reject all unavailable links before loading any associated records.
      attempt = where("expires_at > ?", Time.current).find_by(token_digest: digest, started_at: nil) # tenancy-ok: the one-use token names its precise attempt
      attempt&.current_connector
    end

    def start(token, browser:)
      return unless token.is_a?(String) && TOKEN.match?(token) && browser_nonce?(browser)
      state = "gstart.#{SecureRandom.urlsafe_base64(32)}"
      transaction do
        attempt = find_by(token_digest: digest("start", token)) # tenancy-ok: a one-use token names its precise attempt
        next unless attempt&.claim_start(state, browser)
        connector = attempt.current_connector
        next unless connector
        attempt.grant_for(connector).authorization_url(state: state, verifier: verifier(state))
      end
    end

    def claim_callback(state, browser:)
      return unless callback_state?(state) && browser_nonce?(browser)
      transaction do
        attempt = find_by(state_digest: digest("state", state), browser_digest: digest("browser", browser)) # tenancy-ok: the state and browser proof name its precise attempt
        attempt if attempt&.claim_finish
      end
    end

    def verifier(state) = Base64.urlsafe_encode64(mac("pkce", state), padding: false)

    def normalize_email(value)
      return unless value.is_a?(String) && value.ascii_only?
      email = value.strip.downcase
      email if email.bytesize <= 254 && URI::MailTo::EMAIL_REGEXP.match?(email)
    end

    def digest(purpose, value) = mac(purpose, value).unpack1("H*")

    def target(connector, issuer)
      # An unused column must not change a legacy link issued before the migration.
      attributes = connector.attributes
      attributes.delete("gmail_grant") unless connector.gmail_grant?
      digest("target", [ attributes, client_for(connector), McpServer.redirect_uri,
        issuer.id, issuer.role, issuer.updated_at, issuer.user.oidc_sub, issuer.user.email ].to_json)
    end

    def issuer_membership(connector, user, agent_bound: false)
      return unless user
      membership = connector.workspace.memberships.find_by(user: user)
      membership if membership && (membership.owner? || (!agent_bound && connector.user_id == user.id))
    end

    def eligible?(connector)
      return unless canonical_origin && !connector.enabled? && !connector.command? && connector.install.nil? &&
        connector.conversation_id && connector.conversation&.workspace == connector.workspace &&
        !connector.authorized_by_header? && grant_scope(connector)

      uri = URI(connector.url)
      return unless uri.is_a?(URI::HTTPS) && uri.port == 443 && !uri.userinfo
      client = client_for(connector)
      client && client["client_id"].present? && client["client_secret"].present? &&
        client["issuer"].in?([ nil, Grant::ISSUER ]) &&
        client["token_endpoint_auth_method"].in?([ nil, "client_secret_post", "client_secret_basic" ])
    end

    def grant_scope(connector)
      scope = connector.oauth_scope
      case connector.google
      when :gmail
        scope if scope.to_s.split.intersect?(Grant::PROFILE_SCOPES)
      when :calendar, :drive
        entry = McpServer.gallery_attributes(connector.google)
        approved = entry[:oauth_scope]
        "#{approved} openid email" if approved.present? && connector.url == entry[:url] && scope.to_s.split.sort == approved.split.sort
      end
    end

    def client_for(connector) = McpServer::Authorization.new(connector).client_information

    private
      def bindable?(connector)
        gallery = McpServer.gallery_attributes(:gmail)
        connector.url == gallery[:url] && connector.oauth_app == gallery[:oauth_app] &&
          connector.oauth_scope == gallery[:oauth_scope] && connector.oauth_client.nil? &&
          !connector.signed_in? && connector.oauth_state.nil? && connector.oauth_pending.nil? &&
          (!connector.gmail_grant? || connector.gmail_grant_target?(connector.conversation))
      end

      def bind_agent!(connector, email)
        thread = connector.conversation
        connector.update!(gmail_grant: { "agent_id" => thread.agent_id, "conversation_id" => thread.id,
          "workspace_id" => connector.workspace_id, "email" => email })
      end

      def mac(purpose, value)
        key = Rails.application.key_generator.generate_key("google-account-start/#{purpose}", 32)
        OpenSSL::HMAC.digest("SHA256", key, value)
      end
  end

  def claim_start(state, browser)
    now = Time.current
    mcp_server.google_account_starts.where(id: id, started_at: nil).where("expires_at > ?", now).update_all(
      state_digest: self.class.digest("state", state), browser_digest: self.class.digest("browser", browser), started_at: now, updated_at: now) == 1
  end

  def claim_finish
    now = Time.current
    mcp_server.google_account_starts.where(id: id, finished_at: nil).where("expires_at > ?", now)
      .update_all(finished_at: now, updated_at: now) == 1
  end

  def current_connector
    connector = mcp_server.reload(lock: true)
    issuer = self.class.issuer_membership(connector, issued_by.reload, agent_bound: connector.gmail_grant?)
    return unless issuer && Admission.admits?(issued_email) && self.class.eligible?(connector)
    return if connector.gmail_grant? && !connector.gmail_grant_target?(connector.conversation)

    connector if self.class.target(connector, issuer) == target_digest
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def grant_for(connector)
    Grant.new(client: self.class.client_for(connector), scope: self.class.grant_scope(connector), redirect_uri: McpServer.redirect_uri)
  end

  def matches?(address)
    email = self.class.normalize_email(address)
    email && ActiveSupport::SecurityUtils.secure_compare(expected_email_digest, self.class.digest("email", email))
  end

  def save_grant(tokens)
    # No network inside the transaction. SQLite's write transaction keeps the
    # final checks (including issue, membership and connector changes) and save together.
    self.class.transaction do
      next false unless mcp_server.google_account_starts.where(id: id).where.not(finished_at: nil).where("expires_at > ?", Time.current).exists?
      connector = current_connector
      next false unless connector
      authorization = McpServer::Authorization.new(connector)
      if connector.gmail_grant?
        now = Time.current
        connector.update!(gmail_grant: connector.gmail_grant.merge("granted_at" => now.iso8601, "start_id" => id),
          oauth_tokens: authorization.token_attributes(tokens), enabled: true, refreshed_at: now,
          refresh_error: nil, sign_in_needed: false)
      else
        authorization.save_tokens(tokens)
      end
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    false
  end
end
