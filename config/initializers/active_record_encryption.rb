# Encrypted columns (an MCP server's bearer token) need keys. Rails reads them
# from credentials (active_record_encryption.*); without them, derive keys from
# secret_key_base so there is no second key to keep and back up. Rotating
# secret_key_base then makes stored tokens unreadable: a person enters them again.
# Derived the same in a web, job or task process (DurableAssistants::EncryptionKeys).
ActiveSupport.on_load(:active_record_encryption) do
  unless ActiveRecord::Encryption.config.has_primary_key?
    keys = DurableAssistants::EncryptionKeys.new(Rails.application.secret_key_base)
    ActiveRecord::Encryption.configure(**keys.config, **Rails.application.config.active_record.encryption)
    ActiveRecord::Encryption.default_context.key_provider = keys.provider
  end
end
