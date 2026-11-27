# A visitor can fill one empty OAuth client secret, without passing it through
# an agent, the vault or the provider. Only digests of the token and connector
# identity are kept. The client secret lives in oauth_client.
class McpClientSecretSetup < ApplicationRecord
  LASTS = 15.minutes
  MAX_SECRET_BYTES = 4.kilobytes

  belongs_to :mcp_server
  belongs_to :issued_by, class_name: "User"

  class << self
    def issue!(connector, by:)
      raise ActiveRecord::RecordNotFound unless may_issue?(connector, by:)
      token = SecureRandom.base58(40)
      setup = connector.client_secret_setups.create!(issued_by: by, token_digest: digest(token),
        target_digest: target(connector), expires_at: LASTS.from_now)
      [ setup, token ]
    end

    def find_by_token(token)
      return unless token.is_a?(String) && token.match?(/\A[A-Za-z0-9]{40}\z/)
      find_by(token_digest: digest(token)) # tenancy-ok: the one-time token names only this setup
    end

    def may_issue?(connector, by:)
      eligible?(connector) && member?(connector, by) && (connector.user_id == by.id || connector.workspace.owner == by)
    end

    def valid_secret?(value)
      value.is_a?(String) && value.valid_encoding? && value.bytesize <= MAX_SECRET_BYTES && value.present? && !value.match?(/[[:cntrl:]]/)
    end

    def target(connector)
      digest([ connector.id, connector.workspace_id, connector.conversation_id, connector.url, connector.oauth_client&.sort ].to_json)
    end

    def digest(value) = Digest::SHA256.hexdigest(value)

    def member?(connector, member)
      member && connector.workspace.member?(member)
    end

    def eligible?(connector)
      connector.conversation&.workspace == connector.workspace && connector.conversation_id.present? &&
        connector.enabled? && connector.url.present? && !connector.command? && !connector.own_listing? &&
        connector.install.nil? && connector.oauth_app.nil? && !connector.authorized_by_header? &&
        connector.oauth_pending.blank? && !connector.signed_in? && connector.oauth_client&.fetch("client_id", nil).present? &&
        !connector.oauth_client.key?("client_secret")
    end
  end

  def fill!(secret:)
    return false unless self.class.valid_secret?(secret)
    self.class.transaction do
      now = Time.current
      # Take the write lock before re-reading the connector. On SQLite this
      # serializes claims from different links, not only replays of this one.
      claimed = mcp_server.client_secret_setups.where(id: id, used_at: nil).where("expires_at > ?", now)
        .update_all(used_at: now, updated_at: now)
      next false unless claimed == 1
      connector = mcp_server.reload(lock: true)
      next false unless self.class.may_issue?(connector, by: issued_by) && self.class.target(connector) == target_digest
      connector.update_columns(oauth_client: connector.oauth_client.merge(
        "client_secret" => secret, "token_endpoint_auth_method" => "client_secret_post"), updated_at: now)
    end
  end
end
