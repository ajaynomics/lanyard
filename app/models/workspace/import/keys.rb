# The other install's Active Record encryption keys, to read its encrypted
# columns before each is written again under this install's own. Given as its
# secret_key_base, from which it derives them as DurableAssistants::EncryptionKeys
# does (either way an earlier release derived them), or as the keys its
# credentials hold (active_record_encryption.primary_key and
# key_derivation_salt). Held only in memory, and never shown.
class Workspace::Import::Keys
  # A YAML file: what `bin/rails credentials:show` prints for that install,
  # or just its `secret_key_base:`. Keys of its own win over those derived,
  # as in its initializer.
  def self.load(path)
    settings = YAML.safe_load_file(path).to_h
    encryption = settings["active_record_encryption"].to_h
    if encryption["primary_key"].present? then new(primary_key: encryption["primary_key"], key_derivation_salt: encryption["key_derivation_salt"])
    else new(secret_key_base: settings["secret_key_base"])
    end
  end

  def initialize(secret_key_base: nil, primary_key: nil, key_derivation_salt: nil)
    return @provider = DurableAssistants::EncryptionKeys.new(secret_key_base).provider if secret_key_base.present?
    raise Workspace::Import::Refused, "The other install's secret_key_base, or its primary key and key derivation salt, are needed" if primary_key.blank? || key_derivation_salt.blank?
    @provider = ActiveRecord::Encryption::KeyProvider.new(Array(primary_key).map { derive(it, key_derivation_salt) })
  end

  def decrypt(ciphertext) = ActiveRecord::Encryption::Encryptor.new.decrypt(ciphertext, key_provider: @provider)

  def inspect = "#<#{self.class.name}>"

  private
    # As ActiveRecord::Encryption::KeyGenerator#derive_key_from, with the other install's salt.
    def derive(password, salt)
      key = ActiveSupport::KeyGenerator.new(password, hash_digest_class: ActiveRecord::Encryption.config.hash_digest_class)
        .generate_key(salt, ActiveRecord::Encryption.cipher.key_length)
      ActiveRecord::Encryption::Key.new(key)
    end
end
