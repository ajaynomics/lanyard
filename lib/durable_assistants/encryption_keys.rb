# Active Record encryption keys derived from a secret_key_base, the same in
# every process (config/initializers/active_record_encryption.rb).
#
# They were derived through Rails.application.key_generator, which takes
# ActiveSupport::KeyGenerator's digest when it is first built and keeps it for
# the process. Rails sets that digest to SHA256 only after initialization. A
# process that eager-loads (the web, jobs, bin/rails runner and console in
# production) runs the initializer while loading its models, before that, and
# derived its keys with SHA1; a Rake task (`bin/rails <task>`) does not
# eager-load, runs it later, and derived them with SHA256: one secret, two
# sets of keys, and what a task wrote the web could not read.
#
# So the digest is named here. SHA1 encrypts: it is what every web and job
# process has always used, so what an install holds stays as it is. SHA256
# only decrypts, for what a task wrote before.
class DurableAssistants::EncryptionKeys
  ENCRYPTING = OpenSSL::Digest::SHA1
  DECRYPTING_TOO = OpenSSL::Digest::SHA256

  def initialize(secret_key_base)
    @secret_key_base = secret_key_base
  end

  # The primary key and salt, as Active Record's own configuration takes them.
  def config(digest = ENCRYPTING)
    generator = ActiveSupport::KeyGenerator.new(@secret_key_base, iterations: 1000, hash_digest_class: digest)
    { primary_key: generator.generate_key("active_record_encryption/primary_key", 32).unpack1("H*"),
      key_derivation_salt: generator.generate_key("active_record_encryption/salt", 32).unpack1("H*") }
  end

  # Every key decrypts; Active Record encrypts with the last.
  def provider = ActiveRecord::Encryption::KeyProvider.new(keys)

  def keys = [ DECRYPTING_TOO, ENCRYPTING ].map { key(**config(it)) }

  def inspect = "#<#{self.class.name}>"

  private
    # As ActiveRecord::Encryption::KeyGenerator#derive_key_from, with this salt.
    def key(primary_key:, key_derivation_salt:)
      ActiveRecord::Encryption::Key.new(ActiveSupport::KeyGenerator.new(primary_key, hash_digest_class: ActiveRecord::Encryption.config.hash_digest_class)
        .generate_key(key_derivation_salt, ActiveRecord::Encryption.cipher.key_length))
    end
end
