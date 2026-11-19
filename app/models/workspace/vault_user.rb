# A workspace's own Passbolt user, which its agents read and save as unless
# an agent has one of its own (DurableAssistants::Passbolt.key_for), so a
# shared workspace never reads the install's folders. Kept encrypted, and set
# as a pair: a key without its passphrase signs in as nobody.
module Workspace::VaultUser
  extend ActiveSupport::Concern

  included do
    encrypts :passbolt_private_key, :passbolt_passphrase
    # A passphrase's spaces are its own; only an empty one is none.
    normalizes :passbolt_private_key, with: -> { it.strip.presence }
    normalizes :passbolt_passphrase, with: -> { it.presence }
    # Both or neither; on its page (context :vault_user), both.
    validates :passbolt_private_key, :passbolt_passphrase, presence: true,
      if: -> { passbolt_private_key? || passbolt_passphrase? || validation_context == :vault_user }
  end

  def vault_user? = passbolt_private_key.present? && passbolt_passphrase.present?

  def forget_vault_user = update!(passbolt_private_key: nil, passbolt_passphrase: nil)
end
