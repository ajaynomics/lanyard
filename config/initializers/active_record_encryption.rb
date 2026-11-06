# Encrypted columns (an MCP server's bearer token) need keys. Rails reads them
# from credentials (active_record_encryption.*); without them, derive keys from
# secret_key_base so there is no second key to keep and back up. Rotating
# secret_key_base then makes stored tokens unreadable: a person enters them again.
ActiveSupport.on_load(:active_record_encryption) do
  unless ActiveRecord::Encryption.config.has_primary_key?
    ActiveRecord::Encryption.configure(
      primary_key: Rails.application.key_generator.generate_key("active_record_encryption/primary_key", 32).unpack1("H*"),
      key_derivation_salt: Rails.application.key_generator.generate_key("active_record_encryption/salt", 32).unpack1("H*"),
      **Rails.application.config.active_record.encryption
    )
  end
end
