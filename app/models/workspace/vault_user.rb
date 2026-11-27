# A workspace's own Passbolt user, which its agents read and save as unless
# an agent has one of its own (DurableAssistants::Passbolt.connection_for), so
# a shared workspace never reads the install's folders. Kept encrypted, and
# set as a pair: a key without its passphrase signs in as nobody. With a
# server of its own as well, its agents are read there and never on the
# install's; without, its user is one on the install's server.
module Workspace::VaultUser
  extend ActiveSupport::Concern

  included do
    encrypts :passbolt_private_key, :passbolt_passphrase
    # A passphrase's spaces are its own; only an empty one is none.
    normalizes :passbolt_private_key, with: -> { it.strip.presence }
    normalizes :passbolt_passphrase, with: -> { it.presence }
    normalizes :passbolt_url, with: -> { it.strip.presence }
    # Both or neither; on its page (context :vault_user), or with a server of its own, both.
    validates :passbolt_private_key, :passbolt_passphrase, presence: true,
      if: -> { passbolt_private_key? || passbolt_passphrase? || passbolt_url? || validation_context == :vault_user }
    # On a change only: resolving it on every save of the workspace would let
    # a resolver's outage block a rename. Each call checks it again anyway.
    validate :vault_server_reachable_safely, if: -> { passbolt_url? && will_save_change_to_passbolt_url? }
  end

  def vault_user? = passbolt_private_key.present? && passbolt_passphrase.present?

  # What is saved, not what a refused save just assigned.
  def vault_user_saved? = passbolt_private_key_in_database.present? && passbolt_passphrase_in_database.present?

  def forget_vault_user = update!(passbolt_private_key: nil, passbolt_passphrase: nil, passbolt_url: nil)

  private
    # Its key signs in there, so only over https, and never to this server or
    # its private network, by where its name leads and not only by the name.
    # Checked again before every call (DurableAssistants::Passbolt).
    def vault_server_reachable_safely
      uri = URI.parse(passbolt_url)
      return errors.add(:passbolt_url, "must start with https://") unless uri.is_a?(URI::HTTPS) && uri.host.present?
      McpServer::Address.public_address(uri.host)
    rescue McpServer::Address::Refused => refused
      errors.add(:passbolt_url, "can't be used: #{refused.message}")
    rescue URI::InvalidURIError
      errors.add(:passbolt_url, "is not a web address")
    end
end
